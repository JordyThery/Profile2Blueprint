import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

private let mobileKey = ProfileKey(platform: .mobile, id: 201)

private func mobileProfile(_ xml: String = DemoFixtures.iphoneLockScreen) throws -> ClassicProfile {
    try ClassicXMLParser.parseProfile(Data(xml.utf8), platform: .mobile)
}

// MARK: - Mobile parsing and eligibility

@Suite("Mobile profiles")
struct MobileProfileTests {

    @Test("Mobile XML parses with the mobile element names")
    func parsing() throws {
        let profile = try mobileProfile()
        #expect(profile.platform == .mobile)
        #expect(profile.key == mobileKey)
        #expect(profile.level == .system)
        #expect(profile.scope.deviceGroups == [ClassicReference(id: 12, name: "Field iPhones")])
        #expect(!profile.scope.allDevices)
        let document = try profile.document.get()
        #expect(document.payloads.first?.type == "com.apple.shareddeviceconfiguration")
    }

    @Test("Jamf Pro's mobile levels map to System", arguments: ["System", "Device Level", "device"])
    func levels(raw: String) {
        #expect(ProfileLevel(raw) == .system)
    }

    @Test("The mobile list parses with its own root element")
    func list() throws {
        let list = try ClassicXMLParser.parseProfileList(
            Data(DemoFixtures.profileListXML(platform: .mobile).utf8), platform: .mobile)
        #expect(list.map(\.profileID) == [201, 202])
        #expect(list.allSatisfy { $0.platform == .mobile })
    }

    @Test("A ready mobile profile maps to the MOBILE group of the same name")
    func eligibility() throws {
        let report = EligibilityChecker.check(try mobileProfile(), platformGroups: DemoFixtures.platformGroups)
        #expect(report.status == .ready)
        let match = try #require(report.scopeMapping.first?.autoMatch)
        #expect(match.name == "Field iPhones")
        #expect(match.deviceType == .mobile)
    }

    @Test("Scope mapping never crosses platforms")
    func mappingIsPlatformScoped() {
        // "Engineers" exists as both a COMPUTER and a MOBILE demo group.
        var scope = ClassicScope()
        scope.deviceGroups = [ClassicReference(id: 1, name: "Engineers")]
        let forMac = ScopeMapper.propose(for: scope, platform: .macOS, platformGroups: DemoFixtures.platformGroups)
        let forMobile = ScopeMapper.propose(for: scope, platform: .mobile, platformGroups: DemoFixtures.platformGroups)
        #expect(forMac.first?.autoMatch?.deviceType == .computer)
        #expect(forMobile.first?.autoMatch?.deviceType == .mobile)
        #expect(forMac.first?.autoMatch?.id != forMobile.first?.autoMatch?.id)
    }

    @Test("A mobile web clip is blocked like any refused payload type")
    func webClipBlocked() throws {
        let report = EligibilityChecker.check(try mobileProfile(DemoFixtures.ipadWebClip), platformGroups: DemoFixtures.platformGroups)
        #expect(report.status == .blocked)
        #expect(report.has(.blockedPayloadType))
    }

    @Test("The same ID on both platforms is two different profiles")
    func keyCollision() throws {
        let mac = ProfileKey(platform: .macOS, id: 10)
        let mobile = ProfileKey(platform: .mobile, id: 10)
        #expect(mac != mobile)
        var store: [ProfileKey: String] = [:]
        store[mac] = "mac"; store[mobile] = "mobile"
        #expect(store.count == 2)
        #expect([mobile, mac].sorted() == [mac, mobile], "macOS sorts before mobile")
    }

    @Test("The demo workspace loads both platforms")
    @MainActor
    func demoWorkspace() {
        let workspace = Workspace.previewDemo()
        #expect(workspace.summaries.contains { $0.platform == .mobile })
        #expect(workspace.summaries.contains { $0.platform == .macOS })
        #expect(workspace.profiles[mobileKey] != nil)
        #expect(workspace.groups(for: .mobile).allSatisfy { $0.deviceType == .mobile })
    }

    @Test("Mobile create and verify pass end to end in demo mode")
    @MainActor
    func mobileMigration() async throws {
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: mobileKey))
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.blueprintDescription.contains("classic mobile device configuration profile ID 201"))
        session.dryRun = false
        await session.create()
        #expect(session.lastError == nil)
        #expect(session.blueprintID != nil)
        let fidelity = try #require(session.fidelity)
        #expect(fidelity.passed, "\(fidelity.mismatches)")
    }
}

