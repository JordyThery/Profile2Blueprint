import Foundation
import Testing
@testable import Profile2Blueprint

private func profile(_ xml: String) throws -> ClassicProfile {
    try ClassicXMLParser.parseProfile(Data(xml.utf8))
}

private func check(_ xml: String, groups: [PlatformGroup] = DemoFixtures.platformGroups) throws -> EligibilityReport {
    EligibilityChecker.check(try profile(xml), platformGroups: groups)
}

private let engineers = DemoFixtures.platformGroups[0]

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
        #expect(!report.has(.unsupportedPayloadType), "a refused type is not also reported as unrecognised")
    }

    @Test("Certificate payloads are Blocked rather than flagged as informational")
    func certificatePayloadsBlocked() throws {
        let xml = DemoFixtures.corporateFonts.replacingOccurrences(of: "com.apple.font", with: "com.apple.security.pkcs12")
        let report = try check(xml)
        #expect(report.status == .blocked)
        #expect(report.has(.blockedPayloadType))
    }

    @Test("A payload type outside the known registry warns but does not block")
    func unrecognisedType() throws {
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
        #expect(!report.has(.noMappedGroup), "Engineers still maps")
        #expect(report.scopeMapping.map(\.exactMatches.count) == [1, 2])
    }

    @Test("All computers, buildings, limitations and exclusions need attention")
    func allComputersAndExclusions() throws {
        let report = try check(DemoFixtures.wifiAllComputers)
        #expect(report.status == .needsAttention)
        for kind: FindingKind in [.allComputers, .nonGroupTargets, .limitations, .exclusions, .noMappedGroup] {
            #expect(report.has(kind), "\(kind)")
        }
        let exclusions = try #require(report.findings.first { $0.kind == .exclusions })
        #expect(exclusions.title.contains("NOT carried over"))
        #expect(exclusions.detail.contains("KIOSK-01") && exclusions.detail.contains("Lab Machines"))
    }

    @Test("Record UUID different from PayloadUUID needs attention")
    func recordUUIDMismatch() throws {
        let report = try check(DemoFixtures.uploadedPPPC)
        #expect(report.status == .needsAttention)
        #expect(report.has(.recordUUIDMismatch))
        #expect(!report.identityRulesHold)
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
        scope.computerGroups = [
            ClassicReference(id: 1, name: "Engineers"),
            ClassicReference(id: 2, name: "all managed  clients"),
            ClassicReference(id: 3, name: "iPads"),
        ]
        let groups = DemoFixtures.platformGroups + [
            PlatformGroup(id: "m", name: "iPads", description: nil, deviceType: .mobile, groupType: .smart, memberCount: 9),
        ]
        let entries = ScopeMapper.propose(for: scope, platformGroups: groups)
        #expect(entries[0].autoMatch?.name == "Engineers")
        #expect(entries[1].autoMatch == nil)
        #expect(entries[1].suggestions.map(\.name) == ["All Managed Clients"])
        #expect(entries[2].isUnmatched && entries[2].suggestions.isEmpty)
        #expect(ScopeMapper.automaticSelection(entries) == [engineers.id])
    }
}

// MARK: - Builder

@Suite("Blueprint builder")
struct BlueprintBuilderTests {

