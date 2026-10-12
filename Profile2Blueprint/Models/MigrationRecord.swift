import Foundation

nonisolated enum MigrationAction: String, Codable, Hashable, Sendable, CaseIterable {
    case dryRun = "dry-run"
    case create
    case skipExisting = "skip-existing"
    case adoptExisting = "open-existing"
    case verify
    case deploy
    case deploymentResult = "deployment-result"
    case unscopeClassic = "unscope-classic"
    case restoreClassicScope = "restore-classic-scope"

    var title: String {
        switch self {
        case .dryRun: "Dry run"
        case .create: "Create (not deployed)"
        case .skipExisting: "Skipped (exists)"
        case .adoptExisting: "Opened existing"
        case .verify: "Verify"
        case .deploy: "Deploy"
        case .deploymentResult: "Deployment result"
        case .unscopeClassic: "Unscope classic profile"
        case .restoreClassicScope: "Restore classic scope"
        }
    }
}

nonisolated enum MigrationResult: String, Codable, Hashable, Sendable {
    case success
    case warning
    case failure
}

/// One line of the local action log. Never contains secrets or payload contents.
nonisolated struct MigrationRecord: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var timestamp: Date
    var tenantName: String
    var environmentID: String?
    var action: MigrationAction
    var platform: ProfilePlatform = .macOS
    var sourceProfileID: Int
    var sourceProfileName: String
    var blueprintID: String?
    var blueprintName: String?
    var result: MigrationResult
    var message: String

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, tenantName, environmentID, action, platform
        case sourceProfileID, sourceProfileName, blueprintID, blueprintName, result, message
    }

    /// Records written before mobile support decode as macOS.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        tenantName = try container.decode(String.self, forKey: .tenantName)
        environmentID = try container.decodeIfPresent(String.self, forKey: .environmentID)
        action = try container.decode(MigrationAction.self, forKey: .action)
        platform = try container.decodeIfPresent(ProfilePlatform.self, forKey: .platform) ?? .macOS
        sourceProfileID = try container.decode(Int.self, forKey: .sourceProfileID)
        sourceProfileName = try container.decode(String.self, forKey: .sourceProfileName)
        blueprintID = try container.decodeIfPresent(String.self, forKey: .blueprintID)
        blueprintName = try container.decodeIfPresent(String.self, forKey: .blueprintName)
        result = try container.decode(MigrationResult.self, forKey: .result)
        message = try container.decode(String.self, forKey: .message)
    }

    init(
        id: UUID = UUID(), timestamp: Date, tenantName: String, environmentID: String?,
        action: MigrationAction, platform: ProfilePlatform = .macOS, sourceProfileID: Int, sourceProfileName: String,
        blueprintID: String?, blueprintName: String?, result: MigrationResult, message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tenantName = tenantName
        self.environmentID = environmentID
        self.action = action
        self.platform = platform
        self.sourceProfileID = sourceProfileID
        self.sourceProfileName = sourceProfileName
        self.blueprintID = blueprintID
        self.blueprintName = blueprintName
        self.result = result
        self.message = message
    }
}
