import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

/// Demo mode on JTKit's demo server: Classic reads and scope writes go
/// through the app's real code, nothing leaves the Mac, real tenants and
/// Test Connection are left alone.
@Suite("Demo mode through JTKit", .serialized)
@MainActor
struct DemoModeThroughJTKitTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "p2b-demo-\(UUID().uuidString)")

    /// A placeholder tenant, never a real one.
    private let tenant = Tenant(name: "Sandbox", region: .eu, environmentID: "0f0e0d0c-0b0a-4000-8000-000000000001",
                                clientID: "client", jamfProURL: "example.jamfcloud.com")

    private func makeModel(session: URLSession = .shared, demoMode: Bool) throws -> AppModel {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return AppModel(
            store: TenantStore(fileURL: folder.appending(path: "tenants.json")),
            secrets: InMemorySecretStore(),
            session: session,
            history: HistoryStore(fileURL: folder.appending(path: "history.json")),
            demoFiles: DemoFiles(folder: folder.appending(path: "demo")),
            demoMode: demoMode
        )
    }

    @Test("The demo workspace is Contoso (Demo), read through the real Classic code, every request answered inside the app")
    func demoWorkspace() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try makeModel(demoMode: true)
        let environment = try model.activeWorkspace().environment
        #expect(environment.isDemo)
        #expect(environment.displayName == "Contoso (Demo)")
        #expect(environment.classic is LiveClassicAPI, "the app's real Classic reader")
        #expect(environment.classicScopeWriter is LiveClassicScopeWriter, "the app's real scope writer")

        let list = try await environment.classic.listProfiles(platform: .macOS)
        #expect(list.map(\.profileID).sorted() == [101, 102, 103, 104, 105, 106, 107])
        #expect(list.map(\.name) == list.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                "sorted by name, as from a tenant")
        let profile = try await environment.classic.profile(key: ProfileKey(platform: .mobile, id: 201))
        #expect(profile.name == "Contoso – iPhone Lock Screen Message")
        #expect(try await environment.platform.deviceGroups() == DemoFixtures.platformGroups)

        let requests = model.activity.entries.filter { $0.status != nil }
        #expect(requests.count >= 4, "sign-in, two Classic reads, device groups")
        #expect(requests.allSatisfy { $0.connection == "Contoso (Demo)" && ($0.status ?? 0) < 400 })
        #expect(requests.contains { $0.detail.contains("proclassic/osxconfigurationprofiles") }, "Classic requests show in the log")
    }

    @Test("Demo mode's scope write passes the allow-list; a PUT that isn't scope-only is refused before it's sent")
    func scopeWritesThroughTheAllowList() async throws {
        let classic = DemoClassicServer()
        let environment = MigrationEnvironment.demo(classicServer: classic)
        let key = ProfileKey(platform: .macOS, id: 101)
        let writer = try #require(environment.classicScopeWriter)

        try await writer.replaceScope(key: key, body: ClassicScopeService.unscopedBody(platform: .macOS))
        #expect(classic.scopeWrites.count == 1)
        #expect(!ClassicScopeService.hasTargets(try await environment.classic.profile(key: key).scope))

        let whole = Data(try #require(DemoFixtures.profilesByKey[key]).utf8)
        let error = await #expect(throws: JamfPlatform.APIError.self) { try await writer.replaceScope(key: key, body: whole) }
        guard case .refused = error?.kind else { Issue.record("not refused: \(String(describing: error))"); return }
        #expect(classic.scopeWrites.count == 1, "nothing more reached the demo server")
    }

    @Test("Without the tenant's switch the demo has no writer; real tenants' allow-list is unchanged")
    func noWriterWhenOff() {
        #expect(MigrationEnvironment.demo(classicScopeChanges: false).classicScopeWriter == nil)
        let put = HTTPRequest(method: "PUT", path: JamfClassic.path("osxconfigurationprofiles", id: "101"),
                              body: ClassicScopeService.unscopedBody(platform: .macOS), contentType: "application/xml")
        #expect(!RequestPolicy.isPermitted(put), "denied by default")
    }

    @Test("Test Connection uses the real tenant and the real network while demo mode is on")
    func testConnectionStaysReal() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = MockServer { _ in .json(401, #"{"error":"invalid_client"}"#) }
        let model = try makeModel(session: server.session, demoMode: true)
        await #expect(throws: (any Error).self) {
            _ = try await model.testConnection(tenant, secretOverride: "typed-secret")
        }
        #expect(!server.requests.isEmpty, "sent to the tenant")
        #expect(server.requests.allSatisfy { !($0.url.host() ?? "").hasSuffix(DemoNetwork.reservedDomain) })
        #expect(model.isDemoMode, "demo mode stays on")
    }

    @Test("Turning demo mode on and off rebuilds the workspace and never touches the saved tenants")
    func switching() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try makeModel(demoMode: false)
        try model.connections.save(tenant)
        let saved = try String(contentsOf: folder.appending(path: "tenants.json"), encoding: .utf8)
        let current = try #require(model.currentTenantID)
        #expect(try !model.activeWorkspace().environment.isDemo)

        model.isDemoMode = true
        #expect(try model.activeWorkspace().environment.isDemo, "the new mode at once")
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.activity.entries.contains { $0.detail == "Demo Mode turned on." })

        model.makeCurrent(current)
        #expect(model.isDemoMode, "choosing the tenant already in use from code leaves the switch alone")
        model.isDemoMode = false
        #expect(try !model.activeWorkspace().environment.isDemo)
        #expect(model.currentTenantID == current)
        #expect(try String(contentsOf: folder.appending(path: "tenants.json"), encoding: .utf8) == saved)
    }
}

