import Foundation

nonisolated enum ActivityCategory: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case auth
    case request
    case retry
    case blocked
    case migration
    case classicWrite = "classic-write"
    case app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auth: "Auth"
        case .request: "API request"
        case .retry: "Retry"
        case .blocked: "Blocked"
        case .migration: "Migration"
        case .classicWrite: "Classic write"
        case .app: "App"
        }
    }
}

nonisolated enum ActivityLevel: String, Codable, Hashable, Sendable, Comparable {
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// One thing the app did. Never contains tokens, secrets or payload contents.
nonisolated struct ActivityEvent: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var timestamp = Date()
    var environment: String
    var category: ActivityCategory
    var level: ActivityLevel = .info
    var message: String
    var method: String?
    var path: String?
    var status: Int?
    var durationMs: Int?
    var traceId: String?
}

/// Receives activity events from any isolation domain.
nonisolated protocol ActivityRecorder: Sendable {
    func record(_ event: ActivityEvent)
}

/// Discards events (tests, previews).
nonisolated struct NullActivityRecorder: ActivityRecorder {
    func record(_ event: ActivityEvent) {}
}
