import AppKit
import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

// The release gate's review findings, each with a test that keeps it fixed:
// the classic scope cleanup (Restore stays restored, failed writes never read
// as "unscoped", the tenant's switch stops pending cleanups, the Blueprint
// must cover the classic scope), the stores, and the migration's stages.

private let loginItems = ProfileKey(platform: .macOS, id: 101) // scoped to Engineering Macs only
private let wifiAllComputers = ProfileKey(platform: .macOS, id: 105) // scoped to all computers

private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "p2b-gate-\(UUID().uuidString)-\(name)")
}

@MainActor
private func confirmation(_ session: MigrationSession) throws -> DeployConfirmation {
    DeployConfirmation(blueprintID: try #require(session.blueprintID), blueprintName: "n",
                       groupNames: session.selectedGroups.map(\.name), deviceCount: session.deviceCount, confirmedAt: Date())
}

/// A writer that fails without reaching Jamf Pro (a 403, say).
private struct RefusingWriter: ClassicScopeWriter {
    func replaceScope(key: ProfileKey, body: Data) async throws {
        throw ScopeChangeError(message: "403: the integration lacks configuration-profiles:update")
    }
}

/// A writer whose change reaches Jamf Pro, but whose answer is lost.
private struct AnswerLostWriter: ClassicScopeWriter {
    let inner: LiveClassicScopeWriter
    func replaceScope(key: ProfileKey, body: Data) async throws {
        try await inner.replaceScope(key: key, body: body)
        throw URLError(.networkConnectionLost)
    }
}

/// The demo's Classic reads, failing every read once `failing` is on.
private final class FlakyClassic: ClassicAPI, @unchecked Sendable {
    let inner: LiveClassicAPI
    private let lock = NSLock()
    private var isFailing = false
    init(_ inner: LiveClassicAPI) { self.inner = inner }
    var failing: Bool {
        get { lock.withLock { isFailing } }
        set { lock.withLock { isFailing = newValue } }
    }
    func listProfiles(platform: ProfilePlatform) async throws -> [ClassicProfileSummary] {
        try await inner.listProfiles(platform: platform)
    }
    func profile(key: ProfileKey) async throws -> ClassicProfile {
        if failing { throw URLError(.timedOut) }
        return try await inner.profile(key: key)
    }
}

/// A writer that turns on `classic.failing` right after its write, so the read-back fails.
private struct ThenReadsFail: ClassicScopeWriter {
    let inner: LiveClassicScopeWriter
    let classic: FlakyClassic
    func replaceScope(key: ProfileKey, body: Data) async throws {
        try await inner.replaceScope(key: key, body: body)
        classic.failing = true
    }
}

/// The demo's Classic reads, with the mobile list refused.
private struct NoMobileList: ClassicAPI {
    let inner: LiveClassicAPI
    func listProfiles(platform: ProfilePlatform) async throws -> [ClassicProfileSummary] {
        if platform == .mobile { throw ScopeChangeError(message: "403: no permission for mobile device profiles") }
        return try await inner.listProfiles(platform: platform)
    }
    func profile(key: ProfileKey) async throws -> ClassicProfile { try await inner.profile(key: key) }
}

/// A demo environment on one Classic server, with the writer and switch given.
private func environment(
    classicServer: DemoClassicServer = DemoClassicServer(),
    classic: (any ClassicAPI)? = nil,
    writer: (any ClassicScopeWriter)? = nil,
    scopeChanges: ClassicWriteSwitch = ClassicWriteSwitch(true)
) -> MigrationEnvironment {
    let client = MigrationEnvironment.demoClient(classicServer: classicServer)
    return MigrationEnvironment(
        displayName: MigrationEnvironment.demoDisplayName, isDemo: true, environmentID: nil,
        classic: classic ?? LiveClassicAPI(client: client), platform: client,
        classicScopeWriter: writer ?? LiveClassicScopeWriter(client: client),
        scopeChanges: scopeChanges)
}

