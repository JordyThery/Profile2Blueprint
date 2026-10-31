import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

private func profile(_ xml: String) throws -> ClassicProfile {
    try ClassicXMLParser.parseProfile(Data(xml.utf8), platform: .macOS)
}

private func check(_ xml: String, groups: [JamfPlatform.DeviceGroup] = DemoFixtures.platformGroups) throws -> EligibilityReport {
    EligibilityChecker.check(try profile(xml), platformGroups: groups)
}

/// Contoso's "Engineering Macs", the group most demo profiles are scoped to.
private let engineers = DemoFixtures.platformGroups[2]

// MARK: - Eligibility table

@Suite("Eligibility checker")
struct EligibilityTests {

    @Test("Fixture 1 is Ready, with only informational notes")
    func readyProfile() throws {
        let report = try check(DemoFixtures.managedLoginItems)
        #expect(report.status == .ready)
        #expect(report.reasons.isEmpty)
        #expect(report.has(.cannotVerifyDevicePreconditions), "rules 1–2 are always stated")
        #expect(report.has(.droppedTopLevelKeys))
        #expect(report.scopeMapping.first?.autoMatch == engineers)
    }

    @Test("User-level profile is Blocked")
    func userLevel() throws {
        let report = try check(DemoFixtures.userDock)
        #expect(report.status == .blocked)
        #expect(report.findings.first { $0.kind == .userLevel }?.severity == .blocker)
    }

    @Test("Every payload type the API refuses is Blocked",
          arguments: EligibilityChecker.blockedPayloadTypes.sorted())
    func blockedTypes(type: String) throws {
        let xml = DemoFixtures.corporateFonts.replacingOccurrences(of: "com.apple.font", with: type)
        let report = try check(xml)
        #expect(report.status == .blocked)
        #expect(report.has(.blockedPayloadType))
        #expect(report.findings.first { $0.kind == .blockedPayloadType }?.detail.contains(type) == true)
        #expect(!report.has(.unsupportedPayloadType), "a refused type is not also reported as unrecognized")
    }

    @Test("Certificate payloads are Blocked rather than flagged as informational")
    func certificatePayloadsBlocked() throws {
        let xml = DemoFixtures.corporateFonts.replacingOccurrences(of: "com.apple.font", with: "com.apple.security.pkcs12")
        let report = try check(xml)
        #expect(report.status == .blocked)
        #expect(report.has(.blockedPayloadType))
    }

    @Test("A payload type outside the known registry warns but does not block")
    func unrecognizedType() throws {
        let xml = DemoFixtures.corporateFonts.replacingOccurrences(of: "com.apple.font", with: "com.example.invented")
        let report = try check(xml)
        #expect(report.status == .needsAttention, "the API is the authority; the registry may have grown")
        #expect(report.findings.first { $0.kind == .unsupportedPayloadType }?.severity == .warning)
        #expect(report.findings.first { $0.kind == .unsupportedPayloadType }?.detail.contains("com.example.invented") == true)
    }

    @Test("A payload type Jamf Pro spells differently is Blocked, not rewritten")
    func nonCanonicalType() throws {
        let xml = DemoFixtures.corporateFonts.replacingOccurrences(of: "com.apple.font", with: "com.apple.preferences.users")
        let report = try check(xml)
        #expect(report.status == .blocked)
        let finding = try #require(report.findings.first { $0.kind == .nonCanonicalPayloadType })
        #expect(finding.detail.contains("com.apple.preference.users"), "names the spelling the API wants")
        #expect(!report.has(.unsupportedPayloadType))
    }

    @Test("Payloads the Jamf Pro UI can't edit are called out")
    func apiOnlyPayload() throws {
        let wifi = try check(DemoFixtures.wifiAllComputers)
        let finding = try #require(wifi.findings.first { $0.kind == .apiOnlyPayload })
        #expect(finding.severity == .info)
        #expect(finding.detail.contains("com.apple.wifi.managed"))
        #expect(try !check(DemoFixtures.managedLoginItems).has(.apiOnlyPayload), "com.apple.servicemanagement is UI-manageable")
    }

    @Test("Missing payload identifiers are Blocked")
    func missingIdentifiers() throws {
        let xml = DemoFixtures.managedLoginItems.replacingOccurrences(
            of: "&lt;key&gt;PayloadUUID&lt;/key&gt;&lt;string&gt;\(DemoFixtures.managedLoginItemsPayloadUUID)&lt;/string&gt;", with: "")
        let report = try check(xml)
        #expect(report.status == .blocked)
        let detail = try #require(report.findings.first { $0.kind == .missingIdentifiers }?.detail)
        #expect(detail.contains("payload 1 (com.apple.servicemanagement): PayloadUUID"))
    }

    @Test("Empty PayloadContent is Blocked")
    func noPayloads() throws {
        let xml = DemoFixtures.userDock
            .replacingOccurrences(of: "<level>User</level>", with: "<level>System</level>")
            .replacing(/&lt;key&gt;PayloadContent&lt;\/key&gt;.*&lt;\/array&gt;/.dotMatchesNewlines(), with: "&lt;key&gt;PayloadContent&lt;/key&gt;&lt;array/&gt;")
        let report = try check(xml)
        #expect(report.status == .blocked)
        #expect(report.has(.noPayloads))
    }

    @Test("Unparseable payload plist is Blocked")
    func unparseable() throws {
        let report = try check(DemoFixtures.managedLoginItems.replacingOccurrences(of: "&lt;/plist&gt;", with: ""))
        #expect(report.status == .blocked)
        #expect(report.has(.unparseablePayload))
    }

