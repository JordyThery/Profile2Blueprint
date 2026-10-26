import Foundation
import JTKit

/// The app's own entries in JTKit's activity log, beside the requests JTKit
/// records itself: settings changes, migration steps, update checks.
nonisolated enum ActivityCategory: String, Sendable, CaseIterable {
    case auth = "Auth"
    case migration = "Migration"
    case classicWrite = "Classic write"
    case app = "App"
}

nonisolated enum ActivityLevel: Sendable {
    case info
    case warning
    case error
}

extension ActivityLog {
    /// Adds one of the app's own entries. The message is redacted; `environment`
    /// is the tenant it concerns, if any.
    func app(_ message: String, environment: String? = nil, level: ActivityLevel = .info, category: ActivityCategory = .app) {
        let safe = Redaction.text(message)
        append(ActivityLogEntry(
            category: category.rawValue,
            operation: "",
            detail: safe,
            failedWithoutStatus: level == .error,
            isWarning: level == .warning,
            connection: environment,
            identifiers: IdentifierMasker.identifiers(inText: safe)
        ))
    }
}