@Suite("Demo mode's Contoso sample data")
struct DemoSampleDataTests {
    @Test("Every UUID is in JTKit's reserved fake range; identifiers and addresses are Contoso's")
    func clearlyFake() {
        let texts = Array(DemoFixtures.profilesByKey.values)
            + DemoFixtures.platformGroups.map(\.id)
        for text in texts {
            for match in text.matches(of: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/) {
                #expect(DemoSamples.isDemoID(String(match.output)), "\(match.output)")
            }
            #expect(!text.contains("com.example"))
            #expect(!text.contains("example.com"))
            #expect(!text.contains("Example"))
        }
        for xml in DemoFixtures.profilesByKey.values {
            let name = xml.firstMatch(of: /<general><id>\d+<\/id><name>([^<]*)<\/name>/)?.1
            #expect(name?.hasPrefix("Contoso – ") == true, "\(name ?? "")")
            for identifier in xml.matches(of: /com\.[a-z]+\.[A-Za-z.]+/) where !identifier.output.hasPrefix("com.apple.") {
                #expect(identifier.output.hasPrefix("com.contoso.example.") || identifier.output.hasPrefix("com.google")
                        || identifier.output.hasPrefix("com.jamf"), "\(identifier.output)")
            }
        }
    }

    @Test("Contoso's groups plus a second Design Macs; Finance Macs is missing")
    func groups() {
        #expect(Array(DemoFixtures.platformGroups.prefix(DemoSamples.platformGroups.count)) == DemoSamples.platformGroups)
        #expect(DemoFixtures.platformGroups.filter { $0.name == "Design Macs" }.count == 2)
        #expect(!DemoFixtures.platformGroups.contains { $0.name == "Finance Macs" })
    }

    @Test("The scope screen shows a choice for Design Macs and nothing for Finance Macs")
    func scopeCases() throws {
        let baseline = try ClassicXMLParser.parseProfile(Data(DemoFixtures.securityBaseline.utf8), platform: .macOS)
        let entries = ScopeMapper.propose(for: baseline.scope, platform: .macOS, platformGroups: DemoFixtures.platformGroups)
        #expect(entries.first { $0.classicGroup.name == "Engineering Macs" }?.autoMatch?.id == DemoFixtures.engineersPlatformGroupID)
        let design = try #require(entries.first { $0.classicGroup.name == "Design Macs" })
        #expect(design.autoMatch == nil && design.exactMatches.count == 2, "ambiguous: the user chooses")

        let certificates = try ClassicXMLParser.parseProfile(Data(DemoFixtures.certificatesAndDates.utf8), platform: .macOS)
        let finance = ScopeMapper.propose(for: certificates.scope, platform: .macOS, platformGroups: DemoFixtures.platformGroups)
        #expect(finance.first?.isUnmatched == true)
    }
}

@Suite("Demo backups and the earlier demo name")
struct EarlierDemoNameTests {
    @Test("A backup under the earlier name \"Offline demo\" is never matched on a real tenant or in demo mode")
    func earlierName() {
        let backup = ScopeBackup(environmentName: MigrationEnvironment.earlierDemoDisplayName, environmentID: nil,
                                 platform: .macOS, profileID: 1, profileName: "p", blueprintID: nil, scopeXML: "<scope/>")
        let real = MigrationEnvironment(displayName: MigrationEnvironment.earlierDemoDisplayName, isDemo: false,
                                        environmentID: nil, classic: demoClassicAPI(),
                                        platform: DemoJamfPlatformServer().client(log: nil))
        #expect(!backup.belongs(to: real))
        #expect(!backup.belongs(to: .demo()))
    }
}