/// Opens the profile's migration, creates and verifies its Blueprint.
@MainActor
private func created(_ key: ProfileKey, in workspace: Workspace, unscopeAfterDeploy: Bool = false) async throws -> MigrationSession {
    let session = try #require(workspace.session(for: key))
    await session.waitUntilReady()
    session.dryRun = false
    session.acknowledgedWarnings = true
    session.unscopeAfterDeploy = unscopeAfterDeploy
    await session.create()
    try #require(session.blueprintID != nil, "create: \(String(describing: session.lastError))")
    return session
}

@MainActor
private func isScoped(_ key: ProfileKey, _ environment: MigrationEnvironment) async throws -> Bool {
    ClassicScopeService.hasTargets(try await environment.classic.profile(key: key).scope)
}

// MARK: - Restore Scope stays restored (finding 1)

@Suite("Restore Scope is never undone", .serialized)
@MainActor
struct RestoreStaysRestoredTests {
    @Test("After Restore, Refresh Status and a relaunch don't unscope again")
    func restoreThenRefreshAndRelaunch() async throws {
        let server = DemoClassicServer()
        let env = environment(classicServer: server)
        let backups = ScopeBackupStore(fileURL: temporaryFile("backups.json"))
        let sessions = SessionStateStore(fileURL: temporaryFile("sessions.json"))
        let workspace = Workspace.previewDemo(environment: env, scopeBackups: backups, sessionStates: sessions)
        let session = try await created(loginItems, in: workspace, unscopeAfterDeploy: true)
        await session.deploy(try confirmation(session))
        guard case .unscoped = session.unscopeStatus else { Issue.record("\(session.unscopeStatus)"); return }

        await session.restoreClassicScope()
        #expect(try await isScoped(loginItems, env))
        #expect(!session.unscopeAfterDeploy, "the opt-in is turned off")
        #expect(!session.autoUnscopeArmed)

        await session.recheckDeployment()
        #expect(try await isScoped(loginItems, env), "Refresh Status leaves the restored scope")

        // A relaunch: a new workspace on the same files.
        let reopened = Workspace.previewDemo(environment: env, scopeBackups: backups, sessionStates: sessions)
        let resumed = try #require(reopened.session(for: loginItems))
        await resumed.waitUntilReady()
        for _ in 0..<50 { await Task.yield() }
        #expect(resumed.blueprintID == session.blueprintID)
        #expect(resumed.scopeChangedBefore && !resumed.unscopeAfterDeploy && !resumed.autoUnscopeArmed)
        #expect(try await isScoped(loginItems, env), "the relaunch leaves the restored scope")
        #expect(server.scopeWrites.count == 2, "only the unscope and the restore")
    }
}

// MARK: - Failed writes never read as "unscoped" (findings 3 and 10)

@Suite("Scope backups record whether the write happened", .serialized)
@MainActor
struct ScopeWriteOutcomeTests {
    @Test("A refused PUT leaves no backup that reads as unscoped, also after a relaunch")
    func refusedWrite() async throws {
        let server = DemoClassicServer()
        let backups = ScopeBackupStore(fileURL: temporaryFile("backups.json"))
        let refusing = environment(classicServer: server, writer: RefusingWriter())
        await #expect(throws: ScopeChangeError.self) {
            _ = try await ClassicScopeService.unscope(key: loginItems, blueprintID: nil, environment: refusing, backups: backups)
        }
        #expect(await backups.all.map(\.writeState) == [.notWritten])
        #expect(await backups.latest(key: loginItems, environment: refusing) == nil)
        #expect(await !backups.hasScopeChange(key: loginItems, environment: refusing))

