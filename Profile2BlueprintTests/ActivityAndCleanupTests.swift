import Foundation
import Testing
@testable import Profile2Blueprint

/// Collects activity events for assertions.
final class RecordingActivity: ActivityRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ActivityEvent] = []
    var events: [ActivityEvent] { lock.withLock { stored } }
    func record(_ event: ActivityEvent) { lock.withLock { stored.append(event) } }
}

private let base = URL(string: "https://eu.api.jamfcloud.com")!
private let tokenBody = #"{"access_token":"SECRET-TOKEN-VALUE","expires_in":900,"token_type":"Bearer"}"#

private func client(_ activity: RecordingActivity, policy: ClassicWritePolicy = .denied) -> HTTPClient {
    let tokens = TokenProvider(tokenURL: base.appending(path: "auth/token"), clientID: "c", secret: { "s" },
                               session: MockURLProtocol.makeSession(), environmentName: "Test", activity: activity)
    return HTTPClient(baseURL: base, environmentID: "e77c1408-10c8-4007-b177-abc9157fbcaa", tokens: tokens,
                      session: MockURLProtocol.makeSession(), classicWritePolicy: policy,
                      environmentName: "Test", activity: activity, sleep: { _ in })
}

private let scopeOnlyBody = ClassicScopeService.unscopedBody

// MARK: - Milestone 7: activity log

/// Network-backed activity tests join the serialized `NetworkingTests` suite because
/// `MockURLProtocol`'s handler is global.
extension NetworkingTests {

    @Test("Requests, token issue, retries and errors are recorded; the token value never is")
    func requestEvents() async throws {
        let calls = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenBody) }
            if calls.next() == 1 { return .json(429, "{}", headers: ["Retry-After": "0"]) }
            return .json(400, #"{"httpStatus":400,"traceId":"trace-123","errors":{"code":"INVALID_FIELD","field":"name","description":"bad"}}"#)
        }
        let activity = RecordingActivity()
        await #expect(throws: APIError.self) {
            _ = try await client(activity).send(HTTPRequest(path: "blueprints/v1/blueprints"))
        }

        let events = activity.events
        #expect(events.map(\.category) == [.auth, .request, .retry, .request])
        #expect(events[0].message.contains("token issued"))
        #expect(events[1].status == 429)
        #expect(events[3].status == 400)
        #expect(events[3].traceId == "trace-123")
        #expect(events[3].message == "INVALID_FIELD: bad")
        #expect(events[3].durationMs != nil)
        #expect(events.allSatisfy { !$0.message.contains("SECRET-TOKEN-VALUE") })
        #expect(events.allSatisfy { $0.environment == "Test" })
    }

    @Test("Refused writes are recorded as blocked and never sent")
    func blockedEvents() async throws {
        MockURLProtocol.install { _ in Issue.record("nothing should be sent"); return .json(500, "{}") }
        let activity = RecordingActivity()
        await #expect(throws: APIError.self) {
            _ = try await client(activity).send(HTTPRequest(method: "DELETE", path: "blueprints/v1/blueprints/x"))
        }
        #expect(activity.events.map(\.category) == [.blocked])
        #expect(activity.events.first?.method == "DELETE")
        #expect(MockURLProtocol.requests.isEmpty)
    }
}

@Suite("Activity log")
struct ActivityLogTests {

    @Test("Store keeps the newest events, redacts, and persists")
    func store() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "p2b-activity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(fileURL: url, limit: 3)
        for index in 1...5 {
            await store.append(ActivityEvent(environment: "E", category: .app, message: "event \(index) Bearer abc.def"))
        }
        await store.flush()
        let reloaded = ActivityStore(fileURL: url, limit: 3)
        let messages = await reloaded.all.map(\.message)
        #expect(messages == (3...5).map { "event \($0) Bearer \(Redactor.placeholder)" })
    }

    @Test("Markdown export escapes cells")
    func markdown() {
        let text = ActivityExport.markdown([ActivityEvent(environment: "A|B", category: .request, message: "x\ny", method: "GET", path: "p", status: 200)])
        #expect(text.contains(#"A\|B"#))
        #expect(text.contains("`GET p`"))
        #expect(text.contains("x y"))
    }
}

// MARK: - Milestone 8: guarded classic scope changes

@Suite("Classic scope change guard")
struct ClassicWriteGuardTests {
    private let path = "proclassic/osxconfigurationprofiles/id/42"

    @Test("PUT is refused unless scope changes are explicitly enabled")
    func deniedByDefault() {
        #expect(!HTTPClient.isPermitted(HTTPRequest(method: "PUT", path: path, body: scopeOnlyBody)))
        #expect(!HTTPClient.isPermitted(HTTPRequest(method: "PUT", path: path, body: scopeOnlyBody), classicWrites: .denied))
        #expect(HTTPClient.isPermitted(HTTPRequest(method: "PUT", path: path, body: scopeOnlyBody), classicWrites: .scopeOnly))
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
        #expect(!HTTPClient.isPermitted(HTTPRequest(method: "PUT", path: path, body: Data(body.utf8)), classicWrites: .scopeOnly))
    }

