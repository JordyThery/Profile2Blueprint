import Foundation
import OSLog

/// A saved copy of a classic profile's scope, taken right before it was changed.
nonisolated struct ScopeBackup: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var environmentName: String
    var environmentID: String?
    var profileID: Int
    var profileName: String
    var blueprintID: String?
    /// The `<scope>` element exactly as Jamf Pro returned it.
    var scopeXML: String
    var restoredAt: Date?
}

/// Persists scope backups in Application Support (`scope-backups.json`). Never pruned.
actor ScopeBackupStore {
    let fileURL: URL
    private var backups: [ScopeBackup]

    init(fileURL: URL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        backups = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([ScopeBackup].self, from: $0) } ?? []
    }

    static func appDefault() -> ScopeBackupStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return ScopeBackupStore(fileURL: base.appending(path: "Profile2Blueprint/scope-backups.json"))
    }

    var all: [ScopeBackup] { backups }

    /// The newest unrestored backup for a profile, matched by environment ID when
    /// one exists (tenant names can be edited) and by name otherwise (demo mode).
    func latest(profileID: Int, environmentID: String?, environmentName: String) -> ScopeBackup? {
        backups.last {
            $0.profileID == profileID && $0.restoredAt == nil
                && ($0.environmentID ?? $0.environmentName) == (environmentID ?? environmentName)
        }
    }

    /// Saves before any write. Throws if the backup can't be written, which aborts the unscope.
    func save(_ backup: ScopeBackup) throws {
        backups.append(backup)
        try persist()
    }

    func markRestored(_ id: UUID) throws {
        guard let index = backups.firstIndex(where: { $0.id == id }) else { return }
        backups[index].restoredAt = Date()
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backups).write(to: fileURL, options: .atomic)
    }
}

nonisolated struct ScopeChangeError: Error, LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// Unscopes a classic profile (after its blueprint is deployed) and restores it.
///
/// Sequence: fresh GET → back up the raw `<scope>` → PUT a scope-only body → GET again
/// and check the result. Payloads are never sent, so they can't be changed.
nonisolated enum ClassicScopeService {
    /// Scope with every target removed. Limitations and exclusions are left as they are.
    static let unscopedBody = Data("""
    <?xml version="1.0" encoding="UTF-8"?><os_x_configuration_profile><scope>\
    <all_computers>false</all_computers><all_jss_users>false</all_jss_users>\
    <computers/><computer_groups/><buildings/><departments/><jss_users/><jss_user_groups/>\
    </scope></os_x_configuration_profile>
    """.utf8)

    static func restoreBody(scopeXML: String) -> Data {
        Data(#"<?xml version="1.0" encoding="UTF-8"?><os_x_configuration_profile>\#(scopeXML)</os_x_configuration_profile>"#.utf8)
    }

    /// Whether a scope still targets anything.
    static func hasTargets(_ scope: ClassicScope) -> Bool {
        scope.allComputers || scope.allJSSUsers || !scope.computers.isEmpty || !scope.computerGroups.isEmpty
            || !scope.buildings.isEmpty || !scope.departments.isEmpty || !scope.otherTargets.isEmpty
    }

    /// Only after a fully clean deployment: deployed, report present, nothing failed or pending.
    static func deploymentAllowsUnscope(_ outcome: DeploymentOutcome?) -> Bool {
        guard case let .succeeded(report?) = outcome else { return false }
        return report.failed == 0 && report.pending == 0 && report.succeeded > 0
    }

    static func unscope(
        profileID: Int,
        blueprintID: String?,
        environment: MigrationEnvironment,
        backups: ScopeBackupStore
    ) async throws -> (backup: ScopeBackup, after: ClassicProfile) {
        guard let writer = environment.classicScopeWriter else {
            throw ScopeChangeError(message: "Classic scope changes are not enabled for this tenant.")
        }
        let before = try await environment.classic.profile(id: profileID)
        guard hasTargets(before.scope) else {
            throw ScopeChangeError(message: "The classic profile is already unscoped. Nothing was changed.")
        }
        let backup = ScopeBackup(environmentName: environment.displayName, environmentID: environment.environmentID,
                                 profileID: profileID, profileName: before.name, blueprintID: blueprintID, scopeXML: before.rawScopeXML)
        try await backups.save(backup)

        try await writer.replaceScope(profileID: profileID, body: unscopedBody)

        let after = try await environment.classic.profile(id: profileID)
        guard !hasTargets(after.scope) else {
            throw ScopeChangeError(message: "Jamf Pro accepted the change, but the profile still has scope targets. Check it in Jamf Pro; the backup is saved.")
        }
        guard after.payloadsPlist == before.payloadsPlist else {
            throw ScopeChangeError(message: "The profile's payloads changed unexpectedly after the scope update. Check it in Jamf Pro immediately.")
        }
        return (backup, after)
    }

    /// Order-insensitive scope comparison; Jamf Pro may return list members reordered.
    private static func equivalent(_ a: ClassicScope, _ b: ClassicScope) -> Bool {
        func ids(_ references: [ClassicReference]) -> Set<String> { Set(references.map(\.identity)) }
        func buckets(_ list: [ScopeBucket]) -> [String: Set<String>] {
            Dictionary(list.map { ($0.kind, ids($0.items)) }, uniquingKeysWith: { first, second in first.union(second) })
        }
        return a.allComputers == b.allComputers && a.allJSSUsers == b.allJSSUsers
            && ids(a.computerGroups) == ids(b.computerGroups)
            && ids(a.computers) == ids(b.computers)
            && ids(a.buildings) == ids(b.buildings)
            && ids(a.departments) == ids(b.departments)
            && buckets(a.otherTargets) == buckets(b.otherTargets)
            && buckets(a.limitations) == buckets(b.limitations)
            && buckets(a.exclusions) == buckets(b.exclusions)
    }

    static func restore(
        _ backup: ScopeBackup,
        environment: MigrationEnvironment,
        backups: ScopeBackupStore
    ) async throws -> ClassicProfile {
        guard let writer = environment.classicScopeWriter else {
            throw ScopeChangeError(message: "Classic scope changes are not enabled for this tenant.")
        }
        guard let expected = try? ClassicXMLParser.parseScopeXML(backup.scopeXML) else {
            throw ScopeChangeError(message: "The saved scope backup can't be read.")
        }
        try await writer.replaceScope(profileID: backup.profileID, body: restoreBody(scopeXML: backup.scopeXML))
        let after = try await environment.classic.profile(id: backup.profileID)
        guard equivalent(after.scope, expected) else {
            throw ScopeChangeError(message: "Scope was sent back to Jamf Pro, but the result differs from the backup. Check the profile in Jamf Pro.")
        }
        try await backups.markRestored(backup.id)
        return after
    }
}