        // The permission is added and the workspace rebuilt: nothing reads as unscoped.
        let workspace = Workspace.previewDemo(environment: environment(classicServer: server), scopeBackups: backups)
        let session = try #require(workspace.session(for: loginItems))
        await session.waitUntilReady()
        #expect(session.scopeBackup == nil && session.unscopeStatus == .notRequested && !session.scopeChangedBefore)
    }

    @Test("A PUT whose answer was lost but that reached Jamf Pro is found out and offered for Restore")
    func answerLost() async throws {
        let server = DemoClassicServer()
        let client = MigrationEnvironment.demoClient(classicServer: server)
        let env = environment(classicServer: server, writer: AnswerLostWriter(inner: LiveClassicScopeWriter(client: client)))
        let backups = ScopeBackupStore(fileURL: temporaryFile("backups.json"))
        await #expect(throws: URLError.self) {
            _ = try await ClassicScopeService.unscope(key: loginItems, blueprintID: nil, environment: env, backups: backups)
        }
        #expect(await backups.latest(key: loginItems, environment: env)?.writeState == .written)
    }

    @Test("When the read-back fails after the change, Restore is offered at once")
    func readBackFails() async throws {
        let server = DemoClassicServer()
        let client = MigrationEnvironment.demoClient(classicServer: server)
        let classic = FlakyClassic(LiveClassicAPI(client: client))
        let env = environment(classicServer: server, classic: classic,
                              writer: ThenReadsFail(inner: LiveClassicScopeWriter(client: client), classic: classic))
        let workspace = Workspace.previewDemo(environment: env)
        let session = try await created(loginItems, in: workspace)
        await session.deploy(try confirmation(session))
        await session.unscopeClassic()
        guard case .failed = session.unscopeStatus else { Issue.record("\(session.unscopeStatus)"); return }
        #expect(session.scopeBackup != nil)
        classic.failing = false
        #expect(session.canRestoreScope && !session.canUnscopeNow)
    }

    @Test("A backup saved without an outcome is settled by reading the profile", arguments: [true, false])
    func pendingIsSettled(changeHappened: Bool) async throws {
        let server = DemoClassicServer()
        let env = environment(classicServer: server)
        let before = try await env.classic.profile(key: loginItems)
        if changeHappened {
            try await LiveClassicScopeWriter(client: MigrationEnvironment.demoClient(classicServer: server))
                .replaceScope(key: loginItems, body: ClassicScopeService.unscopedBody(platform: .macOS))
        }
        let backups = ScopeBackupStore(fileURL: temporaryFile("backups.json"))
        try await backups.save(ScopeBackup(environmentName: env.displayName, environmentID: nil, platform: .macOS,
                                           profileID: loginItems.id, profileName: before.name, blueprintID: nil,
                                           scopeXML: before.rawScopeXML))
        let workspace = Workspace.previewDemo(environment: env, scopeBackups: backups)
        let session = try #require(workspace.session(for: loginItems))
        await session.waitUntilReady()
        if changeHappened {
            #expect(session.unscopeStatus == .unscoped(session.scopeBackup?.createdAt ?? .distantPast))
        } else {
            #expect(session.scopeBackup == nil && session.unscopeStatus == .notRequested)
        }
        #expect(await backups.all.first?.writeState == (changeHappened ? .written : .notWritten))
    }

    @Test("Backups saved before the outcome was kept decode as pending")
    func legacyBackupDecodesPending() throws {
        let json = #"[{"id":"00000000-0000-4000-8000-000000000b01","createdAt":"2026-01-01T09:00:00Z","environmentName":"Sandbox","profileID":1,"profileName":"p","scopeXML":"<scope/>"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([ScopeBackup].self, from: Data(json.utf8)).first?.writeState == .pending)
    }
}

// MARK: - The tenant's switch stops pending cleanups (findings 4 and 20)

