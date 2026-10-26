import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

private let base = URL(string: "https://eu.api.jamfcloud.com")!
private let tokenBody = #"{"access_token":"SECRET-TOKEN-VALUE","expires_in":900,"token_type":"Bearer"}"#

private func client(_ log: ActivityLog, policy: ClassicWritePolicy = .denied) -> PlatformClient {
    let recorder = RequestRecorder(session: MockURLProtocol.makeSession(), log: log,
                                   service: "Jamf Platform API", connection: "Test")
    let tokens = JamfTokenProvider(tokenURL: base.appending(path: "auth/token"), method: .apiClient(clientID: "c"),
                                   secret: { "s" }, recorder: recorder)
    return PlatformClient.live(baseURL: base, environmentID: "e77c1408-10c8-4007-b177-abc9157fbcaa", tokens: tokens,
                               recorder: recorder, classicWritePolicy: policy, sleep: { _ in })
}

private let scopeOnlyBody = ClassicScopeService.unscopedBody(platform: .macOS)

// MARK: - Milestone 7: activity log (JTKit's, from step 5)

/// Network-backed activity tests join the serialized `NetworkingTests` suite because
/// `MockURLProtocol`'s handler is global.
extension NetworkingTests {

    @Test("Sign-in, requests, waits and errors are recorded; the token and the secret never are")
    @MainActor
    func requestEvents() async throws {
        let calls = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenBody) }
            if calls.next() == 1 { return .json(429, "{}", headers: ["Retry-After": "0"]) }
            return .json(400, #"{"httpStatus":400,"traceId":"trace-123","errors":{"code":"INVALID_FIELD","field":"name","description":"bad"}}"#)
        }
        let log = ActivityLog()
        await #expect(throws: APIError.self) {
            _ = try await client(log).send(HTTPRequest(path: "blueprints/v1/blueprints"))
        }

        let entries = log.entries
        #expect(entries.map(\.category) == ["Sign-in", "API", "Retry", "API"])
        #expect(entries[0].status == 200)
        #expect(entries[1].status == 429)
        #expect(entries[2].isWarning)
        #expect(entries[2].note == "HTTP 429: waiting 0 s, attempt 2 of 4.")
        #expect(entries[3].status == 400)
        #expect(entries[3].request?.responseBody?.contains("trace-123") == true, "error bodies are recorded")
        #expect(entries[3].duration != nil)
        let everything = entries.map(ActivityLogExport.transcript(of:)).joined(separator: "\n")
        #expect(!everything.contains("SECRET-TOKEN-VALUE"))
        #expect(!everything.contains("client_secret=s"))
        #expect(entries.allSatisfy { $0.connection == "Test" })
    }

    @Test("Refused writes are recorded as blocked and never sent")
    @MainActor
    func blockedEvents() async throws {
        MockURLProtocol.install { _ in Issue.record("nothing should be sent"); return .json(500, "{}") }
        let log = ActivityLog()
        await #expect(throws: APIError.self) {
            _ = try await client(log).send(HTTPRequest(method: "DELETE", path: "blueprints/v1/blueprints/x"))
        }
        #expect(log.entries.map(\.category) == ["Blocked"])
        #expect(log.entries.first?.operation == "DELETE")
        #expect(log.entries.first?.isWarning == true)
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test("Profile and Blueprint contents are never recorded: no request bodies, no successful responses")
    @MainActor
    func contentsAreNotRecorded() async throws {
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenBody) }
            if request.method == "GET" {
                return MockResponse(status: 200, headers: ["Content-Type": "application/xml"],
                                    body: Data("<os_x_configuration_profile><general><payloads>&lt;key&gt;Password&lt;/key&gt;&lt;string&gt;wifi-psk-123&lt;/string&gt;</payloads></general></os_x_configuration_profile>".utf8))
            }
            return .json(400, #"{"httpStatus":400,"errors":{"code":"INVALID_FIELD","description":"bad"}}"#)
        }
        let log = ActivityLog()
        let client = client(log)
        _ = try await client.send(HTTPRequest(path: "proclassic/osxconfigurationprofiles/id/1", accept: "application/xml"))
        await #expect(throws: APIError.self) {
            _ = try await client.send(HTTPRequest(method: "POST", path: "blueprints/v1/blueprints",
                                                  body: Data(#"{"steps":[{"Password":"wifi-psk-123"}]}"#.utf8),
                                                  contentType: "application/json"))
        }
        let everything = log.entries.map(ActivityLogExport.transcript(of:)).joined(separator: "\n")
        #expect(!everything.contains("wifi-psk-123"))
        #expect(log.entries.compactMap(\.request).allSatisfy { $0.requestBody == nil })
        #expect(everything.contains("INVALID_FIELD"), "the error answer itself is recorded")
    }
}

