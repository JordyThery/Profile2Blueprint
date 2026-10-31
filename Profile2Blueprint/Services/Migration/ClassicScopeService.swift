import Foundation
import JTKit
import OSLog

/// Whether the scope change a backup was taken for reached Jamf Pro.
nonisolated enum ScopeWriteState: String, Codable, Hashable, Sendable {
    /// Saved before the write; its outcome isn't known yet (or the app stopped
    /// before it was). Settled by reading the profile (`ClassicScopeService.settle`).
    case pending
    /// Jamf Pro took the change: the profile was unscoped.
    case written
    /// The write didn't happen; the profile still has the backed-up scope.
    /// Never read as "unscoped" and never offered for Restore.
    case notWritten
}

/// A saved copy of a classic profile's scope, taken right before it was changed.
nonisolated struct ScopeBackup: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var environmentName: String
    var environmentID: String?
    var platform: ProfilePlatform = .macOS
    var profileID: Int
    var profileName: String
    var blueprintID: String?
    /// The `<scope>` element exactly as Jamf Pro returned it.
    var scopeXML: String
    var restoredAt: Date?
    var writeState: ScopeWriteState = .pending

    var key: ProfileKey { ProfileKey(platform: platform, id: profileID) }

    /// Whether this backup was taken in `environment`: a real tenant by its
    /// Environment ID, demo mode by name. A demo backup never matches a real
    /// tenant and a real tenant's backup never matches demo mode.
    func belongs(to environment: MigrationEnvironment) -> Bool {
        if environment.isDemo {
            return environmentID == nil && environmentName == environment.displayName
        }
        guard let environmentID else {
            // Backups without an Environment ID: matched by name, never a demo name.
            return environmentName == environment.displayName
                && ![MigrationEnvironment.demoDisplayName, MigrationEnvironment.earlierDemoDisplayName].contains(environmentName)
        }
        return environmentID == environment.environmentID
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, environmentName, environmentID, platform, profileID, profileName, blueprintID, scopeXML, restoredAt,
             writeState
    }

    /// Backups saved before mobile support decode as macOS. Backups saved
    /// before the write outcome was kept decode as pending, so the app reads
    /// the profile once to find out whether the change happened.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        environmentName = try container.decode(String.self, forKey: .environmentName)
        environmentID = try container.decodeIfPresent(String.self, forKey: .environmentID)
        platform = try container.decodeIfPresent(ProfilePlatform.self, forKey: .platform) ?? .macOS
        profileID = try container.decode(Int.self, forKey: .profileID)
        profileName = try container.decode(String.self, forKey: .profileName)
        blueprintID = try container.decodeIfPresent(String.self, forKey: .blueprintID)
        scopeXML = try container.decode(String.self, forKey: .scopeXML)
        restoredAt = try container.decodeIfPresent(Date.self, forKey: .restoredAt)
        writeState = try container.decodeIfPresent(ScopeWriteState.self, forKey: .writeState) ?? .pending
    }

    init(
        id: UUID = UUID(), createdAt: Date = Date(), environmentName: String, environmentID: String?,
        platform: ProfilePlatform, profileID: Int, profileName: String, blueprintID: String?,
        scopeXML: String, restoredAt: Date? = nil, writeState: ScopeWriteState = .pending
    ) {
        self.id = id
        self.createdAt = createdAt
        self.environmentName = environmentName
        self.environmentID = environmentID
        self.platform = platform
        self.profileID = profileID
        self.profileName = profileName
        self.blueprintID = blueprintID
        self.scopeXML = scopeXML
        self.restoredAt = restoredAt
        self.writeState = writeState
    }
}