@Suite("Turning classic scope changes off", .serialized)
@MainActor
struct ScopeSwitchTests {
    @Test("A migration still running can't change the scope once the switch is off")
    func switchOffStopsCleanup() async throws {
        let server = DemoClassicServer()
        let scopeChanges = ClassicWriteSwitch(true)
        let env = environment(classicServer: server, scopeChanges: scopeChanges)
        let session = try await created(loginItems, in: Workspace.previewDemo(environment: env), unscopeAfterDeploy: true)
        #expect(session.autoUnscopeArmed)

        scopeChanges.isOn = false
        #expect(env.classicScopeWriter == nil && !session.canChangeClassicScope && !session.autoUnscopeArmed)
        await session.deploy(try confirmation(session))
        await session.reportBecameFinal(session.deviceReport)
        #expect(server.scopeWrites.isEmpty)
        #expect(try await isScoped(loginItems, env))
        await #expect(throws: ScopeChangeError.self) {
            _ = try await ClassicScopeService.unscope(key: loginItems, blueprintID: nil, environment: env,
                                                      backups: ScopeBackupStore(fileURL: temporaryFile("b.json")))
        }
    }

    @Test("The allow-list reads the switch at every request")
    func allowListFollowsTheSwitch() {
        let scopeChanges = ClassicWriteSwitch(true)
        let put = HTTPRequest(method: "PUT", path: "proclassic/osxconfigurationprofiles/id/42",
                              body: ClassicScopeService.unscopedBody(platform: .macOS))
        #expect(RequestPolicy.isPermitted(put, classicWrites: scopeChanges.policy))
        scopeChanges.isOn = false
        #expect(!RequestPolicy.isPermitted(put, classicWrites: scopeChanges.policy))
    }

    @Test("Saving the tenant with the switch off turns it off in the workspace already open, and closes it")
    func savingTheTenantTurnsItOff() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "p2b-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(store: TenantStore(fileURL: folder.appending(path: "tenants.json")),
                             secrets: InMemorySecretStore(),
                             history: HistoryStore(fileURL: folder.appending(path: "history.json")),
                             scopeBackups: ScopeBackupStore(fileURL: folder.appending(path: "backups.json")),
                             sessionStates: SessionStateStore(fileURL: folder.appending(path: "sessions.json")),
                             demoMode: false)
        var tenant = Tenant(name: "Sandbox", region: .eu, environmentID: "0f0e0d0c-0b0a-4000-8000-00000000abcd",
                            clientID: "c", allowClassicScopeChanges: true)
        try model.connections.save(tenant)
        model.makeCurrent(tenant.id)
        let open = try model.activeWorkspace()
        #expect(open.environment.classicScopeWriter != nil)

        tenant.allowClassicScopeChanges = false
        try model.connections.save(tenant)
        #expect(open.environment.classicScopeWriter == nil, "the old workspace's writer is off at once")
        #expect(open.isClosed)
        #expect(try model.activeWorkspace().environment.classicScopeWriter == nil)
    }

    @Test("A closed workspace's migrations stop and open no new ones")
    func closedWorkspace() async throws {
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: loginItems))
        workspace.close()
        #expect(session.isClosed && !session.autoUnscopeArmed && !session.canUnscopeNow)
        #expect(workspace.session(for: wifiAllComputers) == nil)
    }
}

// MARK: - The Blueprint must cover the classic scope (finding 6)

@Suite("Automatic cleanup only where the Blueprint reaches every device", .serialized)
@MainActor
struct ScopeCoverageTests {
    @Test("All computers isn't covered by a group: no automatic cleanup after a clean deployment")
    func allComputersHeldBack() async throws {
        let server = DemoClassicServer()
        let env = environment(classicServer: server)
        let workspace = Workspace.previewDemo(environment: env)
        let session = try #require(workspace.session(for: wifiAllComputers))
        await session.waitUntilReady()
        session.toggleGroup(DemoFixtures.engineersPlatformGroupID)
        session.acknowledgedWarnings = true
        session.dryRun = false
        session.unscopeAfterDeploy = true
        #expect(session.uncoveredClassicTargets.contains("all computers"))
        #expect(!session.autoUnscopeArmed, "the deploy sheet doesn't promise cleanup")
        await session.create()
        await session.deploy(try confirmation(session))
        #expect(ClassicScopeService.deploymentAllowsUnscope(session.outcome), "the deployment itself was clean")
        guard case .heldBack = session.unscopeStatus else { Issue.record("\(session.unscopeStatus)"); return }
        #expect(server.scopeWrites.isEmpty)
    }

