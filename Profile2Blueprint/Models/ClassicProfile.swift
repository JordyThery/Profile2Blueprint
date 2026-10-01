import Foundation

/// `{id, name}` pair used throughout the Classic API.
nonisolated struct ClassicReference: Hashable, Sendable, Identifiable {
    var id: Int?
    var name: String

    /// Stable identity even when the Classic API omits the ID (e.g. some user entries).
    var identity: String { id.map(String.init) ?? "name:\(name)" }
}

/// Entry in `GET /osxconfigurationprofiles`.
nonisolated struct ClassicProfileSummary: Hashable, Sendable, Identifiable {
    var id: Int
    var name: String
}

/// `general/level`. The Classic API reports computer-level profiles as `System`.
nonisolated enum ProfileLevel: Hashable, Sendable {
    case system
    case user
    case other(String)

    init(_ raw: String) {
        switch raw.lowercased() {
        case "system", "computer": self = .system
        case "user": self = .user
        default: self = .other(raw)
        }
    }

    var displayName: String {
        switch self {
        case .system: "Computer (System)"
        case .user: "User"
        case let .other(raw): raw
        }
    }
}

/// A named list of scope targets (e.g. `buildings`, `network_segments`).
nonisolated struct ScopeBucket: Hashable, Sendable, Identifiable {
    var kind: String
    var items: [ClassicReference]

    var id: String { kind }

    /// `network_segments` → `Network segments`.
    var displayName: String {
        let words = kind.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

nonisolated struct ClassicScope: Hashable, Sendable {
    var allComputers = false
    var allJSSUsers = false
    var computerGroups: [ClassicReference] = []
    var computers: [ClassicReference] = []
    var buildings: [ClassicReference] = []
    var departments: [ClassicReference] = []
    /// Other non-empty targets (JSS users / user groups).
    var otherTargets: [ScopeBucket] = []
    /// Non-empty limitation lists.
    var limitations: [ScopeBucket] = []
    /// Non-empty exclusion lists.
    var exclusions: [ScopeBucket] = []

    var hasExclusions: Bool { !exclusions.isEmpty }
    var hasLimitations: Bool { !limitations.isEmpty }
}

/// A Jamf Pro classic macOS configuration profile as returned by
/// `GET /osxconfigurationprofiles/id/{id}`.
nonisolated struct ClassicProfile: Hashable, Sendable, Identifiable {
    var id: Int
    var name: String
    var description: String
    var site: ClassicReference?
    var category: ClassicReference?
    var level: ProfileLevel
    var distributionMethod: String
    var userRemovable: Bool
    var redeployOnUpdate: String
    /// `general/uuid`. In practice Jamf Pro stores the top-level PayloadIdentifier here.
    var uuid: String
    /// The unescaped payload plist (`general/payloads`).
    var payloadsPlist: String
    var scope: ClassicScope
    /// The `<scope>` element exactly as Jamf Pro returned it, used to back up and restore scope.
    var rawScopeXML: String

    /// The parsed payload plist, or the reason it couldn't be parsed.
    var document: Result<ProfileDocument, PlistParseError>
}

/// One entry of `PayloadContent`.
nonisolated struct PayloadInfo: Hashable, Sendable, Identifiable {
    var index: Int
    var type: String?
    var identifier: String?
    var uuid: String?
    var displayName: String?
    var content: PlistDictionary

    var id: Int { index }
}

/// The parsed top-level configuration profile dictionary.
nonisolated struct ProfileDocument: Hashable, Sendable {
    var root: PlistDictionary
    var payloadIdentifier: String?
    var payloadUUID: String?
    var payloadDisplayName: String?
    var payloads: [PayloadInfo]
    /// `PayloadContent` was missing or wasn't an array of dictionaries.
    var hasMalformedPayloadContent: Bool

    init(root: PlistDictionary) {
        self.root = root
        payloadIdentifier = root.string("PayloadIdentifier")
        payloadUUID = root.string("PayloadUUID")
        payloadDisplayName = root.string("PayloadDisplayName")

        var malformed = false
        var payloads: [PayloadInfo] = []
        if let array = root["PayloadContent"]?.arrayValue {
            for (index, element) in array.enumerated() {
                guard let dict = element.dictValue else {
                    malformed = true
                    continue
                }
                payloads.append(PayloadInfo(
                    index: index,
                    type: dict.string("PayloadType"),
                    identifier: dict.string("PayloadIdentifier"),
                    uuid: dict.string("PayloadUUID"),
                    displayName: dict.string("PayloadDisplayName"),
                    content: dict
                ))
            }
        } else {
            malformed = true
        }
        self.payloads = payloads
        hasMalformedPayloadContent = malformed
    }
}
