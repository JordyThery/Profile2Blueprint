import Foundation
import JTKit

/// Synthetic Classic API responses for offline demo mode and tests.
///
/// Shapes mirror real `GET /osxconfigurationprofiles/id/{id}` XML: the payload plist
/// is XML-escaped inside `general/payloads`, `level` is `System`/`User`, and
/// `general/uuid` carries the top-level PayloadIdentifier.
nonisolated enum DemoFixtures {
    // MARK: Fixture 1 — modelled on the profile from Jamf's JNUC transform demo

    static let managedLoginItemsTopUUID = "8F2A6C1E-3B4D-4E5F-9A7B-1C2D3E4F5A6B"
    static let managedLoginItemsPayloadUUID = "2D9E7C41-5A3B-4C8D-9E1F-0A2B3C4D5E6F"
    static let engineersPlatformGroupID = "5b1f7c2e-8d4a-4e3b-9c6f-1a2b3c4d5e6f"

    static let managedLoginItems = profileXML(
        id: 101,
        name: "Classic – Managed Login Items",
        description: "Allow Google login items",
        uuid: managedLoginItemsTopUUID,
        plist: plist("""
        <key>PayloadUUID</key><string>\(managedLoginItemsTopUUID)</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadOrganization</key><string>Example Org</string>
        <key>PayloadIdentifier</key><string>\(managedLoginItemsTopUUID)</string>
        <key>PayloadDisplayName</key><string>Classic – Managed Login Items</string>
        <key>PayloadDescription</key><string/>
        <key>PayloadVersion</key><integer>1</integer>
        <key>PayloadEnabled</key><true/>
        <key>PayloadRemovalDisallowed</key><true/>
        <key>PayloadScope</key><string>System</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadDisplayName</key><string>Service Management - Managed Login Items</string>
            <key>PayloadIdentifier</key><string>\(managedLoginItemsPayloadUUID)</string>
            <key>PayloadOrganization</key><string>Example Org</string>
            <key>PayloadType</key><string>com.apple.servicemanagement</string>
            <key>PayloadUUID</key><string>\(managedLoginItemsPayloadUUID)</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>Rules</key>
            <array>
              <dict>
                <key>RuleType</key><string>BundleIdentifierPrefix</string>
                <key>RuleValue</key><string>com.google</string>
              </dict>
            </array>
          </dict>
        </array>
        """),
        scope: scopeXML(groups: [(3, "Engineers")])
    )

    // MARK: Fixture 2 — multiple payloads (order + count)

    static let securityBaseline = profileXML(
        id: 102,
        name: "Classic – Security Baseline",
        uuid: "A1B2C3D4-0001-4000-8000-000000000102",
        plist: plist("""
        <key>PayloadUUID</key><string>A1B2C3D4-0001-4000-8000-000000000102</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>A1B2C3D4-0001-4000-8000-000000000102</string>
        <key>PayloadDisplayName</key><string>Classic – Security Baseline</string>
        <key>PayloadVersion</key><integer>1</integer>
        <key>PayloadScope</key><string>System</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.notificationsettings</string>
            <key>PayloadIdentifier</key><string>B0000000-0000-4000-8000-000000000001</string>
            <key>PayloadUUID</key><string>B0000000-0000-4000-8000-000000000001</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadDisplayName</key><string>Notifications</string>
            <key>NotificationSettings</key>
            <array>
              <dict>
                <key>BundleIdentifier</key><string>com.apple.btmnotificationagent</string>
                <key>CriticalAlertEnabled</key><true/>
                <key>NotificationsEnabled</key><false/>
                <key>AlertType</key><integer>1</integer>
              </dict>
            </array>
          </dict>
          <dict>
            <key>PayloadType</key><string>com.apple.servicemanagement</string>
            <key>PayloadIdentifier</key><string>B0000000-0000-4000-8000-000000000002</string>
            <key>PayloadUUID</key><string>B0000000-0000-4000-8000-000000000002</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>Rules</key>
            <array>
              <dict><key>RuleType</key><string>TeamIdentifier</string><key>RuleValue</key><string>EQHXZ8M8AV</string><key>Comment</key><string>Google</string></dict>
              <dict><key>RuleType</key><string>BundleIdentifier</string><key>RuleValue</key><string>com.example.agent</string></dict>
            </array>
          </dict>
          <dict>
            <key>PayloadType</key><string>com.apple.ManagedClient.preferences</string>
            <key>PayloadIdentifier</key><string>B0000000-0000-4000-8000-000000000003</string>
            <key>PayloadUUID</key><string>B0000000-0000-4000-8000-000000000003</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadContent</key>
            <dict>
              <key>com.apple.screensaver</key>
              <dict>
                <key>Forced</key>
                <array>
                  <dict>
                    <key>mcx_preference_settings</key>
                    <dict>
                      <key>askForPassword</key><true/>
                      <key>askForPasswordDelay</key><integer>0</integer>
                      <key>idleTime</key><integer>600</integer>
                    </dict>
                  </dict>
                </array>
              </dict>
            </dict>
          </dict>
        </array>
        """),
        scope: scopeXML(groups: [(3, "Engineers"), (7, "Designers")])
    )

    // MARK: Fixture 3 — <data>, <date> and <real>

    static let certificateDER = Data([0x30, 0x82, 0x01, 0x0A, 0x02, 0x82, 0x01, 0x01, 0x00, 0xC3, 0xFF, 0x10, 0x7E])
    static let configuredDateISO = "2026-01-15T00:00:00Z"

    static let certificatesAndDates = profileXML(
        id: 103,
        name: "Classic – Certificate Preference and Update Deadline",
        uuid: "A1B2C3D4-0001-4000-8000-000000000103",
        plist: plist("""
        <key>PayloadUUID</key><string>A1B2C3D4-0001-4000-8000-000000000103</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>A1B2C3D4-0001-4000-8000-000000000103</string>
        <key>PayloadDisplayName</key><string>Classic – Certificate Preference and Update Deadline</string>
        <key>PayloadVersion</key><integer>1</integer>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.security.certificatepreference</string>
            <key>PayloadIdentifier</key><string>C0000000-0000-4000-8000-000000000001</string>
            <key>PayloadUUID</key><string>C0000000-0000-4000-8000-000000000001</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadCertificateFileName</key><string>Example Root CA.cer</string>
            <key>PayloadContent</key>
            <data>
            \(certificateDER.base64EncodedString())
            </data>
          </dict>
          <dict>
            <key>PayloadType</key><string>com.apple.ManagedClient.preferences</string>
            <key>PayloadIdentifier</key><string>C0000000-0000-4000-8000-000000000002</string>
            <key>PayloadUUID</key><string>C0000000-0000-4000-8000-000000000002</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadContent</key>
            <dict>
              <key>com.example.updater</key>
              <dict>
                <key>Forced</key>
                <array>
                  <dict>
                    <key>mcx_preference_settings</key>
                    <dict>
                      <key>Deadline</key><date>\(configuredDateISO)</date>
                      <key>Ratio</key><real>0.75</real>
                      <key>Banner</key><string>  Leading &amp; trailing spaces kept  </string>
                    </dict>
                  </dict>
                </array>
              </dict>
            </dict>
          </dict>
        </array>
        """),
        scope: scopeXML(groups: [(11, "Finance")])
    )

    // MARK: Fixture 4 — blocked payload type

    static let corporateFonts = profileXML(
        id: 104,
        name: "Classic – Corporate Fonts",
        uuid: "A1B2C3D4-0001-4000-8000-000000000104",
        plist: plist("""
        <key>PayloadUUID</key><string>A1B2C3D4-0001-4000-8000-000000000104</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>A1B2C3D4-0001-4000-8000-000000000104</string>
        <key>PayloadDisplayName</key><string>Classic – Corporate Fonts</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.font</string>
            <key>PayloadIdentifier</key><string>D0000000-0000-4000-8000-000000000001</string>
            <key>PayloadUUID</key><string>D0000000-0000-4000-8000-000000000001</string>
            <key>Name</key><string>ExampleSans.ttf</string>
            <key>Font</key><data>AAEAAAALAIAAAwAw</data>
          </dict>
        </array>
        """),
        scope: scopeXML(groups: [(3, "Engineers")])
    )

    // MARK: Fixture 5 — All computers + exclusions

    static let wifiAllComputers = profileXML(
        id: 105,
        name: "Classic – Office Wi-Fi",
        uuid: "A1B2C3D4-0001-4000-8000-000000000105",
        plist: plist("""
        <key>PayloadUUID</key><string>A1B2C3D4-0001-4000-8000-000000000105</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>A1B2C3D4-0001-4000-8000-000000000105</string>
        <key>PayloadDisplayName</key><string>Classic – Office Wi-Fi</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.wifi.managed</string>
            <key>PayloadIdentifier</key><string>E0000000-0000-4000-8000-000000000001</string>
            <key>PayloadUUID</key><string>E0000000-0000-4000-8000-000000000001</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>SSID_STR</key><string>Example-Office</string>
            <key>EncryptionType</key><string>WPA2</string>
            <key>AutoJoin</key><true/>
            <key>HIDDEN_NETWORK</key><false/>
          </dict>
        </array>
        """),
        scope: """
        <scope><all_computers>true</all_computers><all_jss_users>false</all_jss_users>
        <computers/><buildings><building><id>2</id><name>HQ</name></building></buildings><departments/><computer_groups/>
        <jss_users/><jss_user_groups/>
        <limitations><users/><user_groups/><network_segments><network_segment><id>4</id><name>Office LAN</name></network_segment></network_segments><ibeacons/></limitations>
        <exclusions><computers><computer><id>77</id><name>KIOSK-01</name><udid>11111111-2222-3333-4444-555555555555</udid></computer></computers>
        <buildings/><departments/><computer_groups><computer_group><id>9</id><name>Lab Machines</name></computer_group></computer_groups>
        <users/><user_groups/><network_segments/><ibeacons/><jss_users/><jss_user_groups/></exclusions></scope>
        """
    )

    // MARK: Extra — user-level profile (blocked in v1)

    static let userDock = profileXML(
        id: 106,
        name: "Classic – User Dock Settings",
        level: "User",
        uuid: "A1B2C3D4-0001-4000-8000-000000000106",
        plist: plist("""
        <key>PayloadUUID</key><string>A1B2C3D4-0001-4000-8000-000000000106</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>A1B2C3D4-0001-4000-8000-000000000106</string>
        <key>PayloadDisplayName</key><string>Classic – User Dock Settings</string>
        <key>PayloadScope</key><string>User</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.dock</string>
            <key>PayloadIdentifier</key><string>F0000000-0000-4000-8000-000000000001</string>
            <key>PayloadUUID</key><string>F0000000-0000-4000-8000-000000000001</string>
            <key>autohide</key><true/>
          </dict>
        </array>
        """),
        scope: scopeXML(groups: [(3, "Engineers")])
    )

    // MARK: Extra — uploaded profile whose PayloadUUID differs from Jamf's record UUID

    static let uploadedPPPC = profileXML(
        id: 107,
        name: "Classic – Uploaded PPPC",
        uuid: "com.example.pppc.terminal",
        plist: plist("""
        <key>PayloadUUID</key><string>9C8B7A6D-5E4F-4321-8765-0FEDCBA98765</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>com.example.pppc.terminal</string>
        <key>PayloadDisplayName</key><string>Classic – Uploaded PPPC</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.TCC.configuration-profile-policy</string>
            <key>PayloadIdentifier</key><string>com.example.pppc.terminal.tcc</string>
            <key>PayloadUUID</key><string>1A2B3C4D-5E6F-4A0B-8C1D-2E3F4A5B6C7D</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>Services</key>
            <dict>
              <key>SystemPolicyAllFiles</key>
              <array>
                <dict>
                  <key>Identifier</key><string>com.apple.Terminal</string>
                  <key>IdentifierType</key><string>bundleID</string>
                  <key>CodeRequirement</key><string>identifier "com.apple.Terminal" and anchor apple</string>
                  <key>Allowed</key><true/>
                </dict>
              </array>
            </dict>
          </dict>
        </array>
        """),
        scope: scopeXML(groups: [(3, "Engineers")])
    )

    // MARK: Mobile fixture 1 — single lock screen payload (the hardware-verified shape)

    static let iphoneLockScreenTopUUID = "6B5ECD21-C8FA-44DF-AC99-9F533C36D6E8"

    static let iphoneLockScreen = profileXML(
        platform: .mobile,
        id: 201,
        name: "Demo – iPhone Lock Screen Message",
        description: "Serial number on the lock screen",
        uuid: iphoneLockScreenTopUUID,
        plist: plist("""
        <key>PayloadUUID</key><string>\(iphoneLockScreenTopUUID)</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>\(iphoneLockScreenTopUUID)</string>
        <key>PayloadDisplayName</key><string>Demo – iPhone Lock Screen Message</string>
        <key>PayloadVersion</key><integer>1</integer>
        <key>PayloadScope</key><string>System</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.shareddeviceconfiguration</string>
            <key>PayloadIdentifier</key><string>AB000000-0000-4000-8000-000000000001</string>
            <key>PayloadUUID</key><string>AB000000-0000-4000-8000-000000000001</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>IfLostReturnToMessage</key><string>$SERIALNUMBER</string>
            <key>LockScreenFootnote</key><string>$SERIALNUMBER</string>
          </dict>
        </array>
        """),
        scope: scopeXML(platform: .mobile, groups: [(12, "Field iPhones")])
    )

    // MARK: Mobile fixture 2 — blocked payload type (web clip)

    static let ipadWebClip = profileXML(
        platform: .mobile,
        id: 202,
        name: "Demo – iPad Help Desk Web Clip",
        uuid: "6B5ECD21-0002-4000-8000-000000000202",
        plist: plist("""
        <key>PayloadUUID</key><string>6B5ECD21-0002-4000-8000-000000000202</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>6B5ECD21-0002-4000-8000-000000000202</string>
        <key>PayloadDisplayName</key><string>Demo – iPad Help Desk Web Clip</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.webClip.managed</string>
            <key>PayloadIdentifier</key><string>AB000000-0000-4000-8000-000000000002</string>
            <key>PayloadUUID</key><string>AB000000-0000-4000-8000-000000000002</string>
            <key>Label</key><string>Help Desk</string>
            <key>URL</key><string>https://example.com/help</string>
          </dict>
        </array>
        """),
        scope: scopeXML(platform: .mobile, groups: [(13, "Classroom iPads")])
    )

    // MARK: Collections

    /// macOS demo profiles keyed by Classic ID.
    static let profilesByID: [Int: String] = [
        101: managedLoginItems,
        102: securityBaseline,
        103: certificatesAndDates,
        104: corporateFonts,
        105: wifiAllComputers,
        106: userDock,
        107: uploadedPPPC,
    ]

    /// Mobile demo profiles keyed by Classic ID. IDs deliberately reuse no macOS ID,
    /// except in tests that construct collisions on purpose.
    static let mobileProfilesByID: [Int: String] = [
        201: iphoneLockScreen,
        202: ipadWebClip,
    ]

    /// All demo profiles of both platforms.
    static let profilesByKey: [ProfileKey: String] = {
        var all: [ProfileKey: String] = [:]
        for (id, xml) in profilesByID { all[ProfileKey(platform: .macOS, id: id)] = xml }
        for (id, xml) in mobileProfilesByID { all[ProfileKey(platform: .mobile, id: id)] = xml }
        return all
    }()

    static func profileListXML(platform: ProfilePlatform) -> String {
        let byID = platform == .macOS ? profilesByID : mobileProfilesByID
        let items = byID.keys.sorted().compactMap { id -> String? in
            guard let xml = byID[id],
                  let name = xml.firstMatch(of: /<general><id>\d+<\/id><name>([^<]*)<\/name>/)?.1 else { return nil }
            return "<\(platform.profileRootElement)><id>\(id)</id><name>\(name)</name></\(platform.profileRootElement)>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?><\(platform.listRootElement)><size>\(items.count)</size>\(items.joined())</\(platform.listRootElement)>
        """
    }

    static let fieldiPhonesPlatformGroupID = "ab12cd34-0001-4000-8000-5e6f7a8b9c0d"

    /// Platform device groups for demo mode. "Designers" is deliberately ambiguous,
    /// "Finance" deliberately missing, and "Engineers" also exists as a MOBILE group
    /// so per-platform matching is exercised.
    static let platformGroups: [JamfPlatform.DeviceGroup] = [
        JamfPlatform.DeviceGroup(id: engineersPlatformGroupID, name: "Engineers", description: "", deviceType: .computer, groupType: .static, memberCount: 12),
        JamfPlatform.DeviceGroup(id: "7c3d9e1f-2a4b-4c5d-8e6f-7a8b9c0d1e2f", name: "Designers", description: "Smart", deviceType: .computer, groupType: .smart, memberCount: 5),
        JamfPlatform.DeviceGroup(id: "9e5f1a3b-4c6d-4e7f-8a9b-0c1d2e3f4a5b", name: "Designers", description: "Static", deviceType: .computer, groupType: .static, memberCount: 3),
        JamfPlatform.DeviceGroup(id: "1f2e3d4c-5b6a-4978-8a9b-c0d1e2f3a4b5", name: "All Managed Clients", description: "", deviceType: .computer, groupType: .smart, memberCount: 48),
        JamfPlatform.DeviceGroup(id: fieldiPhonesPlatformGroupID, name: "Field iPhones", description: "", deviceType: .mobile, groupType: .smart, memberCount: 7),
        JamfPlatform.DeviceGroup(id: "ab12cd34-0002-4000-8000-5e6f7a8b9c0d", name: "Classroom iPads", description: "", deviceType: .mobile, groupType: .static, memberCount: 24),
        JamfPlatform.DeviceGroup(id: "ab12cd34-0003-4000-8000-5e6f7a8b9c0d", name: "Engineers", description: "Mobile twin of the computer group", deviceType: .mobile, groupType: .smart, memberCount: 4),
    ]

    // MARK: Builders

    private static func plist(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1"><dict>\(body)</dict></plist>
        """
    }

    private static func scopeXML(platform: ProfilePlatform = .macOS, groups: [(Int, String)]) -> String {
        let entry = String(platform.deviceGroupsElement.dropLast(1))
        let groupXML = groups.map { "<\(entry)><id>\($0.0)</id><name>\(escape($0.1))</name></\(entry)>" }.joined()
        return """
        <scope><\(platform.allDevicesElement)>false</\(platform.allDevicesElement)><all_jss_users>false</all_jss_users><\(platform.devicesElement)/><buildings/><departments/>\
        <\(platform.deviceGroupsElement)>\(groupXML)</\(platform.deviceGroupsElement)><jss_users/><jss_user_groups/>\
        <limitations><users/><user_groups/><network_segments/><ibeacons/></limitations>\
        <exclusions><\(platform.devicesElement)/><buildings/><departments/><\(platform.deviceGroupsElement)/><users/><user_groups/><network_segments/><ibeacons/><jss_users/><jss_user_groups/></exclusions></scope>
        """
    }

    private static func profileXML(
        platform: ProfilePlatform = .macOS,
        id: Int, name: String, description: String = "", level: String = "System",
        uuid: String, plist: String, scope: String
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><\(platform.profileRootElement)><general><id>\(id)</id><name>\(escape(name))</name>\
        <description>\(escape(description))</description><site><id>-1</id><name>None</name></site>\
        <category><id>-1</id><name>No category assigned</name></category><distribution_method>Install Automatically</distribution_method>\
        <user_removable>false</user_removable><level>\(level)</level><uuid>\(uuid)</uuid><redeploy_on_update>Newly Assigned</redeploy_on_update>\
        <payloads>\(escape(plist))</payloads></general>\(scope)</\(platform.profileRootElement)>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Mutable in-memory Classic "server" for demo mode, so unscope/restore can be tried.
actor DemoClassicServer {
    private var profilesXML: [ProfileKey: String] = DemoFixtures.profilesByKey
    private(set) var scopeWrites: [(key: ProfileKey, body: String)] = []

    func list(platform: ProfilePlatform) -> String { DemoFixtures.profileListXML(platform: platform) }

    func profileXML(key: ProfileKey) throws -> String {
        guard let xml = profilesXML[key] else {
            throw JamfPlatformError(.status(404, body: nil, text: nil, method: "GET", path: "proclassic/\(key.platform.classicResource)/id/\(key.id)"))
        }
        return xml
    }

    /// Mimics a Classic partial update: replaces only `<scope>`.
    func putScope(key: ProfileKey, body: Data) throws {
        guard RequestPolicy.isScopeOnlyProfileXML(body) else {
            throw JamfPlatformError(.status(400, body: nil, text: "Not a scope-only body", method: "PUT", path: "proclassic/\(key.platform.classicResource)/id/\(key.id)"))
        }
        guard let xml = profilesXML[key],
              let document = try? XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace]),
              let root = document.rootElement(),
              let newScope = try? XMLDocument(data: body).rootElement()?.elements(forName: "scope").first?.copy() as? XMLElement else {
            throw JamfPlatformError(.status(404, body: nil, text: nil, method: "PUT", path: "proclassic/\(key.platform.classicResource)/id/\(key.id)"))
        }
        if let old = root.elements(forName: "scope").first { root.removeChild(at: old.index) }
        root.addChild(newScope)
        profilesXML[key] = document.xmlString
        scopeWrites.append((key, String(decoding: body, as: UTF8.self)))
    }
}

/// Offline Classic API backed by `DemoClassicServer`.
nonisolated struct DemoClassicAPI: ClassicAPI {
    var server = DemoClassicServer()

    func listProfiles(platform: ProfilePlatform) async throws -> [ClassicProfileSummary] {
        try ClassicXMLParser.parseProfileList(Data(await server.list(platform: platform).utf8), platform: platform)
    }

    func profile(key: ProfileKey) async throws -> ClassicProfile {
        try ClassicXMLParser.parseProfile(Data(try await server.profileXML(key: key).utf8), platform: key.platform)
    }
}

nonisolated struct DemoClassicScopeWriter: ClassicScopeWriter {
    let server: DemoClassicServer

    func replaceScope(key: ProfileKey, body: Data) async throws {
        try await server.putScope(key: key, body: body)
    }
}
