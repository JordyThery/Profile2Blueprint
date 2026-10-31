import Foundation
import OSLog

/// What survives a relaunch for one profile's migration: enough to re-attach the
/// created blueprint and resume verify, deploy and cleanup.
nonisolated struct PersistedMigration: Codable, Hashable, Sendable {
    var environmentKey: String
    var platform: ProfilePlatform = .macOS
    var profileID: Int
    var blueprintID: String
    var blueprintName: String
    var selectedGroupIDs: [String]
    var unscopeAfterDeploy: Bool
    /// The description sent on create; nil in records saved before it was kept.
    var blueprintDescription: String?
    var updatedAt = Date()

    var key: ProfileKey { ProfileKey(platform: platform, id: profileID) }

    private enum CodingKeys: String, CodingKey {
        case environmentKey, platform, profileID, blueprintID, blueprintName, selectedGroupIDs, unscopeAfterDeploy,
             blueprintDescription, updatedAt
    }

    /// Records saved before mobile support decode as macOS.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environmentKey = try container.decode(String.self, forKey: .environmentKey)
        platform = try container.decodeIfPresent(ProfilePlatform.self, forKey: .platform) ?? .macOS
        profileID = try container.decode(Int.self, forKey: .profileID)
        blueprintID = try container.decode(String.self, forKey: .blueprintID)
        blueprintName = try container.decode(String.self, forKey: .blueprintName)
        selectedGroupIDs = try container.decode([String].self, forKey: .selectedGroupIDs)
        unscopeAfterDeploy = try container.decode(Bool.self, forKey: .unscopeAfterDeploy)
        blueprintDescription = try container.decodeIfPresent(String.self, forKey: .blueprintDescription)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    init(
        environmentKey: String, platform: ProfilePlatform, profileID: Int, blueprintID: String,
        blueprintName: String, selectedGroupIDs: [String], unscopeAfterDeploy: Bool,
        blueprintDescription: String? = nil, updatedAt: Date = Date()
    ) {
        self.environmentKey = environmentKey
        self.platform = platform
        self.profileID = profileID
        self.blueprintID = blueprintID
        self.blueprintName = blueprintName
        self.selectedGroupIDs = selectedGroupIDs
        self.unscopeAfterDeploy = unscopeAfterDeploy
        self.blueprintDescription = blueprintDescription
        self.updatedAt = updatedAt
    }
}

/// Persists migration sessions as JSON in Application Support (`sessions.json`).
/// Keyed by environment + profile; keeps the newest `limit` records. One
/// instance per file (`AppModel` owns it), so no two copies overwrite each
/// other; a file that can't be read is kept and not written (`StoredList`).
actor SessionStateStore {
    let fileURL: URL
    private let limit: Int
    private var records: [PersistedMigration]
    private let list: StoredList<PersistedMigration>

    init(fileURL: URL, limit: Int = 200) {
        self.fileURL = fileURL
        self.limit = limit
        (records, list) = StoredList.open(fileURL)
    }

    static func appDefault() -> SessionStateStore {
        SessionStateStore(fileURL: StoredList<PersistedMigration>.appSupportFile("sessions.json"))
    }

    /// Why sessions aren't saved, when the file couldn't be read.
    var problem: String? { list.problem }

    func record(environmentKey: String, key: ProfileKey) -> PersistedMigration? {
        records.first { $0.environmentKey == environmentKey && $0.key == key }
    }

    /// Throws when the file couldn't be written; the record stays in memory for this launch.
    func save(_ record: PersistedMigration) throws {
        records.removeAll { $0.environmentKey == record.environmentKey && $0.key == record.key }
        records.append(record)
        if records.count > limit {
            records.sort { $0.updatedAt < $1.updatedAt }
            records.removeFirst(records.count - limit)
        }
        try persist()
    }

    func remove(environmentKey: String, key: ProfileKey) throws {
        records.removeAll { $0.environmentKey == environmentKey && $0.key == key }
        try persist()
    }

    private func persist() throws {
        do {
            try list.write(records)
        } catch {
            Log.app.error("Could not write sessions.json: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
