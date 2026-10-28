import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

private let base = URL(string: "https://eu.api.jamfcloud.com")!
private let tokenBody = #"{"access_token":"SECRET-TOKEN-VALUE","expires_in":900,"token_type":"Bearer"}"#

private func client(_ log: ActivityLog, policy: ClassicWritePolicy = .denied) throws -> JamfPlatform.Client {
    let recorder = RequestRecorder(session: MockURLProtocol.makeSession(), log: log,
                                   service: "Jamf Platform API", connection: "Test")
    let tokens = JamfTokenProvider(tokenURL: base.appending(path: "auth/token"), method: .apiClient(clientID: "c"),
                                   secret: { "s" }, recorder: recorder)
    return try JamfPlatform.Client(baseURL: base, scope: .environment("e77c1408-10c8-4007-b177-abc9157fbcaa"), tokens: tokens,
                                   recorder: recorder, permits: { RequestPolicy.isPermitted($0, classicWrites: policy) },
                                   hints: RequestPolicy.hints(for:), sleep: { _ in })
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
        let client = try client(log)
        await #expect(throws: JamfPlatformError.self) {
            _ = try await client.send(HTTPRequest(path: "blueprints/v1/blueprints"))
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
        let client = try client(log)
        await #expect(throws: JamfPlatformError.self) {
            _ = try await client.send(HTTPRequest(method: "DELETE", path: "blueprints/v1/blueprints/x"))
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
        let client = try client(log)
        _ = try await client.send(HTTPRequest(path: "proclassic/osxconfigurationprofiles/id/1", accept: "application/xml"))
        await #expect(throws: JamfPlatformError.self) {
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
        #expect(!RequestPolicy.isPermitted(HTTPRequest(method: "PUT", path: path, body: scopeOnlyBody)))
        #expect(!RequestPolicy.isPermitted(HTTPRequest(method: "PUT", path: path, body: scopeOnlyBody), classicWrites: .denied))
        #expect(RequestPolicy.isPermitted(HTTPRequest(method: "PUT", path: path, body: scopeOnlyBody), classicWrites: .scopeOnly))
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
        #expect(!RequestPolicy.isPermitted(HTTPRequest(method: "PUT", path: path, body: Data(body.utf8)), classicWrites: .scopeOnly))
    }

    @Test("Enabling scope changes doesn't open DELETE, PATCH or Classic POST")
    func otherMethodsStayClosed() {
        for method in ["DELETE", "PATCH", "POST"] {
            #expect(!RequestPolicy.isPermitted(HTTPRequest(method: method, path: path, body: scopeOnlyBody), classicWrites: .scopeOnly))
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
            classic: demoClassicAPI(server), platform: DemoJamfPlatformServer().client(log: nil),
            classicScopeWriter: writer ? demoScopeWriter(server) : nil
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
        #expect(await store.latest(key: ProfileKey(platform: .macOS, id: 102), environment: env)?.id == backup.id)
        let writes = server.scopeWrites
        #expect(writes.count == 1 && RequestPolicy.isScopeOnlyProfileXML(Data(writes[0].body.utf8)))

        let restored = try await ClassicScopeService.restore(backup, environment: env, backups: store)
        #expect(restored.scope == before.scope)
        #expect(restored.payloadsPlist == before.payloadsPlist)
        #expect(await store.latest(key: ProfileKey(platform: .macOS, id: 102), environment: env) == nil, "backup marked restored")
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
        #expect(RequestPolicy.isScopeOnlyProfileXML(ClassicScopeService.unscopedBody(platform: .macOS)))
        #expect(xml.contains("<all_computers>false</all_computers>"))
        #expect(xml.contains("<computer_groups/>"))
        #expect(!xml.contains("exclusions") && !xml.contains("limitations") && !xml.contains("payloads"))
    }

    @Test("Auto-unscope only after a fully clean deployment", arguments: [
        (DeploymentOutcome.succeeded(JamfPlatform.BlueprintReport(succeeded: 12, failed: 0, pending: 0)), true),
        (DeploymentOutcome.succeeded(JamfPlatform.BlueprintReport(succeeded: 11, failed: 1, pending: 0)), false),
        (DeploymentOutcome.succeeded(JamfPlatform.BlueprintReport(succeeded: 10, failed: 0, pending: 2)), false),
        (DeploymentOutcome.succeeded(JamfPlatform.BlueprintReport(succeeded: 0, failed: 0, pending: 0)), false),
        (DeploymentOutcome.succeeded(nil), false),
        (DeploymentOutcome.timedOut(nil), false),
        (DeploymentOutcome.failed(JamfPlatform.DeploymentStatus(jobState: "FAILED", blueprintState: .notDeployed)), false),
    ])
    func cleanDeploymentGate(outcome: DeploymentOutcome, allowed: Bool) {
        #expect(ClassicScopeService.deploymentAllowsUnscope(outcome) == allowed)
    }

    @Test("A clean deployment is one success with nothing failed or pending, at the boundary", arguments: [
        (1, 0, 0, true),
        (1, 1, 0, false),
        (1, 0, 1, false),
        (0, 0, 0, false), // a Blueprint scoped to empty groups: nothing succeeded
        (0, 1, 0, false),
        (0, 0, 1, false),
    ])
    func cleanDeploymentBoundary(succeeded: Int, failed: Int, pending: Int, allowed: Bool) {
        let report = JamfPlatform.BlueprintReport(succeeded: succeeded, failed: failed, pending: pending)
        #expect(ClassicScopeService.deploymentAllowsUnscope(.succeeded(report)) == allowed)
    }

    @Test("Every mix of counts: clean only with at least one success and no failures or pending")
    func cleanDeploymentEveryMix() {
        for succeeded in 0...3 {
            for failed in 0...2 {
                for pending in 0...2 {
                    let report = JamfPlatform.BlueprintReport(succeeded: succeeded, failed: failed, pending: pending)
                    let expected = succeeded >= 1 && failed == 0 && pending == 0
                    #expect(ClassicScopeService.deploymentAllowsUnscope(.succeeded(report)) == expected,
                            "succeeded \(succeeded), failed \(failed), pending \(pending)")
                }
            }
        }
        // Without a finished deployment's report it never qualifies.
        #expect(!ClassicScopeService.deploymentAllowsUnscope(nil))
        #expect(!ClassicScopeService.deploymentAllowsUnscope(.timedOut(nil)))
        #expect(!ClassicScopeService.deploymentAllowsUnscope(.succeeded(nil)))
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

        await session.deploy(DeployConfirmation(blueprintID: blueprintID, blueprintName: "n", groupNames: ["Engineering Macs"], deviceCount: 12, confirmedAt: Date()))
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
        await session.deploy(DeployConfirmation(blueprintID: blueprintID, blueprintName: "n", groupNames: ["Engineering Macs"], deviceCount: 12, confirmedAt: Date()))
        #expect(session.unscopeStatus == .notRequested)
        #expect(ClassicScopeService.hasTargets(try await workspace.environment.classic.profile(key: ProfileKey(platform: .macOS, id: 101)).scope))
    }
}

