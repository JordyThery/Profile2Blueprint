import Foundation

/// Synthetic Classic API responses for offline demo mode and tests.
///
/// Shapes mirror real `GET /osxconfigurationprofiles/id/{id}` XML: the payload plist
/// is XML-escaped inside `general/payloads`, `level` is `System`/`User`, and
/// `general/uuid` carries the top-level PayloadIdentifier.
nonisolated enum DemoFixtures {
    // MARK: Fixture 1 — the JNUC demo profile

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
        name: "Classic – Root CA and Update Deadline",
        uuid: "A1B2C3D4-0001-4000-8000-000000000103",
        plist: plist("""
        <key>PayloadUUID</key><string>A1B2C3D4-0001-4000-8000-000000000103</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>A1B2C3D4-0001-4000-8000-000000000103</string>
        <key>PayloadDisplayName</key><string>Classic – Root CA and Update Deadline</string>
        <key>PayloadVersion</key><integer>1</integer>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.security.root</string>
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

    // MARK: Collections

    /// All demo profiles keyed by Classic ID.
    static let profilesByID: [Int: String] = [
        101: managedLoginItems,
        102: securityBaseline,
        103: certificatesAndDates,
        104: corporateFonts,
        105: wifiAllComputers,
        106: userDock,
        107: uploadedPPPC,
    ]

    static var profileListXML: String {
        let items = profilesByID.keys.sorted().compactMap { id -> String? in
            guard let xml = profilesByID[id],
                  let name = xml.firstMatch(of: /<general><id>\d+<\/id><name>([^<]*)<\/name>/)?.1 else { return nil }
            return "<os_x_configuration_profile><id>\(id)</id><name>\(name)</name></os_x_configuration_profile>"
        }
        return #"<?xml version="1.0" encoding="UTF-8"?><os_x_configuration_profiles><size>\#(items.count)</size>\#(items.joined())</os_x_configuration_profiles>"#
    }

    /// Platform device groups for demo mode. "Designers" is deliberately ambiguous
    /// and "Finance" deliberately missing.
    static let platformGroups: [PlatformGroup] = [
        PlatformGroup(id: engineersPlatformGroupID, name: "Engineers", description: "", deviceType: .computer, groupType: .staticGroup, memberCount: 12),
        PlatformGroup(id: "7c3d9e1f-2a4b-4c5d-8e6f-7a8b9c0d1e2f", name: "Designers", description: "Smart", deviceType: .computer, groupType: .smart, memberCount: 5),
        PlatformGroup(id: "9e5f1a3b-4c6d-4e7f-8a9b-0c1d2e3f4a5b", name: "Designers", description: "Static", deviceType: .computer, groupType: .staticGroup, memberCount: 3),
        PlatformGroup(id: "1f2e3d4c-5b6a-4978-8a9b-c0d1e2f3a4b5", name: "All Managed Clients", description: "", deviceType: .computer, groupType: .smart, memberCount: 48),
    ]

    // MARK: Builders

    private static func plist(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1"><dict>\(body)</dict></plist>
        """
    }

    private static func scopeXML(groups: [(Int, String)]) -> String {
        let groupXML = groups.map { "<computer_group><id>\($0.0)</id><name>\(escape($0.1))</name></computer_group>" }.joined()
        return """
        <scope><all_computers>false</all_computers><all_jss_users>false</all_jss_users><computers/><buildings/><departments/>\
        <computer_groups>\(groupXML)</computer_groups><jss_users/><jss_user_groups/>\
        <limitations><users/><user_groups/><network_segments/><ibeacons/></limitations>\
        <exclusions><computers/><buildings/><departments/><computer_groups/><users/><user_groups/><network_segments/><ibeacons/><jss_users/><jss_user_groups/></exclusions></scope>
        """
    }

    private static func profileXML(
        id: Int, name: String, description: String = "", level: String = "System",
        uuid: String, plist: String, scope: String
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><os_x_configuration_profile><general><id>\(id)</id><name>\(escape(name))</name>\
        <description>\(escape(description))</description><site><id>-1</id><name>None</name></site>\
        <category><id>-1</id><name>No category assigned</name></category><distribution_method>Install Automatically</distribution_method>\
        <user_removable>false</user_removable><level>\(level)</level><uuid>\(uuid)</uuid><redeploy_on_update>Newly Assigned</redeploy_on_update>\
        <payloads>\(escape(plist))</payloads></general>\(scope)</os_x_configuration_profile>
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
    private var profilesXML: [Int: String] = DemoFixtures.profilesByID
    private(set) var scopeWrites: [(id: Int, body: String)] = []

    func list() -> String { DemoFixtures.profileListXML }

    func profileXML(id: Int) throws -> String {
        guard let xml = profilesXML[id] else {
            throw APIError.http(status: 404, method: "GET", path: "proclassic/osxconfigurationprofiles/id/\(id)", body: nil, rawBody: nil)
        }
        return xml
    }

    /// Mimics a Classic partial update: replaces only `<scope>`.
    func putScope(id: Int, body: Data) throws {
        guard HTTPClient.isScopeOnlyProfileXML(body) else {
            throw APIError.http(status: 400, method: "PUT", path: "proclassic/osxconfigurationprofiles/id/\(id)", body: nil, rawBody: "Not a scope-only body")
        }
        guard let xml = profilesXML[id],
              let document = try? XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace]),
              let root = document.rootElement(),
              let newScope = try? XMLDocument(data: body).rootElement()?.elements(forName: "scope").first?.copy() as? XMLElement else {
            throw APIError.http(status: 404, method: "PUT", path: "proclassic/osxconfigurationprofiles/id/\(id)", body: nil, rawBody: nil)
        }
        if let old = root.elements(forName: "scope").first { root.removeChild(at: old.index) }
        root.addChild(newScope)
        profilesXML[id] = document.xmlString
        scopeWrites.append((id, String(decoding: body, as: UTF8.self)))
    }
}

/// Offline Classic API backed by `DemoClassicServer`.
nonisolated struct DemoClassicAPI: ClassicAPI {
    var server = DemoClassicServer()

    func listProfiles() async throws -> [ClassicProfileSummary] {
        try ClassicXMLParser.parseProfileList(Data(await server.list().utf8))
    }

    func profile(id: Int) async throws -> ClassicProfile {
        try ClassicXMLParser.parseProfile(Data(try await server.profileXML(id: id).utf8))
    }
}

nonisolated struct DemoClassicScopeWriter: ClassicScopeWriter {
    let server: DemoClassicServer

    func replaceScope(profileID: Int, body: Data) async throws {
        try await server.putScope(id: profileID, body: body)
    }
}

/// Offline device groups backed by `DemoFixtures`.
nonisolated struct DemoDeviceGroupsAPI: DeviceGroupsAPI {
    func listGroups(filter: String?) async throws -> [PlatformGroup] {
        DemoFixtures.platformGroups
    }
}