    @Test("A classic group whose platform group isn't one of the Blueprint's isn't covered")
    func otherGroupHeldBack() async throws {
        let server = DemoClassicServer()
        let env = environment(classicServer: server)
        let session = try #require(Workspace.previewDemo(environment: env).session(for: loginItems))
        await session.waitUntilReady()
        #expect(session.uncoveredClassicTargets.isEmpty, "Engineering Macs maps to the selected group")
        let other = try #require(DemoFixtures.platformGroups.first {
            $0.deviceType == .computer && $0.id != DemoFixtures.engineersPlatformGroupID
        })
        session.toggleGroup(DemoFixtures.engineersPlatformGroupID)
        session.toggleGroup(other.id)
        #expect(session.uncoveredClassicTargets == ["group “Engineering Macs”"])
        // The service checks the fresh scope too, whoever calls it.
        let coverage = ScopeCoverage(platform: .macOS, platformGroups: DemoFixtures.platformGroups, blueprintGroupIDs: [other.id])
        await #expect(throws: ScopeChangeError.self) {
            _ = try await ClassicScopeService.unscope(key: loginItems, blueprintID: nil, environment: env,
                                                      backups: ScopeBackupStore(fileURL: temporaryFile("b.json")), requiring: coverage)
        }
        #expect(server.scopeWrites.isEmpty)
    }

    @Test("Every kind of non-group target counts; limitations and exclusions don't")
    func targetKinds() throws {
        let profile = try ClassicXMLParser.parseProfile(Data(try #require(DemoFixtures.profilesByKey[wifiAllComputers]).utf8), platform: .macOS)
        let coverage = ScopeCoverage(platform: .macOS, platformGroups: DemoFixtures.platformGroups, blueprintGroupIDs: [])
        #expect(coverage.uncovered(in: profile.scope) == ["all computers", "building “HQ”"])
        #expect(coverage.uncovered(in: ClassicScope()).isEmpty)
    }
}

// MARK: - One store per file; unreadable files are kept (findings 2, 7, 16)

@Suite("The app's stores", .serialized)
@MainActor
struct StoreTests {
    @Test("Every tenant workspace gets the same scope backup and session stores")
    func oneStorePerFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "p2b-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(store: TenantStore(fileURL: folder.appending(path: "tenants.json")),
                             secrets: InMemorySecretStore(),
                             history: HistoryStore(fileURL: folder.appending(path: "history.json")),
                             scopeBackups: ScopeBackupStore(fileURL: folder.appending(path: "backups.json")),
                             sessionStates: SessionStateStore(fileURL: folder.appending(path: "sessions.json")),
                             demoMode: false)
        var tenant = Tenant(name: "Sandbox", region: .eu, environmentID: "0f0e0d0c-0b0a-4000-8000-00000000abcd", clientID: "c")
        try model.connections.save(tenant)
        model.makeCurrent(tenant.id)
        let first = try model.activeWorkspace()
        tenant.name = "Sandbox 2"
        try model.connections.save(tenant)
        let second = try model.activeWorkspace()
        #expect(first !== second)
        #expect(first.scopeBackups === second.scopeBackups)
        #expect(first.sessionStates === second.sessionStates)

        model.isDemoMode = true
        let demoA = try model.activeWorkspace()
        model.isDemoMode = false
        _ = try model.activeWorkspace()
        model.isDemoMode = true
        let demoB = try model.activeWorkspace()
        #expect(demoA.scopeBackups === demoB.scopeBackups && demoA.sessionStates === demoB.sessionStates)
    }

    @Test("An unreadable backup file is kept, copied, and never written over")
    func unreadableBackups() async throws {
        let url = temporaryFile("scope-backups.json")
        try Data("not json".utf8).write(to: url)
        let store = ScopeBackupStore(fileURL: url)
        #expect(await store.problem != nil)
        await #expect(throws: StoredListError.self) {
            try await store.save(ScopeBackup(environmentName: "x", environmentID: nil, platform: .macOS, profileID: 1,
                                             profileName: "p", blueprintID: nil, scopeXML: "<scope/>"))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
        let copies = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".unreadable-") }
        #expect(copies.count == 1)
    }

    @Test("An unreadable history or session file is kept too, and the failure is reported")
    func unreadableHistoryAndSessions() async throws {
        let historyURL = temporaryFile("history.json")
        let sessionsURL = temporaryFile("sessions.json")
        for url in [historyURL, sessionsURL] { try Data("[{".utf8).write(to: url) }

        let log = HistoryLog(store: HistoryStore(fileURL: historyURL))
        var reported: String?
        log.onSaveFailure = { reported = $0 }
        let profile = try ClassicXMLParser.parseProfile(Data(try #require(DemoFixtures.profilesByKey[loginItems]).utf8), platform: .macOS)
        log.record(.dryRun, environment: .demo(), profile: profile, result: .success, message: "m")
        for _ in 0..<200 where reported == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reported?.contains("history couldn’t be saved") == true)
        #expect(try String(contentsOf: historyURL, encoding: .utf8) == "[{")

        let sessions = SessionStateStore(fileURL: sessionsURL)
        await #expect(throws: StoredListError.self) {
            try await sessions.save(PersistedMigration(environmentKey: "e", platform: .macOS, profileID: 1, blueprintID: "b",
                                                       blueprintName: "n", selectedGroupIDs: [], unscopeAfterDeploy: false))
        }
        #expect(try String(contentsOf: sessionsURL, encoding: .utf8) == "[{")
    }

    @Test("A migration that can't be saved for the next launch says so")
    func sessionSaveFailureShown() async throws {
        let url = temporaryFile("sessions.json")
        try Data("[{".utf8).write(to: url)
        let workspace = Workspace.previewDemo(sessionStates: SessionStateStore(fileURL: url))
        let session = try await created(loginItems, in: workspace)
        for _ in 0..<200 where session.lastError == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.lastError?.title.contains("couldn’t be saved for the next launch") == true)
    }

    @Test("The description is saved with the migration and comes back after a relaunch")
    func descriptionPersisted() async throws {
        let sessions = SessionStateStore(fileURL: temporaryFile("sessions.json"))
        let env = environment()
        let first = Workspace.previewDemo(environment: env, sessionStates: sessions)
        let session = try #require(first.session(for: loginItems))
        await session.waitUntilReady()
        session.blueprintDescription = "Edited by hand"
        session.dryRun = false
        await session.create()
        try #require(session.blueprintID != nil)
        for _ in 0..<200 where await sessions.record(environmentKey: env.displayName, key: loginItems) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let resumed = try #require(Workspace.previewDemo(environment: env, sessionStates: sessions).session(for: loginItems))
        await resumed.waitUntilReady()
        #expect(resumed.blueprintDescription == "Edited by hand")
    }
}

