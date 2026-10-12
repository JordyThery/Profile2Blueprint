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
    var updatedAt = Date()

    var key: ProfileKey { ProfileKey(platform: platform, id: profileID) }

    private enum CodingKeys: String, CodingKey {
        case environmentKey, platform, profileID, blueprintID, blueprintName, selectedGroupIDs, unscopeAfterDeploy, updatedAt
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
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    init(
        environmentKey: String, platform: ProfilePlatform, profileID: Int, blueprintID: String,
        blueprintName: String, selectedGroupIDs: [String], unscopeAfterDeploy: Bool, updatedAt: Date = Date()
    ) {
        self.environmentKey = environmentKey
        self.platform = platform
        self.profileID = profileID
        self.blueprintID = blueprintID
        self.blueprintName = blueprintName
        self.selectedGroupIDs = selectedGroupIDs
        self.unscopeAfterDeploy = unscopeAfterDeploy
        self.updatedAt = updatedAt
    }
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

    func record(environmentKey: String, key: ProfileKey) -> PersistedMigration? {
        records.first { $0.environmentKey == environmentKey && $0.key == key }
    }

    func save(_ record: PersistedMigration) {
        records.removeAll { $0.environmentKey == record.environmentKey && $0.key == record.key }
        records.append(record)
        if records.count > limit {
            records.sort { $0.updatedAt < $1.updatedAt }
            records.removeFirst(records.count - limit)
        }
        persist()
    }

    func remove(environmentKey: String, key: ProfileKey) {
        records.removeAll { $0.environmentKey == environmentKey && $0.key == key }
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