// MARK: - Mobile classic cleanup

@Suite("Mobile classic cleanup")
struct MobileCleanupTests {

    private func environment() -> (MigrationEnvironment, DemoClassicServer) {
        let server = DemoClassicServer()
        return (MigrationEnvironment(
            displayName: "Test", isDemo: true, environmentID: nil,
            classic: DemoClassicAPI(server: server), platform: DemoBlueprintServer().client(log: nil),
            classicScopeWriter: DemoClassicScopeWriter(server: server)
        ), server)
    }

    @Test("The mobile unscoped body uses mobile element names and is scope-only")
    func unscopedBodyShape() {
        let body = ClassicScopeService.unscopedBody(platform: .mobile)
        let xml = String(decoding: body, as: UTF8.self)
        #expect(RequestPolicy.isScopeOnlyProfileXML(body))
        #expect(xml.contains("<all_mobile_devices>false</all_mobile_devices>"))
        #expect(xml.contains("<mobile_device_groups/>"))
        #expect(!xml.contains("all_computers"))
        #expect(!xml.contains("exclusions") && !xml.contains("limitations") && !xml.contains("payloads"))
    }

    @Test("Mobile unscope backs up, clears targets, and restore puts them back")
    func unscopeAndRestore() async throws {
        let (env, server) = environment()
        let store = ScopeBackupStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "p2b-mobile-backups-\(UUID().uuidString).json"))
        let before = try await env.classic.profile(key: mobileKey)

        let (backup, after) = try await ClassicScopeService.unscope(key: mobileKey, blueprintID: "bp", environment: env, backups: store)
        #expect(backup.platform == .mobile)
        #expect(!ClassicScopeService.hasTargets(after.scope))
        #expect(after.payloadsPlist == before.payloadsPlist, "payloads untouched")
        let writes = await server.scopeWrites
        #expect(writes.count == 1 && writes[0].key == mobileKey)

        let restored = try await ClassicScopeService.restore(backup, environment: env, backups: store)
        #expect(restored.scope == before.scope)
    }

    @Test("The allow-list accepts a scope-only mobile PUT, and nothing else new")
    func allowList() {
        let path = "proclassic/mobiledeviceconfigurationprofiles/id/9"
        let body = ClassicScopeService.unscopedBody(platform: .mobile)
        #expect(RequestPolicy.isPermitted(HTTPRequest(method: "PUT", path: path, body: body), classicWrites: .scopeOnly))
        #expect(!RequestPolicy.isPermitted(HTTPRequest(method: "PUT", path: path, body: body), classicWrites: .denied))
        #expect(!RequestPolicy.isPermitted(HTTPRequest(method: "PUT", path: path, body: Data("<configuration_profile><general/></configuration_profile>".utf8)), classicWrites: .scopeOnly))
        #expect(!RequestPolicy.isPermitted(HTTPRequest(method: "DELETE", path: path, body: body), classicWrites: .scopeOnly))
        #expect(!RequestPolicy.isPermitted(HTTPRequest(method: "PUT", path: "proclassic/mobiledevices/id/9", body: body), classicWrites: .scopeOnly))
    }
}

// MARK: - Platform plumbing

@Suite("Platform plumbing")
struct PlatformPlumbingTests {