// MARK: - Demo mode keeps its own files

@Suite("Demo mode's own files", .serialized)
@MainActor
struct DemoFilesTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "p2b-demo-files-\(UUID().uuidString)")
    var realHistory: URL { folder.appending(path: "real/history.json") }
    var demoFolder: URL { folder.appending(path: "demo") }

    private func makeModel(demoMode: Bool) -> AppModel {
        AppModel(
            store: TenantStore(fileURL: folder.appending(path: "real/tenants.json")),
            secrets: InMemorySecretStore(),
            history: HistoryStore(fileURL: realHistory),
            demoFiles: DemoFiles(folder: demoFolder),
            demoMode: demoMode
        )
    }

    /// Waits for a file that is written in the background.
    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: url.path()) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Demo history, scope backups and sessions go to the demo folder, never the real files")
    func demoWritesStayInTheDemoFolder() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel(demoMode: true)
        let workspace = try model.activeWorkspace()

        #expect(workspace.history === model.demoHistory)
        #expect(model.currentHistory === model.demoHistory)
        #expect(await workspace.scopeBackups.fileURL == demoFolder.appending(path: "scope-backups.json"))
        #expect(await workspace.sessionStates.fileURL == demoFolder.appending(path: "sessions.json"))

        // A demo unscope writes a scope backup and a history entry.
        let key = ProfileKey(platform: .macOS, id: 102)
        let (backup, _) = try await ClassicScopeService.unscope(key: key, blueprintID: "bp", environment: workspace.environment,
                                                                 backups: workspace.scopeBackups)
        let profile = try await workspace.environment.classic.profile(key: key)
        workspace.history.record(.unscopeClassic, environment: workspace.environment, profile: profile,
                                 result: .success, message: "Demo unscope")
        try await waitForFile(demoFolder.appending(path: "history.json"))

        #expect(await DemoFiles(folder: demoFolder).history.all.map(\.tenantName) == [MigrationEnvironment.demoDisplayName])
        #expect(await DemoFiles(folder: demoFolder).scopeBackups.all.map(\.id) == [backup.id])
        #expect(!FileManager.default.fileExists(atPath: realHistory.path()), "the real history is never written in demo mode")
        #expect(model.history.records.isEmpty)
    }

    @Test("Outside demo mode, History shows the real history")
    func realHistoryOutsideDemoMode() {
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel(demoMode: false)
        #expect(model.currentHistory === model.history)
    }
}