@Suite("Activity log entries")
@MainActor
struct ActivityLogEntryTests {

    @Test("The app's own entries keep their level, tenant and category, redacted")
    func appEntries() {
        let log = ActivityLog()
        log.app("Saved settings, token Bearer abc.def", environment: "Sandbox")
        log.app("Classic scope changes ENABLED", level: .warning, category: .classicWrite)
        log.app("Create failed", level: .error, category: .migration)

        let entries = log.entries
        #expect(entries.map(\.category) == ["App", "Classic write", "Migration"])
        #expect(entries[0].connection == "Sandbox")
        #expect(entries[0].detail == "Saved settings, token Bearer \(Redaction.placeholder)")
        #expect(entries[0].operation.isEmpty)
        #expect(!entries[0].isProblem)
        #expect(entries[1].isWarning && !entries[1].isFailure)
        #expect(entries[2].isFailure)
    }
}

// MARK: - Milestone 8: guarded classic scope changes

@Suite("Classic scope change guard")
struct ClassicWriteGuardTests {
    private let path = "proclassic/osxconfigurationprofiles/id/42"

    @Test("PUT is refused unless scope changes are explicitly enabled")
    func deniedByDefault() {
        #expect(!PlatformClient.isPermitted(HTTPRequest(method: "PUT", path: path, body: scopeOnlyBody)))
        #expect(!PlatformClient.isPermitted(HTTPRequest(method: "PUT", path: path, body: scopeOnlyBody), classicWrites: .denied))
        #expect(PlatformClient.isPermitted(HTTPRequest(method: "PUT", path: path, body: scopeOnlyBody), classicWrites: .scopeOnly))
    }

    @Test("Even when enabled, only scope-only bodies on a profile ID path pass", arguments: [
        ("<os_x_configuration_profile><general><name>x</name></general></os_x_configuration_profile>", "proclassic/osxconfigurationprofiles/id/42"),
        ("<os_x_configuration_profile><scope/><general/></os_x_configuration_profile>", "proclassic/osxconfigurationprofiles/id/42"),
        ("<os_x_configuration_profile><scope/></os_x_configuration_profile>", "proclassic/osxconfigurationprofiles/name/x"),
        ("<os_x_configuration_profile><scope/></os_x_configuration_profile>", "proclassic/policies/id/42"),
        ("<os_x_configuration_profile><scope/></os_x_configuration_profile>", "proclassic/osxconfigurationprofiles/id/42/extra"),
        ("<computer><scope/></computer>", "proclassic/osxconfigurationprofiles/id/42"),
        ("not xml", "proclassic/osxconfigurationprofiles/id/42"),
    ])
    func onlyScope(body: String, path: String) {
        #expect(!PlatformClient.isPermitted(HTTPRequest(method: "PUT", path: path, body: Data(body.utf8)), classicWrites: .scopeOnly))
    }

    @Test("Enabling scope changes doesn't open DELETE, PATCH or Classic POST")
    func otherMethodsStayClosed() {
        for method in ["DELETE", "PATCH", "POST"] {
            #expect(!PlatformClient.isPermitted(HTTPRequest(method: method, path: path, body: scopeOnlyBody), classicWrites: .scopeOnly))
        }
    }