    @Test("Stored records from before mobile support decode as macOS")
    func legacyDecodes() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let migration = Data(#"{"environmentKey":"env","profileID":7,"blueprintID":"b","blueprintName":"n","selectedGroupIDs":[],"unscopeAfterDeploy":false,"updatedAt":"2026-10-01T00:00:00Z"}"#.utf8)
        #expect(try decoder.decode(PersistedMigration.self, from: migration).key == ProfileKey(platform: .macOS, id: 7))

        let backup = Data(#"{"id":"\#(UUID().uuidString)","createdAt":"2026-10-01T00:00:00Z","environmentName":"Test","profileID":9,"profileName":"P","scopeXML":"<scope/>"}"#.utf8)
        #expect(try decoder.decode(ScopeBackup.self, from: backup).key == ProfileKey(platform: .macOS, id: 9))

        let record = Data(#"{"id":"\#(UUID().uuidString)","timestamp":"2026-10-01T00:00:00Z","tenantName":"T","action":"create","sourceProfileID":3,"sourceProfileName":"N","result":"success","message":"m"}"#.utf8)
        #expect(try decoder.decode(MigrationRecord.self, from: record).platform == .macOS)
    }

    @Test("The mobile Jamf Pro link uses the iOS profiles page")
    func mobileLink() throws {
        let links = try #require(JamfProLinks("ritualstest.jamfcloud.com"))
        #expect(links.classicProfile(platform: .mobile, id: 10).absoluteString
                == "https://ritualstest.jamfcloud.com/iOSConfigurationProfiles.html?id=10&o=r")
    }

    @Test("{platform} renders per platform, and the default template keeps the old macOS wording")
    func platformToken() {
        #expect(BlueprintBuilder.description("{platform}", profileName: "x", profileID: 1, platform: .mobile) == "mobile device")
        #expect(BlueprintBuilder.description(BlueprintBuilder.defaultDescriptionTemplate, profileName: "N", profileID: 5, platform: .macOS)
                == "Migrated from Jamf Pro classic macOS configuration profile ID 5 (“N”) by Profile2Blueprint.")
    }

    @Test("Tenants on the old default template upgrade; edited templates are untouched")
    func templateUpgrade() throws {
        func tenant(template: String) throws -> Tenant {
            let json = #"{"id":"\#(UUID().uuidString)","name":"T","region":"eu","environmentID":"e","clientID":"c","descriptionTemplate":"\#(template)"}"#
            return try JSONDecoder().decode(Tenant.self, from: Data(json.utf8))
        }
        #expect(try tenant(template: BlueprintBuilder.descriptionTemplateV1).descriptionTemplate
                == BlueprintBuilder.defaultDescriptionTemplate)
        #expect(try tenant(template: "Custom {id}").descriptionTemplate == "Custom {id}")
    }
}

// MARK: - New guards

@Suite("New eligibility guards")
struct GuardTests {

    @Test("A payload whose UUID differs from its identifier is Blocked")
    func payloadUUIDMismatch() throws {
        // uploadedPPPC's TCC payload has identifier com.example.pppc.terminal.tcc
        // but a UUID-shaped PayloadUUID; the API would rewrite the UUID.
        let profile = try ClassicXMLParser.parseProfile(Data(DemoFixtures.uploadedPPPC.utf8), platform: .macOS)
        let report = EligibilityChecker.check(profile, platformGroups: DemoFixtures.platformGroups)
        #expect(report.findings.first { $0.kind == .payloadUUIDMismatch }?.severity == .blocker)
        #expect(!report.identityRulesHold)
    }

    @Test("A payload with only metadata warns: the Jamf Pro UI refuses to deploy it")
    func emptyPayload() throws {
        // Strip the payload's only setting (Rules), leaving metadata alone.
        let empty = DemoFixtures.managedLoginItems.replacing(
            /&lt;key&gt;Rules&lt;\/key&gt;.*?&lt;\/array&gt;\s*&lt;\/dict&gt;/.dotMatchesNewlines(),
            with: "&lt;/dict&gt;")
        let profile = try ClassicXMLParser.parseProfile(Data(empty.utf8), platform: .macOS)
        let report = EligibilityChecker.check(profile, platformGroups: DemoFixtures.platformGroups)
        #expect(report.findings.first { $0.kind == .emptyPayload }?.severity == .warning)
    }

    @Test("Secret keys match by ending, plus SCEP's Challenge",
          arguments: [
              ("Password", true), ("AdminPassword", true), ("Challenge", true), ("AuthToken", true),
              ("APIKey", true), ("SharedSecret", true), ("UnlockPasscode", true), ("UserCredential", true),
              ("TokenExpiry", false), ("ChallengeResponseURL", false), ("Name", false),
          ])
    func secretKeys(key: String, secret: Bool) {
        #expect(EligibilityChecker.isSecretKey(key) == secret)
    }