// MARK: - A scope backup is only restored where it was taken

@Suite("Scope backups stay with their environment", .serialized)
struct ScopeBackupEnvironmentTests {
    private let realID = "e77c1408-10c8-4007-b177-abc9157fbcaa"

    private func environment(demo: Bool, server: DemoClassicServer, id: String? = nil) -> MigrationEnvironment {
        MigrationEnvironment(
            displayName: demo ? MigrationEnvironment.demoDisplayName : "Sandbox", isDemo: demo,
            environmentID: demo ? nil : (id ?? realID),
            classic: demoClassicAPI(server), platform: DemoJamfPlatformServer().client(log: nil),
            classicScopeWriter: demoScopeWriter(server)
        )
    }

    private func backups() -> ScopeBackupStore {
        ScopeBackupStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "p2b-backups-\(UUID().uuidString).json"))
    }

    @Test("A demo backup is never restored on a real tenant, and nothing is sent")
    func demoBackupRefusedOnRealTenant() async throws {
        let server = DemoClassicServer()
        let store = backups()
        let (backup, _) = try await ClassicScopeService.unscope(key: ProfileKey(platform: .macOS, id: 102), blueprintID: nil,
                                                                 environment: environment(demo: true, server: server), backups: store)
        await #expect(throws: ScopeChangeError.self) {
            _ = try await ClassicScopeService.restore(backup, environment: environment(demo: false, server: server), backups: store)
        }
        #expect(server.scopeWrites.count == 1, "only the unscope, no restore write")
        #expect(await store.all.first?.restoredAt == nil)
    }

    @Test("A real tenant's backup is never restored in demo mode or on another tenant")
    func realBackupRefusedElsewhere() async throws {
        let server = DemoClassicServer()
        let store = backups()
        let (backup, _) = try await ClassicScopeService.unscope(key: ProfileKey(platform: .macOS, id: 102), blueprintID: nil,
                                                                 environment: environment(demo: false, server: server), backups: store)
        await #expect(throws: ScopeChangeError.self) {
            _ = try await ClassicScopeService.restore(backup, environment: environment(demo: true, server: server), backups: store)
        }
        await #expect(throws: ScopeChangeError.self) {
            _ = try await ClassicScopeService.restore(backup, environment: environment(demo: false, server: server,
                                                                                       id: "0f0e0d0c-0b0a-4000-8000-000000000001"),
                                                      backups: store)
        }
        #expect(server.scopeWrites.count == 1)

        _ = try await ClassicScopeService.restore(backup, environment: environment(demo: false, server: server), backups: store)
        #expect(server.scopeWrites.count == 2, "restored on its own tenant")
    }

    @Test("A backup without an Environment ID matches by name, never the demo's")
    func backupWithoutEnvironmentID() {
        let server = DemoClassicServer()
        func backup(named name: String) -> ScopeBackup {
            ScopeBackup(environmentName: name, environmentID: nil, platform: .macOS, profileID: 1, profileName: "p",
                        blueprintID: nil, scopeXML: "<scope/>")
        }
        #expect(backup(named: "Sandbox").belongs(to: environment(demo: false, server: server)))
        #expect(!backup(named: MigrationEnvironment.demoDisplayName).belongs(to: environment(demo: false, server: server)))
        #expect(backup(named: MigrationEnvironment.demoDisplayName).belongs(to: environment(demo: true, server: server)))
    }
}