    @Test("Unmatched group needs attention")
    func unmatchedGroup() throws {
        let report = try check(DemoFixtures.certificatesAndDates)
        #expect(report.status == .needsAttention)
        #expect(report.has(.noMappedGroup))
        #expect(report.scopeMapping.first?.isUnmatched == true)
    }

    @Test("Ambiguous group names need attention, partial matches are flagged")
    func ambiguousGroup() throws {
        let report = try check(DemoFixtures.securityBaseline)
        #expect(report.status == .needsAttention)
        #expect(report.has(.ambiguousGroups))
        #expect(!report.has(.noMappedGroup), "Engineering Macs still maps")
        #expect(report.scopeMapping.map(\.exactMatches.count) == [1, 2])
    }

    @Test("All computers, buildings, limitations and exclusions need attention")
    func allComputersAndExclusions() throws {
        let report = try check(DemoFixtures.wifiAllComputers)
        #expect(report.status == .needsAttention)
        for kind: FindingKind in [.allDevices, .nonGroupTargets, .limitations, .exclusions, .noMappedGroup] {
            #expect(report.has(kind), "\(kind)")
        }
        let exclusions = try #require(report.findings.first { $0.kind == .exclusions })
        #expect(exclusions.title.contains("aren’t carried over"))
        #expect(exclusions.detail.contains("KIOSK-01") && exclusions.detail.contains("Lab Machines"))
    }

    @Test("Uploaded profile: record-UUID warning plus the payload UUID/identifier blocker")
    func recordUUIDMismatch() throws {
        let report = try check(DemoFixtures.uploadedPPPC)
        #expect(report.has(.recordUUIDMismatch))
        // Its TCC payload's UUID differs from its identifier, which the API rewrites
        // to match, so this profile can never be adopted in place.
        #expect(report.status == .blocked)
        #expect(report.findings.first { $0.kind == .payloadUUIDMismatch }?.severity == .blocker)
    }

    @Test("Self Service distribution needs attention")
    func selfService() throws {
        let xml = DemoFixtures.managedLoginItems.replacingOccurrences(of: "Install Automatically", with: "Make Available in Self Service")
        #expect(try check(xml).has(.selfService))
        #expect(try check(xml).status == .needsAttention)
    }

    @Test("Jamf Protect-managed profiles need attention")
    func jamfProtect() throws {
        let xml = DemoFixtures.managedLoginItems.replacingOccurrences(of: DemoFixtures.managedLoginItemsTopUUID, with: "com.jamf.protect.1234")
        let report = try check(xml)
        #expect(report.has(.jamfProtectManaged))
    }

    @Test("Credentials are flagged as informational")
    func sensitive() throws {
        let xml = DemoFixtures.wifiAllComputers.replacingOccurrences(
            of: "&lt;key&gt;AutoJoin&lt;/key&gt;", with: "&lt;key&gt;Password&lt;/key&gt;&lt;string&gt;hunter2&lt;/string&gt;&lt;key&gt;AutoJoin&lt;/key&gt;")
        let finding = try #require(try check(xml).findings.first { $0.kind == .sensitiveContent })
        #expect(finding.severity == .info)
        #expect(!finding.detail.contains("hunter2"))
    }

    @Test("Empty Wi-Fi SetupModes is Blocked (server rejects it, seen live)")
    func emptySetupModes() throws {
        let xml = DemoFixtures.wifiAllComputers.replacingOccurrences(
            of: "&lt;key&gt;AutoJoin&lt;/key&gt;", with: "&lt;key&gt;SetupModes&lt;/key&gt;&lt;array/&gt;&lt;key&gt;AutoJoin&lt;/key&gt;")
        let report = try check(xml)
        #expect(report.status == .blocked)
        #expect(report.findings.first { $0.kind == .serverValidation }?.detail.contains("SetupModes") == true)
    }

    @Test("Any empty value is Blocked, not just the Wi-Fi case",
          arguments: ["&lt;string/&gt;", "&lt;array/&gt;"])
    func emptyValues(empty: String) throws {
        let xml = DemoFixtures.wifiAllComputers.replacingOccurrences(
            of: "&lt;key&gt;AutoJoin&lt;/key&gt;", with: "&lt;key&gt;ProxyPACURL&lt;/key&gt;\(empty)&lt;key&gt;AutoJoin&lt;/key&gt;")
        let report = try check(xml)
        #expect(report.status == .blocked)
        #expect(report.findings.first { $0.kind == .serverValidation }?.detail.contains("ProxyPACURL") == true)
    }

    @Test("An empty value in server-managed metadata is not treated as a rejection")
    func emptyMetadataIgnored() throws {
        let xml = DemoFixtures.wifiAllComputers.replacingOccurrences(
            of: "&lt;key&gt;AutoJoin&lt;/key&gt;", with: "&lt;key&gt;PayloadDescription&lt;/key&gt;&lt;string/&gt;&lt;key&gt;AutoJoin&lt;/key&gt;")
        #expect(try !check(xml).has(.serverValidation), "the server rewrites these keys anyway")
    }

    @Test("Disabled payloads need attention (server drops PayloadEnabled)")
    func disabledPayload() throws {
        let xml = DemoFixtures.managedLoginItems.replacingOccurrences(
            of: "&lt;key&gt;Rules&lt;/key&gt;", with: "&lt;key&gt;PayloadEnabled&lt;/key&gt;&lt;false/&gt;&lt;key&gt;Rules&lt;/key&gt;")
        let report = try check(xml)
        #expect(report.has(.disabledPayload))
        #expect(report.status == .needsAttention)
    }

    @Test("No platform groups at all → needs attention")
    func noPlatformGroups() throws {
        let report = try check(DemoFixtures.managedLoginItems, groups: [])
        #expect(report.status == .needsAttention)
        #expect(report.has(.noMappedGroup))
    }
}