// MARK: - The migration's stages (findings 5, 8, 9, 12, 13, 14, 15, 17, 19)

@Suite("Migration stages after the release gate", .serialized)
@MainActor
struct StageTests {
    @Test("Dry run after create is refused and leaves the Blueprint deployable")
    func dryRunAfterCreate() async throws {
        let session = try await created(loginItems, in: Workspace.previewDemo())
        #expect(!session.canRunDryRun)
        await session.runDryRun()
        #expect(session.canDeploy)
        await session.deploy(try confirmation(session))
        guard case .deployed = session.state else { Issue.record("\(session.state)"); return }
    }

    @Test("Create waits for the saved state instead of racing it")
    func createWaitsForSavedState() async throws {
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: loginItems))
        session.dryRun = false
        await session.create() // straight away, while the saved state is still being read
        #expect(session.blueprintID != nil)
    }

    @Test("Reload passes the fetched profile to its open migration")
    func reloadUpdatesSessions() async throws {
        let server = DemoClassicServer()
        let env = environment(classicServer: server)
        let workspace = Workspace.previewDemo(environment: env)
        let session = try #require(workspace.session(for: loginItems))
        #expect(ClassicScopeService.hasTargets(session.profile.scope))
        // The profile changes in Jamf Pro (here: its scope).
        try await LiveClassicScopeWriter(client: MigrationEnvironment.demoClient(classicServer: server))
            .replaceScope(key: loginItems, body: ClassicScopeService.unscopedBody(platform: .macOS))
        workspace.reload()
        for _ in 0..<400 where ClassicScopeService.hasTargets(session.profile.scope) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!ClassicScopeService.hasTargets(session.profile.scope))
    }

    @Test("One platform's list failing still shows the other's profiles")
    func partialList() async throws {
        let client = MigrationEnvironment.demoClient()
        let env = MigrationEnvironment(displayName: "Demo", isDemo: true, environmentID: nil,
                                       classic: NoMobileList(inner: LiveClassicAPI(client: client)), platform: client)
        let workspace = Workspace(environment: env, history: HistoryLog(store: HistoryStore(fileURL: temporaryFile("h.json"))),
                                  scopeBackups: ScopeBackupStore(fileURL: temporaryFile("b.json")),
                                  sessionStates: SessionStateStore(fileURL: temporaryFile("s.json")))
        workspace.reload()
        for _ in 0..<400 where workspace.listPhase != .loaded { try await Task.sleep(for: .milliseconds(5)) }
        #expect(workspace.listPhase == .loaded)
        #expect(!workspace.summaries.isEmpty && workspace.summaries.allSatisfy { $0.platform == .macOS })
        #expect(workspace.listErrors[.mobile] != nil && workspace.listErrors[.macOS] == nil)
    }

    @Test("A cleanup that comes due during another action runs right after it")
    func queuedCleanup() async throws {
        let server = DemoClassicServer()
        let env = environment(classicServer: server)
        let session = try await created(loginItems, in: Workspace.previewDemo(environment: env))
        await session.deploy(try confirmation(session))
        session.unscopeAfterDeploy = true
        let verifying = Task { await session.verify() }
        while !session.isBusy { await Task.yield() }
        await session.reportBecameFinal(session.deviceReport) // while Verify Again runs
        await verifying.value
        guard case .unscoped = session.unscopeStatus else { Issue.record("\(session.unscopeStatus)"); return }
        #expect(server.scopeWrites.count == 1)
    }

    @Test("Refresh Status doesn't repeat the same deployment result in the history")
    func refreshRecordsOnce() async throws {
        let workspace = Workspace.previewDemo()
        let session = try await created(loginItems, in: workspace)
        await session.deploy(try confirmation(session))
        await session.recheckDeployment()
        await session.recheckDeployment()
        #expect(workspace.history.records.filter { $0.action == .deploymentResult }.count == 1)
    }

    @Test("While a deployment may still run, Verify Again doesn't make the Blueprint deployable")
    func noSecondDeployOnTopOfARunningOne() async throws {
        let server = DemoJamfPlatformServer(pollsToSucceed: 1_000)
        let pipeline = MigrationPipeline(
            classic: demoClassicAPI(), blueprints: JamfPlatform.Blueprints(client: server.client(log: nil)),
            watch: WatchPolicy(deployment: JamfPlatform.PollingPolicy(
                firstInterval: .milliseconds(1), longestInterval: .milliseconds(1), timeLimit: .milliseconds(20))),
            sleep: { _ in try await Task.sleep(for: .milliseconds(2)) })
        await pipeline.load(try await demoClassicAPI().profile(key: loginItems))
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [DemoFixtures.engineersPlatformGroupID],
                                     acknowledgedWarnings: false)
        let id = try await pipeline.create()
        _ = try await pipeline.verify()
        let deploy = DeployConfirmation(blueprintID: id, blueprintName: "x", groupNames: [], deviceCount: 0, confirmedAt: Date())
        guard case .timedOut = try await pipeline.deploy(confirmation: deploy) else { Issue.record("expected a time-out"); return }
        _ = try await pipeline.verify()
        guard case .deploying = await pipeline.state else { Issue.record("\(await pipeline.state)"); return }
        await #expect(throws: PipelineError.self) { try await pipeline.checkDeployable(confirmation: deploy) }
        #expect(server.deployCount == 1)
    }

    @Test("A group without a member count is shown as unknown, never as 0 devices")
    func unknownMemberCount() {
        let known = JamfPlatform.DeviceGroup(id: "a", name: "A", deviceType: .computer, groupType: .static, memberCount: 3)
        let unknown = JamfPlatform.DeviceGroup(id: "b", name: "B", deviceType: .computer, groupType: .smart, memberCount: nil)
        #expect(unknown.memberCountText == "unknown device count" && unknown.memberCountShort == "unknown")
        #expect(known.memberCountText == "3 devices")
        let item = DeployItem(blueprintID: "bp", blueprintName: "n", sourceName: "s", groups: [known, unknown], warnings: 0)
        #expect(item.deviceCount == 3 && item.hasUnknownDeviceCount)
        #expect(!DeployItem(blueprintID: "bp", blueprintName: "n", sourceName: "s", groups: [known], warnings: 0).hasUnknownDeviceCount)
    }

    @Test("History shows one word per result")
    func resultWords() {
        #expect([MigrationResult.success, .warning, .failure].map(\.title) == ["Success", "Warning", "Failed"])
    }
}

