import Foundation
import JTKit
import Testing
@testable import Profile2Blueprint

private func parse(_ xml: String) throws -> ClassicProfile {
    try ClassicXMLParser.parseProfile(Data(xml.utf8), platform: .macOS)
}

private func document(_ xml: String) throws -> ProfileDocument {
    try parse(xml).document.get()
}

@Suite("Classic XML + plist parsing")
struct ClassicParsingTests {

    @Test("Fixture 1: general, scope and identifiers")
    func fixture1() throws {
        let profile = try parse(DemoFixtures.managedLoginItems)
        #expect(profile.id == 101)
        #expect(profile.name == "Contoso – Managed Login Items")
        #expect(profile.level == .system)
        #expect(profile.distributionMethod == "Install Automatically")
        #expect(profile.redeployOnUpdate == "Newly Assigned")
        #expect(profile.site == nil, "site id -1 means None")
        #expect(profile.scope.deviceGroups == [ClassicReference(id: 3, name: "Engineering Macs")])
        #expect(!profile.scope.allDevices && !profile.scope.hasExclusions)

        let doc = try profile.document.get()
        #expect(doc.payloadUUID == DemoFixtures.managedLoginItemsTopUUID)
        #expect(doc.payloadIdentifier == DemoFixtures.managedLoginItemsTopUUID)
        #expect(doc.payloadDisplayName == "Contoso – Managed Login Items")
        #expect(doc.payloads.count == 1)
        let payload = try #require(doc.payloads.first)
        #expect(payload.type == "com.apple.servicemanagement")
        #expect(payload.uuid == DemoFixtures.managedLoginItemsPayloadUUID)
        #expect(payload.identifier == DemoFixtures.managedLoginItemsPayloadUUID)

        let rule = payload.content["Rules"]?.arrayValue?.first?.dictValue
        #expect(rule?.string("RuleType") == "BundleIdentifierPrefix")
        #expect(rule?.string("RuleValue") == "com.google")
    }

    @Test("Fixture 2: payload order and count are preserved")
    func fixture2() throws {
        let doc = try document(DemoFixtures.securityBaseline)
        #expect(doc.payloads.map(\.type) == [
            "com.apple.notificationsettings", "com.apple.servicemanagement", "com.apple.ManagedClient.preferences",
        ])
        #expect(doc.payloads.map(\.uuid) == (1...3).map { "00000000-0000-4000-8000-00000000B10\($0)" })
        // Dictionary key order is document order, not alphabetical.
        let notification = try #require(doc.payloads[0].content["NotificationSettings"]?.arrayValue?.first?.dictValue)
        #expect(notification.keys == ["BundleIdentifier", "CriticalAlertEnabled", "NotificationsEnabled", "AlertType"])
        // Booleans stay booleans; integers stay integers.
        #expect(notification["CriticalAlertEnabled"] == .bool(true))
        #expect(notification["AlertType"] == .integer(1))
    }

    @Test("Fixture 3: <data>, <date>, <real> and whitespace")
    func fixture3() throws {
        let doc = try document(DemoFixtures.certificatesAndDates)
        #expect(doc.payloads[0].content["PayloadContent"] == .data(DemoFixtures.certificateDER))

        let settings = try #require(
            doc.payloads[1].content["PayloadContent"]?.dictValue?["com.contoso.example.updater"]?.dictValue?["Forced"]?
                .arrayValue?.first?.dictValue?["mcx_preference_settings"]?.dictValue
        )
        #expect(settings["Deadline"] == .date(try Date(DemoFixtures.configuredDateISO, strategy: .iso8601)))
        #expect(settings["Ratio"] == .real(0.75))
        #expect(settings["Banner"] == .string("  Leading & trailing spaces kept  "))
    }

    @Test("Scope: all computers, buildings, limitations and exclusions")
    func fixture5Scope() throws {
        let scope = try parse(DemoFixtures.wifiAllComputers).scope
        #expect(scope.allDevices)
        #expect(scope.buildings.map(\.name) == ["HQ"])
        #expect(scope.limitations.map(\.kind) == ["network_segments"])
        #expect(scope.exclusions.map(\.kind) == ["computers", "computer_groups"])
        #expect(scope.exclusions[0].items == [ClassicReference(id: 77, name: "KIOSK-01")])
    }

    @Test("User-level profiles are recognized")
    func userLevel() throws {
        #expect(try parse(DemoFixtures.userDock).level == .user)
    }

    @Test("Profile list parses every summary")
    func list() throws {
        let list = try ClassicProfileList.parse(Data(DemoFixtures.profileListJSON(platform: .macOS).utf8), platform: .macOS)
        #expect(list.map(\.profileID) == [101, 102, 103, 104, 105, 106, 107])
        #expect(list.first?.name == "Contoso – Managed Login Items")
    }

    @Test("Malformed payloads produce a parse error, not a crash")
    func malformed() throws {
        let xml = DemoFixtures.managedLoginItems.replacingOccurrences(of: "&lt;/plist&gt;", with: "")
        let profile = try parse(xml)
        #expect(throws: PlistParseError.self) { try profile.document.get() }
    }

    @Test("Non-profile XML is rejected with a decoding error")
    func wrongRoot() {
        #expect(throws: APIError.self) { try ClassicXMLParser.parseProfile(Data("<computer/>".utf8), platform: .macOS) }
    }
}