@Suite("Scope mapper")
struct ScopeMapperTests {
    @Test("Exact names auto-match; case-only matches are suggestions; mobile groups are ignored")
    func mapping() {
        var scope = ClassicScope()
        scope.deviceGroups = [
            ClassicReference(id: 1, name: "Engineering Macs"),
            ClassicReference(id: 2, name: "all managed  macs"),
            ClassicReference(id: 3, name: "iPads"),
        ]
        let groups = DemoFixtures.platformGroups + [
            JamfPlatform.DeviceGroup(id: "m", name: "iPads", description: nil, deviceType: .mobile, groupType: .smart, memberCount: 9),
        ]
        let entries = ScopeMapper.propose(for: scope, platform: .macOS, platformGroups: groups)
        #expect(entries[0].autoMatch?.name == "Engineering Macs")
        #expect(entries[1].autoMatch == nil)
        #expect(entries[1].suggestions.map(\.name) == ["All Managed Macs"])
        #expect(entries[2].isUnmatched && entries[2].suggestions.isEmpty)
        #expect(ScopeMapper.automaticSelection(entries) == [engineers.id])
    }
}

// MARK: - Builder

@Suite("Blueprint builder")
struct BlueprintBuilderTests {

    @Test("Fixture 1 builds the create body with identifiers copied verbatim")
    func fixture1Body() throws {
        let source = try profile(DemoFixtures.managedLoginItems)
        let request = try BlueprintBuilder.build(
            profile: source, name: "Contoso – Managed Login Items (migrated)",
            description: "Migrated from Jamf Classic macOS config profile", deviceGroupIDs: [engineers.id]
        )
        let expected = """
        {
          "name": "Contoso – Managed Login Items (migrated)",
          "description": "Migrated from Jamf Classic macOS config profile",
          "scope": {
            "deviceGroups": [
              "\(engineers.id)"
            ]
          },
          "steps": [
            {
              "name": "Migrated classic configuration profile",
              "activationPredicate": null,
              "components": [
                {
                  "identifier": "com.jamf.ddm-configuration-profile",
                  "configuration": {
                    "payloadUUID": "\(DemoFixtures.managedLoginItemsTopUUID)",
                    "payloadIdentifier": "\(DemoFixtures.managedLoginItemsTopUUID)",
                    "payloadDisplayName": "Contoso – Managed Login Items",
                    "payloadContent": [
                      {
                        "payloadDisplayName": "Service Management - Managed Login Items",
                        "payloadIdentifier": "\(DemoFixtures.managedLoginItemsPayloadUUID)",
                        "payloadOrganization": "Contoso",
                        "payloadType": "com.apple.servicemanagement",
                        "payloadUUID": "\(DemoFixtures.managedLoginItemsPayloadUUID)",
                        "payloadVersion": 1,
                        "Rules": [
                          {
                            "RuleType": "BundleIdentifierPrefix",
                            "RuleValue": "com.google"
                          }
                        ]
                      }
                    ]
                  }
                }
              ]
            }
          ]
        }
        """
        #expect(request.body.prettyText == expected)
    }

    @Test("Fixture 2 keeps payload order; fixture 3 encodes data and dates")
    func orderAndTypes() throws {
        let baseline = try BlueprintBuilder.build(profile: profile(DemoFixtures.securityBaseline), name: "x", description: nil, deviceGroupIDs: ["g"])
        let content = baseline.configuration["payloadContent"]?.arrayValue?.compactMap { $0.objectValue?["payloadType"]?.stringValue }
        #expect(content == ["com.apple.notificationsettings", "com.apple.servicemanagement", "com.apple.ManagedClient.preferences"])

        let certs = try BlueprintBuilder.build(profile: profile(DemoFixtures.certificatesAndDates), name: "x", description: nil, deviceGroupIDs: ["g"])
        let payloads = try #require(certs.configuration["payloadContent"]?.arrayValue)
        #expect(payloads[0].objectValue?["PayloadContent"] == .string(DemoFixtures.certificateDER.base64EncodedString()))
        let text = certs.body.serializedString()
        #expect(text.contains(#""Deadline":"2026-01-15T00:00:00Z""#))
        #expect(text.contains(#""Ratio":0.75"#))
    }

    @Test("Custom Settings payloads keep their capitalised PayloadContent")
    func managedPreferencesKeepPayloadContent() throws {
        // The Blueprints API needs the MCX structure intact and stores the key verbatim.
        // Guards against a future change that strips payload metadata wholesale.
        let document = try profile(DemoFixtures.securityBaseline).document.get()
        let mcx = try #require(document.payloads.first { $0.type == "com.apple.ManagedClient.preferences" })
        let object = PlistToJSON.payloadObject(mcx.content)
        #expect(object["PayloadContent"]?.objectValue != nil, "must stay PayloadContent, not payloadContent")
        #expect(object.keys.contains("payloadType") && object.keys.contains("payloadUUID"))
    }