extension NetworkingTests {
    @Test("A dropped connection on the scope PUT is retried, as sending it twice changes nothing")
    func scopePutIsRetried() async throws {
        let base = URL(string: "https://eu.api.jamfcloud.com")!
        let puts = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, #"{"access_token":"t","expires_in":900,"token_type":"Bearer"}"#) }
            if request.method == "PUT", puts.next() == 1 { return .json(503, "{}") }
            return MockResponse(status: 201, headers: ["Content-Type": "application/xml"], body: Data("<p/>".utf8))
        }
        let recorder = RequestRecorder(session: MockURLProtocol.makeSession(), log: nil)
        let tokens = JamfPlatform.TokenProvider(tokenURL: base.appending(path: "auth/token"), method: .apiClient(clientID: "c"),
                                                secret: { "s" }, recorder: recorder)
        let client = try JamfPlatform.Client(baseURL: base, scope: .environment("0f0e0d0c-0b0a-4000-8000-00000000abcd"),
                                             tokens: tokens, recorder: recorder,
                                             permits: { RequestPolicy.isPermitted($0, classicWrites: .scopeOnly) },
                                             hints: RequestPolicy.hints(for:), sleep: { _ in })
        try await LiveClassicScopeWriter(client: client)
            .replaceScope(key: loginItems, body: ClassicScopeService.unscopedBody(platform: .macOS))
        #expect(puts.value == 2)
    }
}