    @Test("Fixture 1 builds the §3.3 body with identifiers copied verbatim")
    func fixture1Body() throws {
        let source = try profile(DemoFixtures.managedLoginItems)
        let request = try BlueprintBuilder.build(
            profile: source, name: "Classic – Managed Login Items (migrated)",
            description: "Migrated from Jamf Classic macOS config profile", deviceGroupIDs: [engineers.id]
        )
        let expected = """
        {
          "name": "Classic – Managed Login Items (migrated)",
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
                    "payloadDisplayName": "Classic – Managed Login Items",
                    "payloadContent": [
                      {
                        "payloadDisplayName": "Service Management - Managed Login Items",
                        "payloadIdentifier": "\(DemoFixtures.managedLoginItemsPayloadUUID)",
                        "payloadOrganization": "Example Org",
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
        #expect(request.body.serialized() == expected)
    }

    @Test("Fixture 2 keeps payload order; fixture 3 encodes data and dates")
    func orderAndTypes() throws {
        let baseline = try BlueprintBuilder.build(profile: profile(DemoFixtures.securityBaseline), name: "x", description: nil, deviceGroupIDs: ["g"])
        let content = baseline.configuration["payloadContent"]?.arrayValue?.compactMap { $0.objectValue?["payloadType"]?.stringValue }
        #expect(content == ["com.apple.notificationsettings", "com.apple.servicemanagement", "com.apple.ManagedClient.preferences"])

        let certs = try BlueprintBuilder.build(profile: profile(DemoFixtures.certificatesAndDates), name: "x", description: nil, deviceGroupIDs: ["g"])
        let payloads = try #require(certs.configuration["payloadContent"]?.arrayValue)
        #expect(payloads[0].objectValue?["PayloadContent"] == .string(DemoFixtures.certificateDER.base64EncodedString()))
        let text = certs.body.serialized(pretty: false)
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
        #expect(deduped.description == nil, "blank description is sent as null")
        #expect(BlueprintBuilder.defaultName(for: fixture1) == "Classic – Managed Login Items (migrated)")
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

    @Test("The default keeps the behaviour from before naming was configurable")
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
            == "Migrated from Jamf Pro classic macOS configuration profile ID 101 (“Classic – Managed Login Items”) by Profile2Blueprint.")
    }

    @Test("Description tokens are substituted")
    func descriptionTokens() {
        let rendered = BlueprintBuilder.description("{name} came from #{id}. {name} again.",
                                                    profileName: "Wi-Fi", profileID: 430)
        #expect(rendered == "Wi-Fi came from #430. Wi-Fi again.")
    }

    @Test("A template with no tokens is used as a constant description")
    func descriptionWithoutTokens() {
        #expect(BlueprintBuilder.description("Managed by DDM.", profileName: "x", profileID: 1) == "Managed by DDM.")
    }

    @Test("An empty template means no description, which is sent as null")
    func emptyDescription() throws {
        let fixture = try profile(DemoFixtures.managedLoginItems)
        #expect(BlueprintBuilder.defaultDescription(for: fixture, template: "").isEmpty)
        let request = try BlueprintBuilder.build(profile: fixture, name: "n", description: "", deviceGroupIDs: ["g"])
        #expect(request.description == nil)
    }

    @Test("An over-long description is trimmed to the API's limit")
    func descriptionTruncation() {
        let rendered = BlueprintBuilder.description(String(repeating: "x", count: 3_000), profileName: "n", profileID: 1)
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

private func detail(for request: BlueprintRequest, transform: (inout JSONObject) -> Void = { _ in }, groups: [String]? = nil) -> BlueprintDetail {
    var configuration = request.configuration
    transform(&configuration)
    return BlueprintDetail(
        id: "bp", name: request.name, description: nil,
        scope: BlueprintScope(deviceGroups: groups ?? request.deviceGroupIDs),
        created: nil, updated: nil,
        deploymentState: DeploymentState(state: "NOT_DEPLOYED", lastDeployment: nil),
        steps: [BlueprintStepDetail(name: "s", components: [BlueprintComponentDetail(identifier: BlueprintBuilder.componentIdentifier, configuration: .object(configuration))])]
    )
}

private func mutatePayload(_ index: Int, _ configuration: inout JSONObject, _ change: (inout JSONObject) -> Void) {
    var payloads = configuration["payloadContent"]?.arrayValue ?? []
    var payload = payloads[index].objectValue ?? JSONObject()
    change(&payload)
    payloads[index] = .object(payload)
    configuration["payloadContent"] = .array(payloads)
}

@Suite("Server string rewrites")
struct ServerRewriteTests {

    private func compare(_ plist: PlistValue, _ json: JSONValue) -> [ValueDifference] {
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
        let differences = compare(.dict(source), .object(JSONObject()))
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
    func identical() {
        let report = FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: detail(for: request))
        #expect(report.passed)
        #expect(report.caseChanges.isEmpty)
    }

    @Test("Expected server canonicalisation is tolerated (§3.6)")
    func canonicalisation() {
        let canonical = detail(for: request) { configuration in
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
    func failures() {
        let changedUUID = detail(for: request) { c in mutatePayload(0, &c) { $0["payloadUUID"] = .string("OTHER") } }
        #expect(FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: changedUUID)
            .mismatches.map(\.field) == ["Payload 1 payloadUUID"])

        let reordered = detail(for: request) { c in
            var payloads = c["payloadContent"]!.arrayValue!
            payloads.swapAt(0, 1)
            c["payloadContent"] = .array(payloads)
        }
        #expect(!FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: reordered).passed)

        let dropped = detail(for: request) { c in c["payloadContent"] = .array(Array(c["payloadContent"]!.arrayValue!.prefix(2))) }
        let droppedReport = FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: dropped)
        #expect(droppedReport.mismatches.contains { $0.field == "Payload count" })

        let changedValue = detail(for: request) { c in
            mutatePayload(2, &c) { payload in
                payload["PayloadContent"] = .object(JSONObject(["com.apple.screensaver": .object(JSONObject(["Forced": .array([.object(JSONObject([
                    "mcx_preference_settings": .object(JSONObject(["askForPassword": .bool(false), "askForPasswordDelay": .integer(0), "idleTime": .integer(600)])),
                ]))])]))]))
            }
        }
        let valueReport = FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: changedValue)
        #expect(valueReport.mismatches.map(\.field) == ["Payload 3 PayloadContent.com.apple.screensaver.Forced[0].mcx_preference_settings.askForPassword"])

        let otherScope = detail(for: request, groups: ["someone-else"])
        #expect(FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: otherScope)
            .mismatches.map(\.field) == ["Scope device groups"])

        let changedTop = detail(for: request) { $0["payloadIdentifier"] = .string("x") }
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
        let dropped = detail(for: request) { c in
            mutatePayload(0, &c) { $0["PayloadDescription"] = nil; $0["PayloadEnabled"] = nil }
        }
        let report = FidelityVerifier.verify(document: document, expectedGroupIDs: ["g"], detail: dropped)
        #expect(report.rows.first { $0.field == "Payload 1 payloadDescription" }?.status == .info)
        #expect(report.mismatches.map(\.field) == ["Payload 1 payloadEnabled"])
    }

    @Test("Missing component fails")
    func missingComponent() {
        var empty = detail(for: request)
        empty.steps = []
        #expect(!FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: empty).passed)
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
    private func makePipeline(server: DemoBlueprintServer = DemoBlueprintServer(pollsToSucceed: 2), timeout: Duration = .seconds(300)) -> MigrationPipeline {
        MigrationPipeline(
            classic: DemoClassicAPI(),
            blueprints: DemoBlueprintsAPI(server: server),
            polling: PollingPolicy(initialInterval: .milliseconds(1), maxInterval: .milliseconds(2), timeout: timeout),
            sleep: { _ in await Task.yield() }
        )
    }

    private func confirmation(_ id: String) -> DeployConfirmation {
        DeployConfirmation(blueprintID: id, blueprintName: "n", groupNames: ["Engineers"], deviceCount: 12, confirmedAt: Date())
    }

    @Test("Full happy path: fetch → validate → build → create → verify → deploy → deployed")
    func happyPath() async throws {
        let server = DemoBlueprintServer(pollsToSucceed: 2)
        let pipeline = makePipeline(server: server)
        _ = try await pipeline.fetch(profileID: 101)
        #expect(await pipeline.state == .fetched)
        #expect(try await pipeline.validate(platformGroups: DemoFixtures.platformGroups).status == .ready)
        _ = try await pipeline.build(name: "Login items (migrated)", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
        #expect(await pipeline.state == .built)

        let created = try await pipeline.create()
        #expect(await pipeline.state == .created(blueprintID: created.id))
        #expect(await server.deployCount == 0, "create must not deploy")

        let fidelity = try await pipeline.verify()
        #expect(fidelity.passed, "\(fidelity.mismatches)")

        let outcome = try await pipeline.deploy(confirmation: confirmation(created.id))
        guard case let .succeeded(report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report?.total == 12)
        #expect(await server.deployCount == 1)
        guard case .deployed = await pipeline.state else { Issue.record("not deployed"); return }
    }

    @Test("Stages can't be skipped")
    func ordering() async throws {
        let pipeline = makePipeline()
        await #expect(throws: PipelineError.self) { try await pipeline.validate(platformGroups: []) }
        _ = try await pipeline.fetch(profileID: 101)
        await #expect(throws: PipelineError.self) { _ = try await pipeline.create() }
        await #expect(throws: PipelineError.self) { _ = try await pipeline.verify() }
        await #expect(throws: PipelineError.self) { _ = try await pipeline.deploy(confirmation: confirmation("x")) }
    }

    @Test("Blocked profiles can't be built; warnings need acknowledgement")
    func gates() async throws {
        let pipeline = makePipeline()
        _ = try await pipeline.fetch(profileID: 104)
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: true)
        }

        _ = try await pipeline.fetch(profileID: 105)
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
        }
        _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: true)
    }

    @Test("Duplicate names are refused at create time")
    func duplicate() async throws {
        let server = DemoBlueprintServer()
        _ = await server.seed(name: "Taken")
        let pipeline = makePipeline(server: server)
        _ = try await pipeline.fetch(profileID: 101)
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        _ = try await pipeline.build(name: "taken", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
        #expect(try await pipeline.existingBlueprints().count == 1)
        await #expect(throws: PipelineError.self) { _ = try await pipeline.create() }
        #expect(await server.createCount == 0)
    }

    @Test("Deploy requires a confirmation for this exact blueprint")
    func confirmationMustMatch() async throws {
        let server = DemoBlueprintServer()
        let pipeline = makePipeline(server: server)
        _ = try await pipeline.fetch(profileID: 101)
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
        _ = try await pipeline.create()
        _ = try await pipeline.verify()
        await #expect(throws: PipelineError.self) { _ = try await pipeline.deploy(confirmation: confirmation("some-other-id")) }
        #expect(await server.deployCount == 0)
    }

    @Test("Deployment failure and timeout are reported")
    func failureAndTimeout() async throws {
        // The failing case gets a generous timeout so it can't time out under load.
        for (server, expectFailure, timeout) in [
            (DemoBlueprintServer(pollsToSucceed: 2, failDeployments: true), true, Duration.seconds(30)),
            (DemoBlueprintServer(pollsToSucceed: 1_000_000), false, Duration.milliseconds(50)),
        ] {
            let pipeline = makePipeline(server: server, timeout: timeout)
            _ = try await pipeline.fetch(profileID: 101)
            _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
            _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineers.id], acknowledgedWarnings: false)
            let created = try await pipeline.create()
            _ = try await pipeline.verify()
            let outcome = try await pipeline.deploy(confirmation: confirmation(created.id))
            switch outcome {
            case .failed: #expect(expectFailure)
            case .timedOut: #expect(!expectFailure)
            case .succeeded: Issue.record("unexpected success")
            }
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
        #expect(HTTPClient.isPermitted(HTTPRequest(method: method, path: path)) == allowed)
    }

    @Test("Classic API protocol exposes no write methods")
    func classicIsReadOnly() {
        // Compile-time property: ClassicAPI only declares listProfiles() and profile(id:).
        let api: any ClassicAPI = DemoClassicAPI()
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
        #expect(row?.contains("Login Items (#101)") == true, "newlines flattened")
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
        await store.append(record("token Bearer abc.def.ghi"))
        let reloaded = HistoryStore(fileURL: url)
        let messages = await reloaded.all.map(\.message)
        #expect(messages == ["token Bearer \(Redactor.placeholder)"])
    }
}