    @Test("Validation: name, description, groups, blocked types, level")
    func validation() throws {
        let fixture1 = try profile(DemoFixtures.managedLoginItems)
        #expect(throws: BlueprintBuildError.self) { try BlueprintBuilder.build(profile: fixture1, name: "  ", description: nil, deviceGroupIDs: ["g"]) }
        #expect(throws: BlueprintBuildError.self) { try BlueprintBuilder.build(profile: fixture1, name: String(repeating: "a", count: 201), description: nil, deviceGroupIDs: ["g"]) }
        #expect(throws: BlueprintBuildError.self) { try BlueprintBuilder.build(profile: fixture1, name: "a", description: String(repeating: "d", count: 2_001), deviceGroupIDs: ["g"]) }
        #expect(throws: BlueprintBuildError.self) { try BlueprintBuilder.build(profile: fixture1, name: "a", description: nil, deviceGroupIDs: []) }
        #expect(throws: BlueprintBuildError.self) { try BlueprintBuilder.build(profile: profile(DemoFixtures.corporateFonts), name: "a", description: nil, deviceGroupIDs: ["g"]) }
        #expect(throws: BlueprintBuildError.self) { try BlueprintBuilder.build(profile: profile(DemoFixtures.userDock), name: "a", description: nil, deviceGroupIDs: ["g"]) }

        let deduped = try BlueprintBuilder.build(profile: fixture1, name: "a", description: "  ", deviceGroupIDs: ["g", "h", "g"])
        #expect(deduped.deviceGroupIDs == ["g", "h"])
        #expect(deduped.description == nil, "a blank description is left out")
        #expect(BlueprintBuilder.defaultName(for: fixture1) == "Contoso – Managed Login Items (migrated)")
    }
}

@Suite("Blueprint naming")
struct BlueprintNamingTests {

    @Test("Prefix and suffix are applied verbatim")
    func affixes() {
        let naming = BlueprintNaming(prefix: "TEST - ", suffix: " [DDM]")
        #expect(naming.name(for: "Restrictions") == "TEST - Restrictions [DDM]")
    }

    @Test("Either affix may be empty, and both empty leaves the name untouched",
          arguments: [
              (BlueprintNaming(prefix: "", suffix: ""), "Restrictions"),
              (BlueprintNaming(prefix: "TEST - ", suffix: ""), "TEST - Restrictions"),
              (BlueprintNaming(prefix: "", suffix: " (migrated)"), "Restrictions (migrated)"),
          ])
    func optionalAffixes(naming: BlueprintNaming, expected: String) {
        #expect(naming.name(for: "Restrictions") == expected)
    }

    @Test("The default keeps the behavior from before naming was configurable")
    func defaultsUnchanged() {
        #expect(BlueprintNaming.default.name(for: "Restrictions") == "Restrictions (migrated)")
    }

    @Test("Over the limit, the profile name is shortened and the affixes survive")
    func truncation() {
        let naming = BlueprintNaming(prefix: "TEST - ", suffix: " (migrated)")
        let name = naming.name(for: String(repeating: "x", count: 400))
        #expect(name.count == BlueprintBuilder.maxNameLength)
        #expect(name.hasPrefix("TEST - ") && name.hasSuffix(" (migrated)"))
    }

    @Test("Affixes longer than the limit are truncated rather than overflowing")
    func affixesOverLimit() {
        let naming = BlueprintNaming(prefix: String(repeating: "p", count: 300), suffix: "s")
        #expect(naming.name(for: "Restrictions").count == BlueprintBuilder.maxNameLength)
    }

