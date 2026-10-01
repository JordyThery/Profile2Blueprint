import Foundation
import OSLog

/// What survives a relaunch for one profile's migration: enough to re-attach the
/// created blueprint and resume verify, deploy and cleanup.
nonisolated struct PersistedMigration: Codable, Hashable, Sendable {
    var environmentKey: String
    var profileID: Int
    var blueprintID: String
    var blueprintName: String
    var selectedGroupIDs: [String]
    var unscopeAfterDeploy: Bool
    var updatedAt = Date()
}

/// Persists migration sessions as JSON in Application Support (`sessions.json`).
/// Keyed by environment + profile; keeps the newest `limit` records.
actor SessionStateStore {
    let fileURL: URL
    private let limit: Int
    private var records: [PersistedMigration]

    init(fileURL: URL, limit: Int = 200) {
        self.fileURL = fileURL
        self.limit = limit
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([PersistedMigration].self, from: $0) } ?? []
    }

    static func appDefault() -> SessionStateStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return SessionStateStore(fileURL: base.appending(path: "Profile2Blueprint/sessions.json"))
    }

    func record(environmentKey: String, profileID: Int) -> PersistedMigration? {
        records.first { $0.environmentKey == environmentKey && $0.profileID == profileID }
    }

    func save(_ record: PersistedMigration) {
        records.removeAll { $0.environmentKey == record.environmentKey && $0.profileID == record.profileID }
        records.append(record)
        if records.count > limit {
            records.sort { $0.updatedAt < $1.updatedAt }
            records.removeFirst(records.count - limit)
        }
        persist()
    }

    func remove(environmentKey: String, profileID: Int) {
        records.removeAll { $0.environmentKey == environmentKey && $0.profileID == profileID }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Could not write sessions.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