/// Persists scope backups in Application Support (`scope-backups.json`). Never
/// pruned. One instance per file (`AppModel` owns it), so no two copies
/// overwrite each other's backups; a file that can't be read is kept and
/// nothing is written, which also stops every scope change (`StoredList`).
actor ScopeBackupStore {
    let fileURL: URL
    private var backups: [ScopeBackup]
    private let list: StoredList<ScopeBackup>

    init(fileURL: URL) {
        self.fileURL = fileURL
        (backups, list) = StoredList.open(fileURL)
    }

    static func appDefault() -> ScopeBackupStore {
        ScopeBackupStore(fileURL: StoredList<ScopeBackup>.appSupportFile("scope-backups.json"))
    }

    /// Every backup, for the release check and tests.
    var all: [ScopeBackup] { backups }

    /// Why backups aren't saved, when the file couldn't be read.
    var problem: String? { list.problem }

    /// The newest unrestored backup for a profile taken in `environment` whose
    /// write may have happened, matched exactly as Restore checks it
    /// (`ScopeBackup.belongs(to:)`), so the app never offers a Restore it
    /// would then refuse, nor reads a write that never happened as "unscoped".
    func latest(key: ProfileKey, environment: MigrationEnvironment) -> ScopeBackup? {
        backups.last { $0.key == key && $0.restoredAt == nil && $0.writeState != .notWritten && $0.belongs(to: environment) }
    }

    /// Whether the app ever changed this profile's scope in `environment`,
    /// restored since or not. Automatic cleanup runs at most once per profile.
    func hasScopeChange(key: ProfileKey, environment: MigrationEnvironment) -> Bool {
        backups.contains { $0.key == key && $0.writeState != .notWritten && $0.belongs(to: environment) }
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

    /// Records the outcome of the write the backup was taken for.
    func setWriteState(_ id: UUID, _ state: ScopeWriteState) throws {
        guard let index = backups.firstIndex(where: { $0.id == id }) else { return }
        backups[index].writeState = state
        try persist()
    }

    private func persist() throws {
        try list.write(backups)
    }
}

/// What a Blueprint targets, to check a classic scope against before an
/// automatic unscope: unscoping removes the classic profile from every device
/// in its scope, so each of them must be in one of the Blueprint's groups.
nonisolated struct ScopeCoverage: Sendable {
    var platform: ProfilePlatform
    var platformGroups: [JamfPlatform.DeviceGroup]
    var blueprintGroupIDs: [String]

    /// The classic scope's targets the Blueprint doesn't provably reach:
    /// everything except device groups whose single exact-name platform group
    /// is one of the Blueprint's groups. Empty means every device is covered.
    /// Limitations and exclusions only make the classic scope smaller, and
    /// unscoping leaves them as they are, so they don't count here.
    func uncovered(in scope: ClassicScope) -> [String] {
        let noun = platform.deviceNoun
        var targets: [String] = []
        if scope.allDevices { targets.append("all \(noun)s") }
        if scope.allJSSUsers { targets.append("all users") }
        if !scope.devices.isEmpty {
            targets.append("\(scope.devices.count) individual \(noun)\(scope.devices.count == 1 ? "" : "s")")
        }
        targets += scope.buildings.map { "building “\($0.name)”" }
        targets += scope.departments.map { "department “\($0.name)”" }
        targets += scope.otherTargets.map { $0.displayName.lowercased() }
        let blueprintGroups = Set(blueprintGroupIDs)
        let mapping = ScopeMapper.propose(for: scope, platform: platform, platformGroups: platformGroups)
        for entry in mapping where !(entry.autoMatch.map { blueprintGroups.contains($0.id) } ?? false) {
            targets.append("group “\(entry.classicGroup.name)”")
        }
        return targets
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
    /// Scope with every target removed, in the platform's element names.
    /// Limitations and exclusions are left as they are.
    static func unscopedBody(platform: ProfilePlatform) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?><\(platform.profileRootElement)><scope>\
        <\(platform.allDevicesElement)>false</\(platform.allDevicesElement)><all_jss_users>false</all_jss_users>\
        <\(platform.devicesElement)/><\(platform.deviceGroupsElement)/><buildings/><departments/><jss_users/><jss_user_groups/>\
        </scope></\(platform.profileRootElement)>
        """.utf8)
    }

    static func restoreBody(platform: ProfilePlatform, scopeXML: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?><\(platform.profileRootElement)>\(scopeXML)</\(platform.profileRootElement)>
        """.utf8)
    }

    /// Whether a scope still targets anything.
    static func hasTargets(_ scope: ClassicScope) -> Bool {
        scope.allDevices || scope.allJSSUsers || !scope.devices.isEmpty || !scope.deviceGroups.isEmpty
            || !scope.buildings.isEmpty || !scope.departments.isEmpty || !scope.otherTargets.isEmpty
    }

    /// Only after a fully clean deployment: deployed, report present, nothing failed or pending.
    static func deploymentAllowsUnscope(_ outcome: DeploymentOutcome?) -> Bool {
        guard case let .succeeded(report?) = outcome else { return false }
        return report.failed == 0 && report.pending == 0 && report.succeeded > 0
    }

    /// Removes every target from the classic profile's scope, after saving a
    /// backup. With `coverage` (the automatic cleanup), refuses unless the
    /// Blueprint's groups reach every device in the fresh classic scope.
    static func unscope(
        key: ProfileKey,
        blueprintID: String?,
        environment: MigrationEnvironment,
        backups: ScopeBackupStore,
        requiring coverage: ScopeCoverage? = nil
    ) async throws -> (backup: ScopeBackup, after: ClassicProfile) {
        guard let writer = environment.classicScopeWriter else {
            throw ScopeChangeError(message: offMessage)
        }
        let before = try await environment.classic.profile(key: key)
        guard hasTargets(before.scope) else {
            throw ScopeChangeError(message: "The classic profile is already unscoped. Nothing was changed.")
        }
        if let coverage {
            let uncovered = coverage.uncovered(in: before.scope)
            guard uncovered.isEmpty else {
                throw ScopeChangeError(message: uncoveredMessage(uncovered))
            }
        }
        var backup = ScopeBackup(environmentName: environment.displayName, environmentID: environment.environmentID,
                                 platform: key.platform, profileID: key.id, profileName: before.name,
                                 blueprintID: blueprintID, scopeXML: before.rawScopeXML)
        try await backups.save(backup)

        do {
            try await writer.replaceScope(key: key, body: unscopedBody(platform: key.platform))
        } catch {
            // The change may or may not have reached Jamf Pro; the profile tells.
            _ = await settle(backup, environment: environment, backups: backups)
            throw error
        }
        backup.writeState = .written
        // Kept in memory even if the file write fails; the next launch settles it.
        try? await backups.setWriteState(backup.id, .written)

        let after = try await environment.classic.profile(key: key)
        guard !hasTargets(after.scope) else {
            throw ScopeChangeError(message: "Jamf Pro accepted the change, but the profile still has scope targets. Check it in Jamf Pro; the backup is saved.")
        }
        guard after.payloadsPlist == before.payloadsPlist else {
            throw ScopeChangeError(message: "The profile’s payloads changed unexpectedly after the scope update. Check it in Jamf Pro immediately.")
        }
        return (backup, after)
    }

    static let offMessage = "Classic scope changes are off for this tenant."

    static func uncoveredMessage(_ uncovered: [String]) -> String {
        "Not unscoped automatically: the classic profile also targets \(uncovered.formatted(.list(type: .and))), "
            + "which the Blueprint’s groups don’t cover. Unscoping would remove the profile from those devices. "
            + "Nothing was changed; unscope by hand if that’s intended."
    }

    /// Finds out whether a pending backup's change reached Jamf Pro by reading
    /// the profile (GET only): no targets left means it did; the backed-up
    /// scope still in place means it didn't. Anything else (the read fails,
    /// or someone changed the scope since) stays pending, and Restore stays offered.
    /// Returns the backup as settled, or nil when the write didn't happen.
    static func settle(_ backup: ScopeBackup, environment: MigrationEnvironment, backups: ScopeBackupStore) async -> ScopeBackup? {
        guard backup.writeState == .pending else { return backup.writeState == .notWritten ? nil : backup }
        guard let now = try? await environment.classic.profile(key: backup.key) else { return backup }
        let state: ScopeWriteState
        if !hasTargets(now.scope) {
            state = .written
        } else if let saved = try? ClassicXMLParser.parseScopeXML(backup.scopeXML, platform: backup.platform), equivalent(now.scope, saved) {
            state = .notWritten
        } else {
            return backup
        }
        try? await backups.setWriteState(backup.id, state)
        var settled = backup
        settled.writeState = state
        return state == .notWritten ? nil : settled
    }

    /// Order-insensitive scope comparison; Jamf Pro may return list members reordered.
    private static func equivalent(_ a: ClassicScope, _ b: ClassicScope) -> Bool {
        func ids(_ references: [ClassicReference]) -> Set<String> { Set(references.map(\.identity)) }
        func buckets(_ list: [ScopeBucket]) -> [String: Set<String>] {
            Dictionary(list.map { ($0.kind, ids($0.items)) }, uniquingKeysWith: { first, second in first.union(second) })
        }
        return a.allDevices == b.allDevices && a.allJSSUsers == b.allJSSUsers
            && ids(a.deviceGroups) == ids(b.deviceGroups)
            && ids(a.devices) == ids(b.devices)
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
            throw ScopeChangeError(message: offMessage)
        }
        guard backup.belongs(to: environment) else {
            throw ScopeChangeError(message: "This scope backup was taken in “\(backup.environmentName)”, not in “\(environment.displayName)”. Nothing was changed.")
        }
        guard let expected = try? ClassicXMLParser.parseScopeXML(backup.scopeXML, platform: backup.platform) else {
            throw ScopeChangeError(message: "The saved scope backup can’t be read.")
        }
        try await writer.replaceScope(key: backup.key, body: restoreBody(platform: backup.platform, scopeXML: backup.scopeXML))
        let after = try await environment.classic.profile(key: backup.key)
        guard equivalent(after.scope, expected) else {
            throw ScopeChangeError(message: "Scope was sent back to Jamf Pro, but the result differs from the backup. Check the profile in Jamf Pro.")
        }
        try await backups.markRestored(backup.id)
        return after
    }
}