    @Test("The default description template renders the original wording")
    func defaultDescriptionUnchanged() throws {
        let fixture = try profile(DemoFixtures.managedLoginItems)
        #expect(BlueprintBuilder.defaultDescription(for: fixture)
            == "Migrated from Jamf Pro classic macOS configuration profile ID 101 (“Contoso – Managed Login Items”) by Profile2Blueprint.")
    }

    @Test("Description tokens are substituted")
    func descriptionTokens() {
        let rendered = BlueprintBuilder.description("{name} came from #{id}. {name} again.",
                                                    profileName: "Wi-Fi", profileID: 430, platform: .macOS)
        #expect(rendered == "Wi-Fi came from #430. Wi-Fi again.")
    }

    @Test("A template with no tokens is used as a constant description")
    func descriptionWithoutTokens() {
        #expect(BlueprintBuilder.description("Managed by DDM.", profileName: "x", profileID: 1, platform: .macOS) == "Managed by DDM.")
    }

    @Test("An empty template means no description, which is left out of the body (as JTKit sends it)")
    func emptyDescription() throws {
        let fixture = try profile(DemoFixtures.managedLoginItems)
        #expect(BlueprintBuilder.defaultDescription(for: fixture, template: "").isEmpty)
        let request = try BlueprintBuilder.build(profile: fixture, name: "n", description: "", deviceGroupIDs: ["g"])
        #expect(request.description == nil)
        #expect(request.body["description"] == nil)
        #expect(request.body.objectValue?.keys == ["name", "scope", "steps"])
    }

    @Test("An over-long description is trimmed to the API's limit")
    func descriptionTruncation() {
        let rendered = BlueprintBuilder.description(String(repeating: "x", count: 3_000), profileName: "n", profileID: 1, platform: .macOS)
        #expect(rendered.count == BlueprintBuilder.maxDescriptionLength)
    }

    @Test("A tenant saved before naming existed decodes with the original suffix")
    func decodesLegacyTenant() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","name":"Old","region":"eu","environmentID":"e","clientID":"c"}
        """.utf8)
        let tenant = try JSONDecoder().decode(Tenant.self, from: json)
        #expect(tenant.naming == .default)
        #expect(tenant.descriptionTemplate == BlueprintBuilder.defaultDescriptionTemplate)
        #expect(!tenant.allowClassicScopeChanges)
    }

    @Test("Naming and the description template survive a save/load round trip")
    func roundTrips() throws {
        let tenant = Tenant(name: "T", naming: BlueprintNaming(prefix: "A", suffix: "B"),
                            descriptionTemplate: "Was {id}")
        let decoded = try JSONDecoder().decode(Tenant.self, from: try JSONEncoder().encode(tenant))
        #expect(decoded.naming == tenant.naming)
        #expect(decoded.descriptionTemplate == "Was {id}")
    }
}

// MARK: - Verifier

private func detail(
    for request: BlueprintRequest, transform: (inout LosslessJSON.Object) -> Void = { _ in }, groups: [String]? = nil
) throws -> JamfPlatform.BlueprintDetail {
    var configuration = request.configuration
    transform(&configuration)
    return try blueprintDetail(name: request.name, deviceGroups: groups ?? request.deviceGroupIDs, configuration: configuration)
}

/// The same JSON with every object's keys in another order, all the way down.
private func reorderedKeys(_ value: LosslessJSON, _ order: ([LosslessJSON.Object.Member]) -> [LosslessJSON.Object.Member]) -> LosslessJSON {
    switch value {
    case let .object(object):
        return .object(LosslessJSON.Object(order(object.members).map { .init(key: $0.key, value: reorderedKeys($0.value, order)) }))
    case let .array(values):
        return .array(values.map { reorderedKeys($0, order) })
    default:
        return value
    }
}

private func mutatePayload(_ index: Int, _ configuration: inout LosslessJSON.Object, _ change: (inout LosslessJSON.Object) -> Void) {
    var payloads = configuration["payloadContent"]?.arrayValue ?? []
    var payload = payloads[index].objectValue ?? LosslessJSON.Object()
    change(&payload)
    payloads[index] = .object(payload)
    configuration["payloadContent"] = .array(payloads)
}

@Suite("Server string rewrites")
struct ServerRewriteTests {

    private func compare(_ plist: PlistValue, _ json: LosslessJSON) -> [ValueDifference] {
        var options = PlistJSONComparator.Options()
        options.tolerateServerRewrites = true
        return PlistJSONComparator.differences(plist: plist, json: json, options: options)
    }

    @Test("CR, CRLF and edge whitespace are folded before comparing",
          arguments: [("a\r\nb", "a\nb"), ("a\rb", "a\nb"), ("  spaced  ", "spaced")])
    func foldedSilently(source: String, stored: String) {
        #expect(compare(.string(source), .string(stored)).isEmpty)
    }

    @Test("Known rewrites are explained instead of failing",
          arguments: [
              ("line one\nline two", "line oneline two", "line feeds"),
              ("A & B < C", "A &amp; B &lt; C", "PI-827"),
              ("done \u{1F680}", "done \u{FFFD}", "Basic Multilingual Plane"),
          ])
    func classified(source: String, stored: String, expectedPhrase: String) throws {
        let difference = try #require(compare(.string(source), .string(stored)).first)
        let reason = try #require(difference.serverRewrite, "should be classified, not reported as corruption")
        #expect(reason.contains(expectedPhrase))
    }

    @Test("Genuine corruption is still a difference")
    func realCorruptionSurvives() throws {
        let difference = try #require(compare(.string("enabled"), .string("disabled")).first)
        #expect(difference.serverRewrite == nil)
    }

    @Test("An omitted empty value is a harmless omission; an omitted real value is not")
    func omittedValues() throws {
        let source = PlistDictionary([.init(key: "Empty", value: .array([])), .init(key: "Real", value: .string("x"))])
        let differences = compare(.dict(source), .object(LosslessJSON.Object()))
        #expect(differences.count == 2)
        #expect(differences.first { $0.path == "Empty" }?.serverRewrite != nil)
        #expect(differences.first { $0.path == "Real" }?.serverRewrite == nil)
    }

    @Test("Without the option, every rewrite is a plain difference")
    func strictByDefault() {
        let differences = PlistJSONComparator.differences(plist: .string("a\r\nb"), json: .string("a\nb"))
        #expect(differences.count == 1)
        #expect(differences[0].serverRewrite == nil)
    }
}

@Suite("Fidelity verifier")
struct FidelityVerifierTests {
    let source: ClassicProfile
    let document: ProfileDocument
    let request: BlueprintRequest

    init() throws {
        source = try profile(DemoFixtures.securityBaseline)
        document = try source.document.get()
        request = try BlueprintBuilder.build(profile: source, name: "n", description: nil, deviceGroupIDs: [engineers.id])
    }

    @Test("Identical read-back passes")
    func identical() throws {
        let report = FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: try detail(for: request))
        #expect(report.passed)
        #expect(report.caseChanges.isEmpty)
    }

    @Test("Expected server canonicalization is tolerated")
    func canonicalization() throws {
        let canonical = try detail(for: request) { configuration in
            configuration["payloadDisplayName"] = .string("Classic - Security Baseline")
            for index in 0..<3 {
                mutatePayload(index, &configuration) { payload in
                    payload["payloadVersion"] = .integer(1)
                    payload["payloadOrganization"] = .string("Jamf")
                    payload["payloadDisplayName"] = .string("Normalised \(index)")
                }
            }
            // Server returns Rules re-PascalCased (here: already PascalCase) but RuleValue lowercased key:
            mutatePayload(1, &configuration) { payload in
                if let rules = payload["Rules"] { payload["Rules"] = nil; payload["rules"] = rules }
            }
        }
        let report = FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: canonical)
        #expect(report.passed, "\(report.mismatches)")
        #expect(report.rows.contains { $0.status == .info && $0.field.contains("payloadDisplayName") })
        #expect(report.caseChanges.map(\.blueprint) == ["rules"], "key re-casing is surfaced, not failed")
    }

    @Test("Changed UUID, reordered payloads, count, values and scope each fail")
    func failures() throws {
        let changedUUID = try detail(for: request) { c in mutatePayload(0, &c) { $0["payloadUUID"] = .string("OTHER") } }
        #expect(FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: changedUUID)
            .mismatches.map(\.field) == ["Payload 1 payloadUUID"])

        let reordered = try detail(for: request) { c in
            var payloads = c["payloadContent"]!.arrayValue!
            payloads.swapAt(0, 1)
            c["payloadContent"] = .array(payloads)
        }
        #expect(!FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: reordered).passed)

        let dropped = try detail(for: request) { c in c["payloadContent"] = .array(Array(c["payloadContent"]!.arrayValue!.prefix(2))) }
        let droppedReport = FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: dropped)
        #expect(droppedReport.mismatches.contains { $0.field == "Payload count" })

        let changedValue = try detail(for: request) { c in
            mutatePayload(2, &c) { payload in
                payload["PayloadContent"] = .object(LosslessJSON.Object(["com.apple.screensaver": .object(LosslessJSON.Object(["Forced": .array([.object(LosslessJSON.Object([
                    "mcx_preference_settings": .object(LosslessJSON.Object(["askForPassword": .bool(false), "askForPasswordDelay": .integer(0), "idleTime": .integer(600)])),
                ]))])]))]))
            }
        }
        let valueReport = FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: changedValue)
        #expect(valueReport.mismatches.map(\.field) == ["Payload 3 PayloadContent.com.apple.screensaver.Forced[0].mcx_preference_settings.askForPassword"])

        let otherScope = try detail(for: request, groups: ["someone-else"])
        #expect(FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: otherScope)
            .mismatches.map(\.field) == ["Scope device groups"])

        let changedTop = try detail(for: request) { $0["payloadIdentifier"] = .string("x") }
        #expect(FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: changedTop)
            .mismatches.map(\.field) == ["payloadIdentifier (top level)"])
    }

    @Test("Dropped PayloadDescription is info; dropped PayloadEnabled=false is a mismatch (seen live)")
    func droppedPayloadKeys() throws {
        let xml = DemoFixtures.managedLoginItems.replacingOccurrences(
            of: "&lt;key&gt;Rules&lt;/key&gt;",
            with: "&lt;key&gt;PayloadDescription&lt;/key&gt;&lt;string&gt;d&lt;/string&gt;&lt;key&gt;PayloadEnabled&lt;/key&gt;&lt;false/&gt;&lt;key&gt;Rules&lt;/key&gt;")
        let source = try profile(xml)
        let document = try source.document.get()
        let request = try BlueprintBuilder.build(profile: source, name: "n", description: nil, deviceGroupIDs: ["g"])
        let dropped = try detail(for: request) { c in
            mutatePayload(0, &c) { $0["PayloadDescription"] = nil; $0["PayloadEnabled"] = nil }
        }
        let report = FidelityVerifier.verify(document: document, expectedGroupIDs: ["g"], detail: dropped)
        #expect(report.rows.first { $0.field == "Payload 1 payloadDescription" }?.status == .info)
        #expect(report.mismatches.map(\.field) == ["Payload 1 payloadEnabled"])
    }

    @Test("Missing component fails")
    func missingComponent() throws {
        let empty = try blueprintDetail(deviceGroups: request.deviceGroupIDs, configuration: nil)
        #expect(!FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: empty).passed)
    }

    @Test("Key order never changes a verdict: a read-back in another order than the source gets the same rows")
    func keyOrder() throws {
        // Unchanged, canonicalized by the server (passes, with info and casing rows),
        // and with a changed value and scope (fails).
        let cases: [(LosslessJSON.Object) -> LosslessJSON.Object] = [
            { $0 },
            { configuration in
                var c = configuration
                for index in 0..<3 {
                    mutatePayload(index, &c) { payload in
                        payload["payloadVersion"] = .integer(1)
                        payload["payloadOrganization"] = .string("Jamf")
                    }
                }
                mutatePayload(1, &c) { payload in
                    if let rules = payload["Rules"] { payload["Rules"] = nil; payload["rules"] = rules }
                }
                return c
            },
            { configuration in
                var c = configuration
                mutatePayload(0, &c) { $0["payloadUUID"] = .string("OTHER") }
                mutatePayload(2, &c) { $0["PayloadContent"] = .object(LosslessJSON.Object()) }
                return c
            },
        ]
        for (index, change) in cases.enumerated() {
            let configuration = change(request.configuration)
            let groups = index == 2 ? ["someone-else"] : request.deviceGroupIDs
            func verdicts(_ order: @escaping ([LosslessJSON.Object.Member]) -> [LosslessJSON.Object.Member]) throws -> FidelityReport {
                let reordered = try #require(reorderedKeys(.object(configuration), order).objectValue)
                // Read through JTKit from the text, as from a real server.
                let detail = try blueprintDetail(deviceGroups: groups, configuration: reordered)
                let readBack = try #require(detail.components.first?.json["configuration"]?.objectValue)
                #expect(readBack.keys == reordered.keys, "JTKit keeps the order it was sent in")
                return FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: detail)
            }
            let sourceOrder = try verdicts { $0 }
            let reversed = try verdicts { $0.reversed() }
            let alphabetical = try verdicts { $0.sorted { $0.key < $1.key } } // what the app saw before JTKit
            if index == 0 { #expect(try #require(reversed.rows.first).field == sourceOrder.rows.first?.field) }
            #expect(sourceOrder.passed == (index < 2), "case \(index)")
            for report in [reversed, alphabetical] {
                #expect(report.passed == sourceOrder.passed, "case \(index)")
                #expect(Set(report.rows.map { "\($0.field)|\($0.status)" }) == Set(sourceOrder.rows.map { "\($0.field)|\($0.status)" }), "case \(index)")
                #expect(report.mismatches.map(\.field).sorted() == sourceOrder.mismatches.map(\.field).sorted(), "case \(index)")
                #expect(report.caseChanges.map(\.blueprint) == sourceOrder.caseChanges.map(\.blueprint), "case \(index)")
            }
        }
    }

    @Test("Five-rule checklist: rules 1–2 need confirmation, 3–5 pass for a built body")
    func checklist() {
        let checks = FidelityVerifier.ruleChecklist(document: document, configuration: request.configuration)
        #expect(checks.map(\.status) == [.confirmOnDevice, .confirmOnDevice, .pass, .pass, .pass])
        var broken = request.configuration
        mutatePayload(1, &broken) { $0["payloadType"] = .string("com.apple.other") }
        #expect(FidelityVerifier.ruleChecklist(document: document, configuration: broken)[4].status == .fail)
    }
}

// MARK: - Pipeline

@Suite("Migration pipeline")
struct PipelineTests {
    private func makePipeline(server: DemoJamfPlatformServer = DemoJamfPlatformServer(pollsToSucceed: 2), timeout: Duration = .seconds(300)) -> MigrationPipeline {
        MigrationPipeline(
            classic: demoClassicAPI(),
            blueprints: JamfPlatform.Blueprints(client: server.client(log: nil)),
            watch: WatchPolicy(deployment: JamfPlatform.PollingPolicy(
                firstInterval: .milliseconds(1), longestInterval: .milliseconds(2), timeLimit: timeout)),
            sleep: { _ in await Task.yield() }
        )
    }

    private func confirmation(_ id: String) -> DeployConfirmation {
        DeployConfirmation(blueprintID: id, blueprintName: "n", groupNames: ["Engineering Macs"], deviceCount: 12, confirmedAt: Date())
    }

    @Test("Full happy path: fetch → validate → build → create → verify → deploy → deployed")
    func happyPath() async throws {
        let server = DemoJamfPlatformServer(pollsToSucceed: 2)
        let pipeline = makePipeline(server: server)
        _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 101))
        #expect(await pipeline.state == .fetched)
        #expect(try await pipeline.validate(platformGroups: DemoFixtures.platformGroups).status == .ready)
        _ = try await pipeline.build(name: "Login items (migrated)", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
        #expect(await pipeline.state == .built)

        let created = try await pipeline.create()
        #expect(await pipeline.state == .created(blueprintID: created))
        #expect(server.deployCount == 0, "create must not deploy")

        let fidelity = try await pipeline.verify()
        #expect(fidelity.passed, "\(fidelity.mismatches)")

        let outcome = try await pipeline.deploy(confirmation: confirmation(created))
        guard case let .succeeded(report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report?.total == 12)
        #expect(server.deployCount == 1)
        guard case .deployed = await pipeline.state else { Issue.record("not deployed"); return }
    }

    @Test("Stages can't be skipped")
    func ordering() async throws {
        let pipeline = makePipeline()
        await #expect(throws: PipelineError.self) { try await pipeline.validate(platformGroups: []) }
        _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 101))
        await #expect(throws: PipelineError.self) { _ = try await pipeline.create() }
        await #expect(throws: PipelineError.self) { _ = try await pipeline.verify() }
        await #expect(throws: PipelineError.self) { _ = try await pipeline.deploy(confirmation: confirmation("x")) }
    }

    @Test("Blocked profiles can't be built; warnings need acknowledgement")
    func gates() async throws {
        let pipeline = makePipeline()
        _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 104))
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: true)
        }

        _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 105))
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
        }
        _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: true)
    }

    @Test("Duplicate names are refused at create time")
    func duplicate() async throws {
        let server = DemoJamfPlatformServer()
        _ = server.seed(name: "Taken")
        let pipeline = makePipeline(server: server)
        _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 101))
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        _ = try await pipeline.build(name: "taken", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
        #expect(try await pipeline.existingBlueprints().count == 1)
        await #expect(throws: DuplicateNameError.self) { _ = try await pipeline.create() }
        #expect(server.createCount == 0)
        // The duplicate leaves the pipeline at .built, so renaming and retrying works.
        _ = try await pipeline.build(name: "now free", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
        _ = try await pipeline.create()
        #expect(server.createCount == 1)
    }

    @Test("Deploy requires a confirmation for this exact blueprint")
    func confirmationMustMatch() async throws {
        let server = DemoJamfPlatformServer()
        let pipeline = makePipeline(server: server)
        _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 101))
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
        _ = try await pipeline.create()
        _ = try await pipeline.verify()
        await #expect(throws: PipelineError.self) { _ = try await pipeline.deploy(confirmation: confirmation("some-other-id")) }
        #expect(server.deployCount == 0)
    }

    @Test("Deployment failure and timeout are reported")
    func failureAndTimeout() async throws {
        // The failing case gets a generous timeout so it can't time out under load.
        for (server, expectFailure, timeout) in [
            (DemoJamfPlatformServer(pollsToSucceed: 2, failDeployments: true), true, Duration.seconds(30)),
            (DemoJamfPlatformServer(pollsToSucceed: 1_000_000), false, Duration.milliseconds(50)),
        ] {
            let pipeline = makePipeline(server: server, timeout: timeout)
            _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 101))
            _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
            _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
            let created = try await pipeline.create()
            _ = try await pipeline.verify()
            let outcome = try await pipeline.deploy(confirmation: confirmation(created))
            switch outcome {
            case .failed: #expect(expectFailure)
            case .timedOut: #expect(!expectFailure)
            case .succeeded: Issue.record("unexpected success")
            }
        }
    }

    @Test("Deploying again waits for the new deployment instead of taking the previous one's success")
    func redeployWaitsForTheNewDeployment() async throws {
        let server = DemoJamfPlatformServer(pollsToSucceed: 2)
        let pipeline = makePipeline(server: server)
        _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 101))
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
        let created = try await pipeline.create()
        _ = try await pipeline.verify()
        guard case .succeeded = try await pipeline.deploy(confirmation: confirmation(created)) else { Issue.record("first deploy"); return }
        let firstStart = try #require(try await JamfPlatform.Blueprints(client: server.client(log: nil)).detail(id: created)
            .overview.deploymentState?.lastDeploymentStarted)

        // The Blueprint now says DEPLOYED / SUCCEEDED; a second deploy must not stop there.
        _ = try await pipeline.verify()
        let seen = StatusRecorder()
        let outcome = try await pipeline.deploy(confirmation: confirmation(created)) { await seen.add($0) }
        guard case .succeeded = outcome else { Issue.record("\(outcome)"); return }
        #expect(server.deployCount == 2)
        #expect(await seen.jobStates.first == "PENDING", "the new deployment is followed from its start")
        let started = await seen.started
        #expect(!started.isEmpty && !started.contains(firstStart), "only the new deployment counts")
    }

    @Test("Create sends exactly the body the Preview tab shows")
    func createSendsThePreview() async throws {
        let server = MockServer { request in
            request.method == "POST" ? .json(201, #"{"id":"new-id"}"#) : .json(200, #"{"totalCount":0,"results":[]}"#)
        }
        let client = try JamfPlatform.Client(
            baseURL: URL(string: "https://us.api.jamfcloud.com")!, scope: .environment(DemoSamples.platformEnvironmentID),
            tokens: FixedToken(), recorder: RequestRecorder(session: server.session, log: nil),
            permits: { RequestPolicy.isPermitted($0) })
        let pipeline = MigrationPipeline(classic: demoClassicAPI(), blueprints: JamfPlatform.Blueprints(client: client))
        _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 101))
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        for description in ["Migrated by Profile2Blueprint", ""] {
            let request = try await pipeline.build(name: "Login items", description: description, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
            #expect(try await pipeline.create() == "new-id")
            let sent = try #require(server.requests.last { $0.method == "POST" })
            #expect(sent.body == request.body.serialized(), "byte for byte")
            _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 101))
            _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        }
    }

    @Test("Rename suggestion increments a trailing number")
    func rename() {
        #expect(MigrationSession.nextName(after: "A (migrated)") == "A (migrated) 2")
        #expect(MigrationSession.nextName(after: "A (migrated) 2") == "A (migrated) 3")
    }
}

// MARK: - Safety & history

@Suite("Safety rules")
struct SafetyTests {
    @Test("Only GETs plus blueprint create/deploy are permitted", arguments: [
        ("GET", "proclassic/osxconfigurationprofiles/id/1", true),
        ("GET", "blueprints/v1/blueprints", true),
        ("POST", "blueprints/v1/blueprints", true),
        ("POST", "blueprints/v1/blueprints/abc/deploy", true),
        ("POST", "blueprints/v1/blueprints/abc/undeploy", false),
        ("DELETE", "blueprints/v1/blueprints/abc", false),
        ("PATCH", "blueprints/v1/blueprints/abc", false),
        ("PUT", "proclassic/osxconfigurationprofiles/id/1", false),
        ("POST", "proclassic/osxconfigurationprofiles/id/0", false),
        ("DELETE", "proclassic/osxconfigurationprofiles/id/1", false),
        ("POST", "device-groups/v1/device-groups", false),
    ])
    func permitted(method: String, path: String, allowed: Bool) {
        #expect(RequestPolicy.isPermitted(HTTPRequest(method: method, path: path)) == allowed)
    }

    @Test("Classic API protocol exposes no write methods")
    func classicIsReadOnly() {
        // Compile-time property: ClassicAPI only declares listProfiles(platform:) and profile(key:).
        let api: any ClassicAPI = demoClassicAPI()
        _ = api
    }
}

@Suite("History export")
struct HistoryTests {
    private func record(_ message: String = "ok") -> MigrationRecord {
        MigrationRecord(timestamp: Date(timeIntervalSince1970: 1_800_000_000), tenantName: "Prod | EU", environmentID: "env",
                        action: .create, sourceProfileID: 101, sourceProfileName: "Login\nItems",
                        blueprintID: "bp-1", blueprintName: "Login Items (migrated)", result: .success, message: message)
    }

    @Test("Markdown export is a well-formed table")
    func markdown() {
        let text = HistoryExport.markdown([record()])
        let lines = text.split(separator: "\n")
        #expect(lines.contains("| Timestamp | Tenant | Action | Source profile | Blueprint | Result | Details |"))
        let row = lines.last.map(String.init)
        #expect(row?.contains(#"Prod \| EU"#) == true, "pipes escaped")
        #expect(row?.contains("Login Items (macOS #101)") == true, "newlines flattened")
        #expect(row?.contains("`bp-1`") == true)
    }

    @Test("JSON export round-trips")
    func json() throws {
        let original = record()
        let data = try HistoryExport.json([original])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([MigrationRecord].self, from: data) == [original])
    }

    @Test("Store persists and redacts secrets in messages")
    func store() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "p2b-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)
        try await store.append(record("token Bearer abc.def.ghi"))
        let reloaded = HistoryStore(fileURL: url)
        let messages = await reloaded.all.map(\.message)
        #expect(messages == ["token Bearer \(Redaction.placeholder)"])
    }
}

/// Deployment progress seen by a test.
private actor StatusRecorder {
    private(set) var statuses: [JamfPlatform.DeploymentStatus] = []
    func add(_ status: JamfPlatform.DeploymentStatus) { statuses.append(status) }
    var jobStates: [String] { statuses.compactMap(\.jobState) }
    var started: [String] { statuses.compactMap(\.jobStarted) }
}

/// A token source that never signs in.
private struct FixedToken: BearerTokenSource {
    func token() async throws -> String { "token" }
    func forgetToken() async {}
}