    @Test("Tenants saved before the setting existed decode with it off")
    func tenantDefaultsOff() throws {
        let legacy = #"{"id":"8F2A6C1E-3B4D-4E5F-9A7B-1C2D3E4F5A6B","name":"Old","region":"eu","environmentID":"x","clientID":"c"}"#
        let tenant = try JSONDecoder().decode(Tenant.self, from: Data(legacy.utf8))
        #expect(tenant.allowClassicScopeChanges == false)
        #expect(Tenant().allowClassicScopeChanges == false)
    }
}

@Suite("Classic scope service", .serialized)
struct ClassicScopeServiceTests {
    private func environment(writer: Bool = true) -> (MigrationEnvironment, DemoClassicServer) {
        let server = DemoClassicServer()
        return (MigrationEnvironment(
            displayName: "Test", isDemo: true, environmentID: nil,
            classic: DemoClassicAPI(server: server), groups: DemoDeviceGroupsAPI(),
            blueprints: DemoBlueprintsAPI(server: DemoBlueprintServer()),
            classicScopeWriter: writer ? DemoClassicScopeWriter(server: server) : nil
        ), server)
    }

    private func backups() -> ScopeBackupStore {
        ScopeBackupStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "p2b-backups-\(UUID().uuidString).json"))
    }

    @Test("Unscope backs up, sends a scope-only body, verifies, and restore puts it back")
    func unscopeAndRestore() async throws {
        let (env, server) = environment()
        let store = backups()
        let before = try await env.classic.profile(key: ProfileKey(platform: .macOS, id: 102))

        let (backup, after) = try await ClassicScopeService.unscope(key: ProfileKey(platform: .macOS, id: 102), blueprintID: "bp", environment: env, backups: store)
        #expect(!ClassicScopeService.hasTargets(after.scope))
        #expect(after.payloadsPlist == before.payloadsPlist, "payloads untouched")
        #expect(backup.scopeXML == before.rawScopeXML)
        #expect(try ClassicXMLParser.parseScopeXML(backup.scopeXML, platform: .macOS) == before.scope)
        #expect(await store.latest(key: ProfileKey(platform: .macOS, id: 102), environmentID: nil, environmentName: "Test")?.id == backup.id)
        let writes = await server.scopeWrites
        #expect(writes.count == 1 && PlatformClient.isScopeOnlyProfileXML(Data(writes[0].body.utf8)))

        let restored = try await ClassicScopeService.restore(backup, environment: env, backups: store)
        #expect(restored.scope == before.scope)
        #expect(restored.payloadsPlist == before.payloadsPlist)
        #expect(await store.latest(key: ProfileKey(platform: .macOS, id: 102), environmentID: nil, environmentName: "Test") == nil, "backup marked restored")
        #expect(await store.all.first?.restoredAt != nil)
    }

    @Test("Refuses when not enabled, and when already unscoped")
    func refusals() async throws {
        let (disabled, _) = environment(writer: false)
        await #expect(throws: ScopeChangeError.self) {
            _ = try await ClassicScopeService.unscope(key: ProfileKey(platform: .macOS, id: 101), blueprintID: nil, environment: disabled, backups: backups())
        }
        let (env, _) = environment()
        let store = backups()
        _ = try await ClassicScopeService.unscope(key: ProfileKey(platform: .macOS, id: 101), blueprintID: nil, environment: env, backups: store)
        await #expect(throws: ScopeChangeError.self) {
            _ = try await ClassicScopeService.unscope(key: ProfileKey(platform: .macOS, id: 101), blueprintID: nil, environment: env, backups: store)
        }
        #expect(await store.all.count == 1, "no second backup")
    }

    @Test("Unscoped body clears targets but leaves limitations/exclusions alone")
    func unscopedBodyShape() throws {
        let xml = String(decoding: ClassicScopeService.unscopedBody(platform: .macOS), as: UTF8.self)
        #expect(PlatformClient.isScopeOnlyProfileXML(ClassicScopeService.unscopedBody(platform: .macOS)))
        #expect(xml.contains("<all_computers>false</all_computers>"))
        #expect(xml.contains("<computer_groups/>"))
        #expect(!xml.contains("exclusions") && !xml.contains("limitations") && !xml.contains("payloads"))
    }

    @Test("Auto-unscope only after a fully clean deployment", arguments: [
        (DeploymentOutcome.succeeded(BlueprintReport(succeeded: 12, failed: 0, pending: 0)), true),
        (DeploymentOutcome.succeeded(BlueprintReport(succeeded: 11, failed: 1, pending: 0)), false),
        (DeploymentOutcome.succeeded(BlueprintReport(succeeded: 10, failed: 0, pending: 2)), false),
        (DeploymentOutcome.succeeded(BlueprintReport(succeeded: 0, failed: 0, pending: 0)), false),
        (DeploymentOutcome.succeeded(nil), false),
        (DeploymentOutcome.timedOut(nil), false),
        (DeploymentOutcome.failed(DeploymentState(state: "NOT_DEPLOYED", lastDeployment: Deployment(started: nil, state: "FAILED"))), false),
    ])
    func cleanDeploymentGate(outcome: DeploymentOutcome, allowed: Bool) {
        #expect(ClassicScopeService.deploymentAllowsUnscope(outcome) == allowed)
    }
}