@Suite("Plist → JSON")
struct PlistToJSONTests {

    @Test("Type mapping follows the documented table")
    func typeMapping() throws {
        let date = try Date("2026-01-15T00:00:00Z", strategy: .iso8601)
        let source = PlistDictionary([
            .init(key: "s", value: .string("x")),
            .init(key: "i", value: .integer(-42)),
            .init(key: "r", value: .real(3.14)),
            .init(key: "b", value: .bool(false)),
            .init(key: "d", value: .data(Data("Hello".utf8))),
            .init(key: "t", value: .date(date)),
            .init(key: "a", value: .array([.integer(1), .string("two")])),
        ])
        let json = PlistToJSON.convert(source)
        #expect(json.keys == ["s", "i", "r", "b", "d", "t", "a"])
        #expect(json["s"] == .string("x"))
        #expect(json["i"] == .integer(-42))
        #expect(json["r"] == .real(3.14))
        #expect(json["r"]?.numberValue?.literal == "3.14")
        #expect(json["b"] == .bool(false))
        #expect(json["d"] == .string("SGVsbG8="))
        #expect(json["t"] == .string("2026-01-15T00:00:00Z"))
        #expect(json["a"] == .array([.integer(1), .string("two")]))
    }

    @Test("Wrapper keys become camelCase only at payload top level")
    func wrapperKeys() throws {
        let payload = try #require(try document(DemoFixtures.managedLoginItems).payloads.first)
        let object = PlistToJSON.payloadObject(payload.content)
        #expect(object.keys == [
            "payloadDisplayName", "payloadIdentifier", "payloadOrganization", "payloadType", "payloadUUID", "payloadVersion", "Rules",
        ])
        let rule = object["Rules"]?.arrayValue?.first?.objectValue
        #expect(rule?.keys == ["RuleType", "RuleValue"], "type-specific keys keep their casing")

        // Nested PayloadContent (ManagedClient.preferences) is not renamed.
        let mcx = try document(DemoFixtures.securityBaseline).payloads[2]
        #expect(PlistToJSON.payloadObject(mcx.content).keys.contains("PayloadContent"))
    }

    @Test("Serialised JSON is valid, ordered and escapes control characters")
    func serialization() throws {
        let value = LosslessJSON.object(LosslessJSON.Object([
            "z": .string("quote \" backslash \\ newline \n tab \t bell \u{07}"),
            "a": .array([.integer(1), .real(2.5), .real(3), .bool(true), .null]),
        ]))
        let text = value.serializedString()
        #expect(text.hasPrefix(#"{"z":"#), "insertion order kept")
        #expect(text.contains(#"\u0007"#))
        let roundTrip = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect((roundTrip?["z"] as? String)?.contains("\n") == true)
        #expect(text.hasSuffix(#""a":[1,2.5,3.0,true,null]}"#), "numbers written as the app always wrote them")
        #expect(value.prettyText.contains("\n  \"a\": ["))
    }

    // MARK: Property test

    @Test("Round-trip property: every key, value and array position survives", arguments: 0..<200)
    func roundTripProperty(seed: Int) throws {
        var rng = SeededGenerator(seed: UInt64(seed) &+ 0x9E37_79B9)
        let plist = PlistValue.random(depth: 0, using: &rng)
        let json = PlistToJSON.convert(plist)

        var options = PlistJSONComparator.Options()
        options.requireKeyOrder = true
        let differences = PlistJSONComparator.differences(plist: plist, json: json, options: options)
        #expect(differences.isEmpty, "seed \(seed): \(differences)")

        // And it survives JTKit's JSON reader, key order included: nothing is sorted any more.
        let reparsed = try LosslessJSON(data: json.serialized())
        #expect(reparsed == json, "seed \(seed)")
        #expect(PlistJSONComparator.differences(plist: plist, json: reparsed, options: options).isEmpty, "seed \(seed)")
    }

    @Test("Comparator catches changed values, reordered arrays and missing keys")
    func comparatorDetectsDifferences() {
        let plist = PlistValue.dict(PlistDictionary([
            .init(key: "Rules", value: .array([.string("a"), .string("b")])),
            .init(key: "Enabled", value: .bool(true)),
        ]))
        let reordered = LosslessJSON.object(LosslessJSON.Object(["Rules": .array([.string("b"), .string("a")]), "Enabled": .bool(true)]))
        let missing = LosslessJSON.object(LosslessJSON.Object(["Rules": .array([.string("a"), .string("b")])]))
        let boolAsInt = LosslessJSON.object(LosslessJSON.Object(["Rules": .array([.string("a"), .string("b")]), "Enabled": .integer(1)]))

        #expect(PlistJSONComparator.differences(plist: plist, json: reordered).count == 2)
        #expect(PlistJSONComparator.differences(plist: plist, json: missing).map(\.path) == ["Enabled"])
        #expect(PlistJSONComparator.differences(plist: plist, json: boolAsInt).map(\.path) == ["Enabled"])
    }
}