    @Test("Enabling scope changes doesn't open DELETE, PATCH or Classic POST")
    func otherMethodsStayClosed() {
        for method in ["DELETE", "PATCH", "POST"] {
            #expect(!HTTPClient.isPermitted(HTTPRequest(method: method, path: path, body: scopeOnlyBody), classicWrites: .scopeOnly))
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
        let before = try await env.classic.profile(id: 102)

        let (backup, after) = try await ClassicScopeService.unscope(profileID: 102, blueprintID: "bp", environment: env, backups: store)
        #expect(!ClassicScopeService.hasTargets(after.scope))
        #expect(after.payloadsPlist == before.payloadsPlist, "payloads untouched")
        #expect(backup.scopeXML == before.rawScopeXML)
        #expect(try ClassicXMLParser.parseScopeXML(backup.scopeXML) == before.scope)
        #expect(await store.latest(profileID: 102, environmentID: nil, environmentName: "Test")?.id == backup.id)
        let writes = await server.scopeWrites
        #expect(writes.count == 1 && HTTPClient.isScopeOnlyProfileXML(Data(writes[0].body.utf8)))

        let restored = try await ClassicScopeService.restore(backup, environment: env, backups: store)
        #expect(restored.scope == before.scope)
        #expect(restored.payloadsPlist == before.payloadsPlist)
        #expect(await store.latest(profileID: 102, environmentID: nil, environmentName: "Test") == nil, "backup marked restored")
        #expect(await store.all.first?.restoredAt != nil)
    }

    @Test("Refuses when not enabled, and when already unscoped")
    func refusals() async throws {
        let (disabled, _) = environment(writer: false)
        await #expect(throws: ScopeChangeError.self) {
            _ = try await ClassicScopeService.unscope(profileID: 101, blueprintID: nil, environment: disabled, backups: backups())
        }
        let (env, _) = environment()
        let store = backups()
        _ = try await ClassicScopeService.unscope(profileID: 101, blueprintID: nil, environment: env, backups: store)
        await #expect(throws: ScopeChangeError.self) {
            _ = try await ClassicScopeService.unscope(profileID: 101, blueprintID: nil, environment: env, backups: store)
        }
        #expect(await store.all.count == 1, "no second backup")
    }

    @Test("Unscoped body clears targets but leaves limitations/exclusions alone")
    func unscopedBodyShape() throws {
        let xml = String(decoding: ClassicScopeService.unscopedBody, as: UTF8.self)
        #expect(HTTPClient.isScopeOnlyProfileXML(ClassicScopeService.unscopedBody))
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
        let session = try #require(workspace.session(for: 101))
        let originalScope = try #require(workspace.profiles[101]).scope
        try await Task.sleep(for: .milliseconds(50)) // let the backup lookup finish

        session.dryRun = false
        session.unscopeAfterDeploy = true
        await session.create()
        let blueprintID = try #require(session.blueprintID)
        #expect(session.fidelity?.passed == true)
        #expect(session.unscopeStatus == .notRequested, "nothing happens before deploy")

        await session.deploy(DeployConfirmation(blueprintID: blueprintID, blueprintName: "n", groupNames: ["Engineers"], deviceCount: 12, confirmedAt: Date()))
        guard case .unscoped = session.unscopeStatus else { Issue.record("\(session.unscopeStatus)"); return }
        let unscoped = try await workspace.environment.classic.profile(id: 101)
        #expect(!ClassicScopeService.hasTargets(unscoped.scope))
        #expect(workspace.history.records.contains { $0.action == .unscopeClassic && $0.result == .success })

        await session.restoreClassicScope()
        #expect(session.unscopeStatus != .notRequested)
        let restored = try await workspace.environment.classic.profile(id: 101)
        #expect(restored.scope == originalScope)
        #expect(workspace.history.records.contains { $0.action == .restoreClassicScope && $0.result == .success })
    }

    @Test("Without the opt-in, deploying leaves the classic profile scoped")
    func noOptIn() async throws {
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: 101))
        session.dryRun = false
        await session.create()
        let blueprintID = try #require(session.blueprintID)
        await session.deploy(DeployConfirmation(blueprintID: blueprintID, blueprintName: "n", groupNames: ["Engineers"], deviceCount: 12, confirmedAt: Date()))
        #expect(session.unscopeStatus == .notRequested)
        #expect(ClassicScopeService.hasTargets(try await workspace.environment.classic.profile(id: 101).scope))
    }
}