@Suite("Session cleanup flow", .serialized)
@MainActor
struct SessionCleanupTests {
    @Test("Opt-in auto-unscope runs after a clean demo deploy; restore puts the scope back")
    func autoUnscope() async throws {
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: ProfileKey(platform: .macOS, id: 101)))
        let originalScope = try #require(workspace.profiles[ProfileKey(platform: .macOS, id: 101)]).scope
        try await Task.sleep(for: .milliseconds(50)) // let the backup lookup finish

        session.dryRun = false
        session.unscopeAfterDeploy = true
        await session.create()
        let blueprintID = try #require(session.blueprintID)
        #expect(session.fidelity?.passed == true)
        #expect(session.unscopeStatus == .notRequested, "nothing happens before deploy")

        await session.deploy(DeployConfirmation(blueprintID: blueprintID, blueprintName: "n", groupNames: ["Engineers"], deviceCount: 12, confirmedAt: Date()))
        guard case .unscoped = session.unscopeStatus else { Issue.record("\(session.unscopeStatus)"); return }
        let unscoped = try await workspace.environment.classic.profile(key: ProfileKey(platform: .macOS, id: 101))
        #expect(!ClassicScopeService.hasTargets(unscoped.scope))
        #expect(workspace.history.records.contains { $0.action == .unscopeClassic && $0.result == .success })

        await session.restoreClassicScope()
        #expect(session.unscopeStatus != .notRequested)
        let restored = try await workspace.environment.classic.profile(key: ProfileKey(platform: .macOS, id: 101))
        #expect(restored.scope == originalScope)
        #expect(workspace.history.records.contains { $0.action == .restoreClassicScope && $0.result == .success })
    }

    @Test("Without the opt-in, deploying leaves the classic profile scoped")
    func noOptIn() async throws {
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: ProfileKey(platform: .macOS, id: 101)))
        session.dryRun = false
        await session.create()
        let blueprintID = try #require(session.blueprintID)
        await session.deploy(DeployConfirmation(blueprintID: blueprintID, blueprintName: "n", groupNames: ["Engineers"], deviceCount: 12, confirmedAt: Date()))
        #expect(session.unscopeStatus == .notRequested)
        #expect(ClassicScopeService.hasTargets(try await workspace.environment.classic.profile(key: ProfileKey(platform: .macOS, id: 101)).scope))
    }
}
