import Foundation
import JTKit

/// Synthetic Classic API responses for demo mode and tests, in Contoso's
/// sample data (JTKit's `DemoSamples` rules: IDs in the reserved fake range,
/// `com.contoso.example` identifiers).
///
/// Shapes mirror real `GET /osxconfigurationprofiles/id/{id}` XML: the payload plist
/// is XML-escaped inside `general/payloads`, `level` is `System`/`User`, and
/// `general/uuid` carries the top-level PayloadIdentifier.
nonisolated enum DemoFixtures {
    // MARK: Fixture 1 — modeled on the profile from Jamf's JNUC transform demo

    static let managedLoginItemsTopUUID = "00000000-0000-4000-8000-00000000A101"
    static let managedLoginItemsPayloadUUID = "00000000-0000-4000-8000-00000000A111"
    /// Contoso's "Engineering Macs" (JTKit's `DemoSamples.platformGroups`).
    static let engineersPlatformGroupID = DemoSamples.uuid(0xd603)

    static let managedLoginItems = profileXML(
        id: 101,
        name: "Contoso – Managed Login Items",
        description: "Allow Google login items",
        uuid: managedLoginItemsTopUUID,
        plist: plist("""
        <key>PayloadUUID</key><string>\(managedLoginItemsTopUUID)</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadOrganization</key><string>Contoso</string>
        <key>PayloadIdentifier</key><string>\(managedLoginItemsTopUUID)</string>
        <key>PayloadDisplayName</key><string>Contoso – Managed Login Items</string>
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
            <key>PayloadOrganization</key><string>Contoso</string>
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
        scope: scopeXML(groups: [(3, "Engineering Macs")])
    )

    // MARK: Fixture 2 — multiple payloads (order + count)

    static let securityBaseline = profileXML(
        id: 102,
        name: "Contoso – Security Baseline",
        uuid: "00000000-0000-4000-8000-00000000A102",
        plist: plist("""
        <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000A102</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000A102</string>
        <key>PayloadDisplayName</key><string>Contoso – Security Baseline</string>
        <key>PayloadVersion</key><integer>1</integer>
        <key>PayloadScope</key><string>System</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.notificationsettings</string>
            <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000B101</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000B101</string>
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
            <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000B102</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000B102</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>Rules</key>
            <array>
              <dict><key>RuleType</key><string>TeamIdentifier</string><key>RuleValue</key><string>EQHXZ8M8AV</string><key>Comment</key><string>Google</string></dict>
              <dict><key>RuleType</key><string>BundleIdentifier</string><key>RuleValue</key><string>com.contoso.example.agent</string></dict>
            </array>
          </dict>
          <dict>
            <key>PayloadType</key><string>com.apple.ManagedClient.preferences</string>
            <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000B103</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000B103</string>
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
        scope: scopeXML(groups: [(3, "Engineering Macs"), (7, "Design Macs")])
    )

    // MARK: Fixture 3 — <data>, <date> and <real>

    static let certificateDER = Data([0x30, 0x82, 0x01, 0x0A, 0x02, 0x82, 0x01, 0x01, 0x00, 0xC3, 0xFF, 0x10, 0x7E])
    static let configuredDateISO = "2026-01-15T00:00:00Z"

    static let certificatesAndDates = profileXML(
        id: 103,
        name: "Contoso – Certificate Preference and Update Deadline",
        uuid: "00000000-0000-4000-8000-00000000A103",
        plist: plist("""
        <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000A103</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000A103</string>
        <key>PayloadDisplayName</key><string>Contoso – Certificate Preference and Update Deadline</string>
        <key>PayloadVersion</key><integer>1</integer>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.security.certificatepreference</string>
            <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000C101</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000C101</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadCertificateFileName</key><string>Contoso Root CA.cer</string>
            <key>PayloadContent</key>
            <data>
            \(certificateDER.base64EncodedString())
            </data>
          </dict>
          <dict>
            <key>PayloadType</key><string>com.apple.ManagedClient.preferences</string>
            <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000C102</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000C102</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadContent</key>
            <dict>
              <key>com.contoso.example.updater</key>
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
        scope: scopeXML(groups: [(11, "Finance Macs")])
    )

    // MARK: Fixture 4 — blocked payload type

    static let corporateFonts = profileXML(
        id: 104,
        name: "Contoso – Corporate Fonts",
        uuid: "00000000-0000-4000-8000-00000000A104",
        plist: plist("""
        <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000A104</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000A104</string>
        <key>PayloadDisplayName</key><string>Contoso – Corporate Fonts</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.font</string>
            <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000D101</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000D101</string>
            <key>Name</key><string>ContosoSans.ttf</string>
            <key>Font</key><data>AAEAAAALAIAAAwAw</data>
          </dict>
        </array>
        """),
        scope: scopeXML(groups: [(3, "Engineering Macs")])
    )

    // MARK: Fixture 5 — All computers + exclusions

    static let wifiAllComputers = profileXML(
        id: 105,
        name: "Contoso – Office Wi-Fi",
        uuid: "00000000-0000-4000-8000-00000000A105",
        plist: plist("""
        <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000A105</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000A105</string>
        <key>PayloadDisplayName</key><string>Contoso – Office Wi-Fi</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.wifi.managed</string>
            <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000E101</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000E101</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>SSID_STR</key><string>Contoso-Office</string>
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
        <exclusions><computers><computer><id>77</id><name>KIOSK-01</name><udid>00000000-0000-4000-8000-0000000C1077</udid></computer></computers>
        <buildings/><departments/><computer_groups><computer_group><id>9</id><name>Lab Machines</name></computer_group></computer_groups>
        <users/><user_groups/><network_segments/><ibeacons/><jss_users/><jss_user_groups/></exclusions></scope>
        """
    )

    // MARK: Extra — user-level profile (blocked)

    static let userDock = profileXML(
        id: 106,
        name: "Contoso – User Dock Settings",
        level: "User",
        uuid: "00000000-0000-4000-8000-00000000A106",
        plist: plist("""
        <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000A106</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000A106</string>
        <key>PayloadDisplayName</key><string>Contoso – User Dock Settings</string>
        <key>PayloadScope</key><string>User</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.dock</string>
            <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000F101</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000F101</string>
            <key>autohide</key><true/>
          </dict>
        </array>
        """),
        scope: scopeXML(groups: [(3, "Engineering Macs")])
    )

    // MARK: Extra — uploaded profile whose PayloadUUID differs from Jamf's record UUID

    static let uploadedPPPC = profileXML(
        id: 107,
        name: "Contoso – Uploaded PPPC",
        uuid: "com.contoso.example.pppc.terminal",
        plist: plist("""
        <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000A107</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>com.contoso.example.pppc.terminal</string>
        <key>PayloadDisplayName</key><string>Contoso – Uploaded PPPC</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.TCC.configuration-profile-policy</string>
            <key>PayloadIdentifier</key><string>com.contoso.example.pppc.terminal.tcc</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000A117</string>
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
        scope: scopeXML(groups: [(3, "Engineering Macs")])
    )

    // MARK: Mobile fixture 1 — single lock screen payload (the hardware-verified shape)

    static let iphoneLockScreenTopUUID = "00000000-0000-4000-8000-00000000A201"

    static let iphoneLockScreen = profileXML(
        platform: .mobile,
        id: 201,
        name: "Contoso – iPhone Lock Screen Message",
        description: "Serial number on the lock screen",
        uuid: iphoneLockScreenTopUUID,
        plist: plist("""
        <key>PayloadUUID</key><string>\(iphoneLockScreenTopUUID)</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>\(iphoneLockScreenTopUUID)</string>
        <key>PayloadDisplayName</key><string>Contoso – iPhone Lock Screen Message</string>
        <key>PayloadVersion</key><integer>1</integer>
        <key>PayloadScope</key><string>System</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.shareddeviceconfiguration</string>
            <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000AB01</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000AB01</string>
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
        name: "Contoso – iPad Help Desk Web Clip",
        uuid: "00000000-0000-4000-8000-00000000A202",
        plist: plist("""
        <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000A202</string>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000A202</string>
        <key>PayloadDisplayName</key><string>Contoso – iPad Help Desk Web Clip</string>
        <key>PayloadContent</key>
        <array>
          <dict>
            <key>PayloadType</key><string>com.apple.webClip.managed</string>
            <key>PayloadIdentifier</key><string>00000000-0000-4000-8000-00000000AB02</string>
            <key>PayloadUUID</key><string>00000000-0000-4000-8000-00000000AB02</string>
            <key>Label</key><string>Help Desk</string>
            <key>URL</key><string>https://help.contoso.example</string>
          </dict>
        </array>
        """),
        scope: scopeXML(platform: .mobile, groups: [(13, "Sales iPads")])
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

    /// The list as Jamf Pro answers it when asked for JSON.
    static func profileListJSON(platform: ProfilePlatform) -> String {
        let byID = platform == .macOS ? profilesByID : mobileProfilesByID
        let items = byID.keys.sorted().compactMap { id -> String? in
            guard let xml = byID[id],
                  let name = xml.firstMatch(of: /<general><id>\d+<\/id><name>([^<]*)<\/name>/)?.1 else { return nil }
            let item = LosslessJSON.object(LosslessJSON.Object([
                "id": .number(LosslessJSON.Number(id)), "name": .string(unescape(String(name))),
            ]))
            return item.serializedString()
        }
        return #"{"\#(platform.listRootElement)":[\#(items.joined(separator: ","))]}"#
    }

    /// Contoso's "Field iPhones".
    static let fieldiPhonesPlatformGroupID = DemoSamples.uuid(0xd604)

    /// The device groups Profile2Blueprint adds to Contoso's in demo mode: a
    /// second "Design Macs", so the scope screen asks which one is meant.
    /// "Finance Macs" is deliberately missing.
    static let addedPlatformGroups: [JamfPlatform.DeviceGroup] = [
        JamfPlatform.DeviceGroup(id: DemoSamples.uuid(0xd611), name: "Design Macs", description: "Static",
                                 deviceType: .computer, groupType: .static, memberCount: 3),
    ]

    /// Every device group of demo mode: Contoso's, then the app's own.
    static let platformGroups: [JamfPlatform.DeviceGroup] = DemoSamples.platformGroups + addedPlatformGroups

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

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
