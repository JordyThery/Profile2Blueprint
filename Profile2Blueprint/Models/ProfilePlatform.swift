import Foundation
import JTKit

/// The classic profile family: Jamf Pro keeps macOS and mobile device profiles in
/// two separate Classic APIs with their own IDs, XML element names and scope shape.
/// Everything that differs between the two lives here, so the rest of the app can
/// treat a profile the same whichever family it came from.
nonisolated enum ProfilePlatform: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case macOS = "macos"
    case mobile = "mobile"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .mobile: "Mobile"
        }
    }

    /// What one scope target is called ("computer" / "mobile device").
    var deviceNoun: String {
        switch self {
        case .macOS: "computer"
        case .mobile: "mobile device"
        }
    }

    /// The `{platform}` description-token value.
    var descriptionNoun: String {
        switch self {
        case .macOS: "macOS"
        case .mobile: "mobile device"
        }
    }

    /// Classic API resource under `proclassic/`.
    var classicResource: String {
        switch self {
        case .macOS: "osxconfigurationprofiles"
        case .mobile: "mobiledeviceconfigurationprofiles"
        }
    }

    /// The Jamf Pro privilege for reading this family's profiles.
    var readPrivilege: JamfPro.Privilege {
        switch self {
        case .macOS: .readMacOSConfigurationProfiles
        case .mobile: .readIOSConfigurationProfiles
        }
    }

    /// The Jamf Pro privilege for changing a profile's scope.
    var updatePrivilege: JamfPro.Privilege {
        switch self {
        case .macOS: .updateMacOSConfigurationProfiles
        case .mobile: .updateIOSConfigurationProfiles
        }
    }

    /// The key of the list in the JSON list response.
    var listRootElement: String {
        switch self {
        case .macOS: "os_x_configuration_profiles"
        case .mobile: "configuration_profiles"
        }
    }

    /// XML root of a single profile.
    var profileRootElement: String {
        switch self {
        case .macOS: "os_x_configuration_profile"
        case .mobile: "configuration_profile"
        }
    }

    /// `<scope>` child element names.
    var allDevicesElement: String {
        switch self {
        case .macOS: "all_computers"
        case .mobile: "all_mobile_devices"
        }
    }

    var devicesElement: String {
        switch self {
        case .macOS: "computers"
        case .mobile: "mobile_devices"
        }
    }

    var deviceGroupsElement: String {
        switch self {
        case .macOS: "computer_groups"
        case .mobile: "mobile_device_groups"
        }
    }

    /// The platform device-group type a profile of this family can target.
    var deviceGroupType: JamfPlatform.DeviceGroup.DeviceType {
        switch self {
        case .macOS: .computer
        case .mobile: .mobile
        }
    }

    /// The Jamf Pro console page for a classic profile of this family.
    var jamfProProfilePage: String {
        switch self {
        case .macOS: "OSXConfigurationProfiles.html"
        case .mobile: "iOSConfigurationProfiles.html"
        }
    }

    var symbol: String {
        switch self {
        case .macOS: "desktopcomputer"
        case .mobile: "iphone"
        }
    }
}

/// Identifies one classic profile. The two Classic APIs number their profiles
/// independently — both can have a profile 10 — so an ID alone is ambiguous.
nonisolated struct ProfileKey: Hashable, Sendable, Codable, Comparable {
    var platform: ProfilePlatform
    var id: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.platform.rawValue == rhs.platform.rawValue
            ? lhs.id < rhs.id
            : lhs.platform.rawValue < rhs.platform.rawValue
    }
}
