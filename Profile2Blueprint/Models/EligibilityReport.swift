import Foundation

nonisolated enum EligibilityStatus: Int, Comparable, Hashable, Sendable {
    case ready = 0
    case needsAttention = 1
    case blocked = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .ready: "Ready"
        case .needsAttention: "Needs attention"
        case .blocked: "Blocked"
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }
}

nonisolated enum FindingSeverity: Int, Comparable, Hashable, Sendable {
    case info = 0
    case warning = 1
    case blocker = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A stable identifier per check, so tests and the UI can refer to specific results.
nonisolated enum FindingKind: String, Hashable, Sendable {
    case userLevel
    case unparseablePayload
    case blockedPayloadType
    case missingIdentifiers
    case noPayloads
    case duplicatePayloadUUIDs
    case noMappedGroup
    case unmatchedGroups
    case ambiguousGroups
    case allComputers
    case nonGroupTargets
    case limitations
    case exclusions
    case recordUUIDMismatch
    case jamfProtectManaged
    case selfService
    case droppedTopLevelKeys
    case sensitiveContent
    case serverValidation
    case disabledPayload
    case site
    case cannotVerifyDevicePreconditions
}

nonisolated struct EligibilityFinding: Hashable, Sendable, Identifiable {
    var kind: FindingKind
    var severity: FindingSeverity
    var title: String
    var detail: String

    var id: FindingKind { kind }
}

/// Result of the eligibility check for one classic profile.
nonisolated struct EligibilityReport: Hashable, Sendable {
    var findings: [EligibilityFinding]
    var scopeMapping: [ScopeMappingEntry]

    var status: EligibilityStatus {
        switch findings.map(\.severity).max() {
        case .blocker: .blocked
        case .warning: .needsAttention
        default: .ready
        }
    }

    /// Findings that drive the badge, most severe first.
    var reasons: [EligibilityFinding] {
        findings.filter { $0.severity > .info }.sorted { $0.severity > $1.severity }
    }

    func has(_ kind: FindingKind) -> Bool {
        findings.contains { $0.kind == kind }
    }

    /// Whether the five-rule identity checks (rules 3–5) are known to hold locally.
    var identityRulesHold: Bool {
        !findings.contains { [.unparseablePayload, .missingIdentifiers, .noPayloads, .recordUUIDMismatch].contains($0.kind) }
    }
}

/// How one classic computer group maps onto platform device groups.
nonisolated struct ScopeMappingEntry: Hashable, Sendable, Identifiable {
    var classicGroup: ClassicReference
    /// Platform COMPUTER groups whose name matches exactly.
    var exactMatches: [PlatformGroup]
    /// Case-/whitespace-insensitive matches, offered as suggestions only.
    var suggestions: [PlatformGroup]

    var id: String { classicGroup.identity }

    var autoMatch: PlatformGroup? {
        exactMatches.count == 1 ? exactMatches[0] : nil
    }

    var isAmbiguous: Bool { exactMatches.count > 1 }
    var isUnmatched: Bool { exactMatches.isEmpty }
}