// MARK: - Random plist generation

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xDEAD_BEEF : seed }
    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}

extension PlistValue {
    static func random(depth: Int, using rng: inout SeededGenerator) -> PlistValue {
        let leafOnly = depth >= 4
        switch Int.random(in: 0..<(leafOnly ? 6 : 9), using: &rng) {
        case 0: return .string(randomString(using: &rng))
        case 1: return .integer(Int64.random(in: -1_000_000...1_000_000, using: &rng))
        case 2: return .real(Double(Int.random(in: -10_000...10_000, using: &rng)) / 64)
        case 3: return .bool(Bool.random(using: &rng))
        case 4: return .data(Data((0..<Int.random(in: 0...24, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        case 5: return .date(Date(timeIntervalSince1970: TimeInterval(Int.random(in: 0...2_000_000_000, using: &rng))))
        case 6, 7:
            var keys = Set<String>()
            let entries: [PlistDictionary.Entry] = (0..<Int.random(in: 0...6, using: &rng)).compactMap { _ in
                let key = randomString(using: &rng)
                guard keys.insert(key).inserted else { return nil }
                return .init(key: key, value: random(depth: depth + 1, using: &rng))
            }
            return .dict(PlistDictionary(entries))
        default:
            return .array((0..<Int.random(in: 0...6, using: &rng)).map { _ in random(depth: depth + 1, using: &rng) })
        }
    }

    private static func randomString(using rng: inout SeededGenerator) -> String {
        let alphabet = Array("abcXYZ019 _-.\"\\/é漢🙂\n\t")
        return String((0..<Int.random(in: 0...10, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
    }
}
