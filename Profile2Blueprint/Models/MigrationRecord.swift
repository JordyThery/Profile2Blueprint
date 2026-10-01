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
    var sourceProfileID: Int
    var sourceProfileName: String
    var blueprintID: String?
    var blueprintName: String?
    var result: MigrationResult
    var message: String
}
