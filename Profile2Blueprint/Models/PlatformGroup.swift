import Foundation

nonisolated enum DeviceType: String, Codable, Hashable, Sendable {
    case computer = "COMPUTER"
    case mobile = "MOBILE"
    case unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeviceType(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .computer: "Computer"
        case .mobile: "Mobile"
        case .unknown: "Unknown"
        }
    }
}

nonisolated enum GroupType: String, Codable, Hashable, Sendable {
    case smart = "SMART"
    case staticGroup = "STATIC"
    case unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GroupType(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .smart: "Smart"
        case .staticGroup: "Static"
        case .unknown: "Unknown"
        }
    }
}

/// A Jamf platform device group (`DeviceGroupListReadRepresentationV1`).
nonisolated struct PlatformGroup: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String?
    var deviceType: DeviceType
    var groupType: GroupType
    var memberCount: Int
}

/// The platform APIs' paginated envelope.
nonisolated struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    var page: Int
    var pageSize: Int
    var totalCount: Int
    var totalPages: Int
    var hasNext: Bool
    var hasPrevious: Bool
    var results: [Item]
}