    @Test("The demo server rewrites each payload's UUID to its identifier, like the live API")
    func demoUUIDRewrite() async throws {
        var configuration = LosslessJSON.Object()
        configuration["payloadUUID"] = .string("TOP-UUID")
        configuration["payloadIdentifier"] = .string("TOP-ID")
        configuration["payloadDisplayName"] = .string("x")
        var payload = LosslessJSON.Object()
        payload["payloadType"] = .string("com.apple.dock")
        payload["payloadIdentifier"] = .string("P-ID")
        payload["payloadUUID"] = .string("P-OTHER-UUID")
        configuration["payloadContent"] = .array([.object(payload)])
        let request = BlueprintRequest(name: "uuid rewrite", description: nil, deviceGroupIDs: [DemoFixtures.engineersPlatformGroupID],
                                       stepName: "s", componentIdentifier: BlueprintBuilder.componentIdentifier, configuration: configuration)
        // Through JTKit's client, as demo mode does.
        let blueprints = JamfPlatform.Blueprints(client: DemoBlueprintServer().client(log: nil))
        let id = try await blueprints.create(name: request.name, description: request.description,
                                             deviceGroups: request.deviceGroupIDs, steps: request.steps)
        let detail = try await blueprints.detail(id: id)
        let stored = detail.components.first?.json["configuration"]?.objectValue
        let storedPayload = stored?["payloadContent"]?.arrayValue?.first?.objectValue
        #expect(storedPayload?["payloadUUID"]?.stringValue == "P-ID", "payload UUID forced to the identifier")
        #expect(stored?["payloadUUID"]?.stringValue == "TOP-UUID", "top-level identity stored verbatim")
        #expect(storedPayload?["payloadVersion"]?.numberValue?.literal == "1", "server-managed metadata re-added")
    }

    @Test("Demo mode answers JTKit's requests: device groups, the duplicate search, deploy and report")
    func demoServerThroughJTKit() async throws {
        let server = DemoBlueprintServer(pollsToSucceed: 1)
        let client = server.client(log: nil)
        let groups = try await client.deviceGroups(pageSize: 3)
        #expect(groups == DemoFixtures.platformGroups, "every page, read back as JTKit's DeviceGroup")

        let blueprints = JamfPlatform.Blueprints(client: client)
        _ = server.seed(name: "Taken")
        #expect(try await blueprints.blueprints(named: "taken").map(\.name) == ["Taken"])
        #expect(try await blueprints.blueprints(named: "Tak").isEmpty, "the search is wide, the match exact")

        let id = try await blueprints.create(name: "n", description: nil, deviceGroups: [DemoFixtures.engineersPlatformGroupID],
                                             steps: [.object(LosslessJSON.Object(["name": .string("s"), "components": .array([])]))])
        let previous = try await blueprints.startDeployment(id: id)
        #expect(previous == nil)
        let outcome = try await blueprints.watchDeployment(id: id, previousStart: previous,
                                                           poller: JamfPlatform.Poller(sleep: { _ in await Task.yield() }))
        #expect(outcome.value?.didSucceed == true)
        #expect(outcome.value?.report == JamfPlatform.BlueprintReport(succeeded: 12, failed: 0, pending: 0))

        let error = await #expect(throws: JamfPlatformError.self) { _ = try await blueprints.detail(id: "missing") }
        #expect(error?.status == 404)
        #expect(error?.hasCode(.notFound) == true)
        #expect(ErrorReport(try #require(error)).traceID == "demo-trace")
    }

    @Test("A null blueprint name reads and is never a duplicate")
    func nullBlueprintName() async throws {
        // Shape seen live: a blueprint whose name and description are null.
        let list = #"{"results":[{"id":"dc0ca4c9-c567-440a-a5b3-750437c58c8a","name":null,"description":null,"created":"2026-04-08T13:48:29.408600Z","updated":"2026-04-08T14:05:56.892810Z","deploymentState":{"state":"NOT_DEPLOYED","lastDeployment":null}},{"id":"b","name":"Real","deploymentState":null}],"totalCount":2}"#
        let server = MockServer { _ in .json(200, list) }
        let client = try JamfPlatform.Client(
            baseURL: URL(string: "https://us.api.jamfcloud.com")!, scope: .environment(DemoBlueprintServer.environmentID),
            tokens: NoToken(), recorder: RequestRecorder(session: server.session, log: nil))
        let blueprints = JamfPlatform.Blueprints(client: client)
        #expect(try await blueprints.blueprints(named: "Real").map(\.id) == ["b"])
        let placeholder = try await blueprints.list().first { $0.id.hasPrefix("dc0c") }?.name
        #expect(try await blueprints.blueprints(named: try #require(placeholder)).isEmpty, "the nameless entry matches nothing")
    }
}

private struct NoToken: BearerTokenSource {
    func token() async throws -> String { "token" }
    func forgetToken() async {}
}