// MARK: - Copying credentials and the batch (finding 18, missing tests)

@Suite("Copying JSON")
@MainActor
struct JSONCopyTests {
    @Test("JSON with credentials is copied concealed and for this Mac only; other JSON plainly")
    func secretsConcealed() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("p2b-gate-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        JSONTextView.copy(#"{"Password":"x"}"#, containsSecrets: true, to: pasteboard)
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        JSONTextView.copy("{}", containsSecrets: false, to: pasteboard)
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) != true)
        #expect(pasteboard.string(forType: .string) == "{}")
    }
}

@Suite("Batch migration", .serialized)
@MainActor
struct BatchTests {
    @Test("A name clash on one item doesn't stop the others; each confirmation deploys its own session")
    func batchRunsEveryItem() async throws {
        let workspace = Workspace.previewDemo()
        let first = try #require(workspace.session(for: loginItems))
        let clash = try #require(workspace.session(for: ProfileKey(platform: .macOS, id: 102)))
        let other = try #require(workspace.session(for: ProfileKey(platform: .mobile, id: 201)))
        for session in [first, clash, other] {
            await session.waitUntilReady()
            session.acknowledgedWarnings = true
            #expect(!session.selectedGroupIDs.isEmpty)
        }
        clash.blueprintName = first.blueprintName // the second create finds a Blueprint with this name

        await BatchMigration.run([first, clash, other], dryRun: false)
        #expect(first.blueprintID != nil && other.blueprintID != nil)
        #expect(clash.blueprintID == nil && clash.duplicates != nil)

        await BatchMigration.deploy([try confirmation(other)], sessions: [first, clash, other])
        guard case .deployed = other.state else { Issue.record("\(other.state)"); return }
        if case .deployed = first.state { Issue.record("only the confirmed Blueprint deploys") }
    }
}
