import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

// The deploy confirmation follows the verified Blueprint, unmapped classic
// groups keep their warning, Stop on a wait reads as a plain sentence and
// sends nothing again, and every failed deploy says in the history whether
// it may have started.

private let loginItems = ProfileKey(platform: .macOS, id: 101) // Engineering Macs only
private let securityBaseline = ProfileKey(platform: .macOS, id: 102) // Engineering Macs + an ambiguous Design Macs
private let financeProfile = ProfileKey(platform: .macOS, id: 103) // Finance Macs, no platform group of that name

private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "p2b-round2-\(UUID().uuidString)-\(name)")
}

/// The demo Platform server with one kind of request answered differently,
/// once, while armed: to make a wait, a refusal or a failure happen on cue.
private final class OnceServer: DemoServer, @unchecked Sendable {
    let inner: DemoJamfPlatformServer
    private let lock = NSLock()
    private var rule: (match: @Sendable (DemoRequest) -> Bool, response: DemoResponse, forward: Bool)?

    init(_ inner: DemoJamfPlatformServer) { self.inner = inner }

    /// - Parameter forward: the server still gets the request (it happened),
    ///   and only the answer is replaced (it was lost or failed).
    func arm(_ response: DemoResponse, forward: Bool = false, when match: @escaping @Sendable (DemoRequest) -> Bool) {
        lock.withLock { rule = (match, response, forward) }
    }

    func respond(to request: DemoRequest) -> DemoResponse {
        let rule: (match: @Sendable (DemoRequest) -> Bool, response: DemoResponse, forward: Bool)? = lock.withLock {
            guard let rule = self.rule, rule.match(request) else { return nil }
            self.rule = nil
            return rule
        }
        guard let rule else { return inner.respond(to: request) }
        if rule.forward { _ = inner.respond(to: request) }
        return rule.response
    }

    static let wait = DemoResponse(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "30"],
                                   body: Data(#"{"httpStatus":429,"errors":[{"code":"TOO_MANY_REQUESTS","description":"slow down"}]}"#.utf8))

    static func status(_ status: Int) -> DemoResponse {
        DemoResponse(status: status, body: Data(#"{"httpStatus":\#(status),"errors":[{"code":"X","description":"no"}]}"#.utf8))
    }

    static func isDeploy(_ request: DemoRequest) -> Bool {
        request.method == "POST" && request.pathSegments.last == "deploy"
    }

    static func isCreate(_ request: DemoRequest) -> Bool {
        request.method == "POST" && request.pathSegments.last == "blueprints"
    }

    static func isBlueprintRead(_ request: DemoRequest) -> Bool {
        request.method == "GET" && request.pathSegments.count >= 4 && request.pathSegments[2] == "blueprints"
            && request.pathSegments.last != "report"
    }

    static func isClassicPut(_ request: DemoRequest) -> Bool {
        request.method == "PUT" && request.pathSegments.contains("proclassic")
    }
}

@MainActor
private struct Rig {
    let server: DemoJamfPlatformServer
    let classic = DemoClassicServer()
    let once: OnceServer
    let waits = RequestWaits()
    let environment: MigrationEnvironment
    let workspace: Workspace

    init(server: DemoJamfPlatformServer = DemoJamfPlatformServer()) {
        self.server = server
        once = OnceServer(server)
        let session = DemoNetwork(servers: [DemoSamples.platformHost: once]).session
        environment = .demo(server: server, classicServer: classic, session: session, waits: waits)
        workspace = Workspace.previewDemo(environment: environment)
    }

    /// A session with its Blueprint created and verified.
    func verified(_ key: ProfileKey = loginItems) async throws -> MigrationSession {
        let session = try #require(workspace.session(for: key))
        await session.waitUntilReady()
        await session.create()
        try #require(session.lastError == nil, "\(String(describing: session.lastError))")
        try #require(session.fidelity?.passed == true)
        return session
    }

    /// Ends the first wait before a retry as soon as it starts, as Stop does.
    func stopFirstWait() -> Task<Void, Never> {
        let waits = waits
        return Task { @MainActor in
            for _ in 0..<1_000 where waits.current.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            waits.cancelAll()
        }
    }

    var lastDeployLine: MigrationRecord? {
        workspace.history.records.last { $0.action == .deploymentResult }
    }
}

@MainActor
private func confirmation(_ session: MigrationSession) throws -> DeployConfirmation {
    let item = try #require(session.deployItem)
    return DeployConfirmation(blueprintID: item.blueprintID, blueprintName: item.blueprintName,
                              groupNames: item.groups.map(\.name), deviceCount: item.deviceCount, confirmedAt: Date())
}

@Suite("Deploy confirmation follows the verified Blueprint", .serialized)
@MainActor
struct DeployTargetTests {
    @Test("The confirmation lists the verified scope, also when the draft selection is emptied")
    func confirmationFromVerifiedScope() async throws {
        let rig = Rig()
        let session = try await rig.verified()
        session.toggleGroup(DemoFixtures.engineersPlatformGroupID)
        #expect(session.selectedGroups.isEmpty)
        let item = try #require(session.deployItem)
        #expect(item.groups.map(\.id) == [DemoFixtures.engineersPlatformGroupID])
        #expect(item.deviceCount > 0 && item.canBeConfirmed)
        #expect(session.canDeploy)
        await session.deploy(try confirmation(session))
        let confirmed = try #require(rig.workspace.history.records.last { $0.action == .deploy })
        #expect(confirmed.message.contains("Engineering Macs"))
        #expect(rig.server.deployCount == 1)
    }

    @Test("A failed reload of the groups keeps the last good list and shows the error")
    func failedReloadKeepsGroups() async throws {
        let rig = Rig()
        let session = try await rig.verified()
        let before = rig.workspace.groups
        rig.once.arm(OnceServer.status(403)) { $0.method == "GET" && $0.pathSegments.contains { $0.hasSuffix("groups") } }
        await rig.workspace.reloadGroups()
        #expect(rig.workspace.groups == before)
        #expect(rig.workspace.groupsError != nil)
        #expect(session.deployItem?.groups.map(\.id) == [DemoFixtures.engineersPlatformGroupID])
        #expect(session.canDeploy)
    }

    @Test("An ID the group list doesn't have is shown as such and blocks Deploy")
    func unresolvedBlocks() {
        let known = DemoFixtures.platformGroups.first { $0.deviceType == .computer }!
        let resolved = MigrationSession.resolve([known.id.uppercased(), "gone-group"], in: DemoFixtures.platformGroups, platform: .macOS)
        #expect(resolved.groups.map(\.id) == [known.id], "IDs compare without case")
        #expect(resolved.unresolved == ["gone-group"])
        let item = DeployItem(blueprintID: "b", blueprintName: "n", sourceName: "s", groups: resolved.groups,
                              unresolvedGroupIDs: resolved.unresolved, warnings: 0)
        #expect(!item.canBeConfirmed)
        // A mobile group never resolves for a macOS profile.
        let mobile = MigrationSession.resolve([DemoFixtures.fieldiPhonesPlatformGroupID], in: DemoFixtures.platformGroups, platform: .macOS)
        #expect(mobile.groups.isEmpty && mobile.unresolved.count == 1)
    }
}

@Suite("Unmapped classic groups keep their warning", .serialized)
@MainActor
struct UnmappedGroupTests {
    /// Login Items' profile, scoped to Engineering Macs (exact match) and Finance Macs (none).
    private func mixedProfile() throws -> ClassicProfile {
        let xml = try #require(DemoFixtures.profilesByKey[loginItems])
        let engineering = "<computer_group><id>3</id><name>Engineering Macs</name></computer_group>"
        try #require(xml.contains(engineering))
        let mixed = xml.replacingOccurrences(of: engineering,
                                             with: engineering + "<computer_group><id>11</id><name>Finance Macs</name></computer_group>")
        return try ClassicXMLParser.parseProfile(Data(mixed.utf8), platform: .macOS)
    }

    @Test("One matched and one unmatched group: needs attention until the second is mapped")
    func matchedAndUnmatched() throws {
        let profile = try mixedProfile()
        let workspace = Workspace.previewDemo()
        let report = EligibilityChecker.check(profile, platformGroups: DemoFixtures.platformGroups)
        let session = MigrationSession(profile: profile, report: report, workspace: workspace)
        #expect(session.selectedGroupIDs == [DemoFixtures.engineersPlatformGroupID], "the exact match is selected")
        #expect(session.effectiveReport.status == .needsAttention)
        #expect(session.effectiveReport.has(.unmatchedGroups))
        #expect(session.needsAcknowledgement)
        let finance = try #require(report.scopeMapping.first { $0.classicGroup.name == "Finance Macs" })
        let other = try #require(DemoFixtures.platformGroups.first {
            $0.deviceType == .computer && $0.id != DemoFixtures.engineersPlatformGroupID
        })
        session.pick(other.id, for: finance)
        #expect(session.effectiveReport.status == .ready)
    }

    @Test("An ambiguous name stays a warning until one group is picked for it")
    func ambiguousUntilPicked() async throws {
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: securityBaseline))
        await session.waitUntilReady()
        #expect(session.effectiveReport.has(.ambiguousGroups))
        let design = try #require(session.report.scopeMapping.first { $0.isAmbiguous })
        session.pick(design.exactMatches[0].id, for: design)
        #expect(!session.effectiveReport.has(.ambiguousGroups))
        #expect(session.effectiveReport.status == .ready)
    }
}

@Suite("Hand-picked groups after a relaunch, and per classic group", .serialized)
@MainActor
struct PickRelaunchTests {
    @Test("A saved pick comes back after a relaunch and keeps the automatic cleanup armed")
    func pickSurvivesRelaunch() async throws {
        let environment = MigrationEnvironment.demo()
        let backups = ScopeBackupStore(fileURL: temporaryFile("b.json"))
        let states = SessionStateStore(fileURL: temporaryFile("s.json"))
        let first = Workspace.previewDemo(environment: environment, scopeBackups: backups, sessionStates: states)
        let session = try #require(first.session(for: financeProfile))
        await session.waitUntilReady()
        let entry = try #require(session.report.scopeMapping.first)
        session.pick(DemoFixtures.engineersPlatformGroupID, for: entry)
        session.unscopeAfterDeploy = true
        await session.create()
        try #require(session.blueprintID != nil)
        try await Task.sleep(for: .milliseconds(50)) // the record is saved in the background

        let relaunched = Workspace.previewDemo(environment: environment, scopeBackups: backups, sessionStates: states)
        let resumed = try #require(relaunched.session(for: financeProfile))
        await resumed.waitUntilReady()
        #expect(resumed.blueprintID == session.blueprintID)
        #expect(resumed.groupPicks == [entry.id: DemoFixtures.engineersPlatformGroupID])
        #expect(resumed.uncoveredClassicTargets.isEmpty)
        #expect(resumed.autoUnscopeArmed)
    }

    @Test("A pick for one classic group doesn't cover another")
    func pickPerGroup() {
        var scope = ClassicScope()
        scope.deviceGroups = [ClassicReference(id: 21, name: "Alpha Macs"), ClassicReference(id: 22, name: "Beta Macs")]
        let coverage = ScopeCoverage(platform: .macOS, platformGroups: DemoFixtures.platformGroups,
                                     blueprintGroupIDs: [DemoFixtures.engineersPlatformGroupID],
                                     picks: ["21": DemoFixtures.engineersPlatformGroupID])
        #expect(coverage.uncovered(in: scope) == ["group “Beta Macs”"])
    }

    @Test("A pick whose group is gone from the list doesn't count; IDs compare without case")
    func pickMustExist() {
        var scope = ClassicScope()
        scope.deviceGroups = [ClassicReference(id: 21, name: "Alpha Macs")]
        let gone = ScopeCoverage(platform: .macOS, platformGroups: DemoFixtures.platformGroups,
                                 blueprintGroupIDs: ["deleted-group"], picks: ["21": "deleted-group"])
        #expect(gone.uncovered(in: scope) == ["group “Alpha Macs”"])
        let mobile = ScopeCoverage(platform: .macOS, platformGroups: DemoFixtures.platformGroups,
                                   blueprintGroupIDs: [DemoFixtures.fieldiPhonesPlatformGroupID],
                                   picks: ["21": DemoFixtures.fieldiPhonesPlatformGroupID])
        #expect(mobile.uncovered(in: scope) == ["group “Alpha Macs”"], "a mobile group never covers a Mac group")
        let upper = ScopeCoverage(platform: .macOS, platformGroups: DemoFixtures.platformGroups,
                                  blueprintGroupIDs: [DemoFixtures.engineersPlatformGroupID.uppercased()],
                                  picks: ["21": DemoFixtures.engineersPlatformGroupID])
        #expect(upper.uncovered(in: scope).isEmpty)
    }
}

@Suite("Stop and failed deploys", .serialized)
@MainActor
struct StopAndFailureTests {
    @Test("Stop during a wait on the deploy POST: nothing sent again, a plain sentence, deployable again")
    func stopDeploy() async throws {
        let rig = Rig()
        let session = try await rig.verified()
        rig.once.arm(OnceServer.wait, when: OnceServer.isDeploy)
        let stopper = rig.stopFirstWait()
        await session.deploy(try confirmation(session))
        await stopper.value
        #expect(rig.server.deployCount == 0)
        #expect(session.lastError?.title.hasPrefix(StoppedWaiting.message) == true, "\(String(describing: session.lastError))")
        #expect(rig.lastDeployLine?.result == .failure)
        #expect(rig.lastDeployLine?.message.contains("nothing was sent again") == true)
        #expect(session.canDeploy, "nothing started, so Deploy can be tried again")
    }

    @Test("Stop during a wait on the create POST: nothing created, a plain sentence")
    func stopCreate() async throws {
        let rig = Rig()
        let session = try #require(rig.workspace.session(for: loginItems))
        await session.waitUntilReady()
        rig.once.arm(OnceServer.wait, when: OnceServer.isCreate)
        let stopper = rig.stopFirstWait()
        await session.create()
        await stopper.value
        #expect(rig.server.createCount == 0)
        #expect(session.blueprintID == nil)
        #expect(session.lastError?.title == StoppedWaiting.message)
    }

    @Test("Stop during a wait on the classic scope PUT: may have been made, check the profile, Restore offered")
    func stopClassicPut() async throws {
        let rig = Rig()
        let backups = ScopeBackupStore(fileURL: temporaryFile("b.json"))
        rig.once.arm(OnceServer.wait, when: OnceServer.isClassicPut)
        let stopper = rig.stopFirstWait()
        var thrown: (any Error)?
        do {
            _ = try await ClassicScopeService.unscope(key: loginItems, blueprintID: nil, environment: rig.environment, backups: backups)
        } catch {
            thrown = error
        }
        await stopper.value
        #expect(thrown.map { ErrorReport($0).title } == ClassicScopeService.stoppedUnscopeMessage)
        #expect(ClassicScopeService.stoppedUnscopeMessage.contains("may already have been made"))
        #expect(!ClassicScopeService.stoppedUnscopeMessage.contains("nothing was sent"))
        let backup = await backups.latest(key: loginItems, environment: rig.environment)
        #expect(backup?.writeState == .pending, "kept for Restore")
    }

    @Test("Stop during the automatic or manual unscope in a migration: Restore is available")
    func stopUnscopeInSession() async throws {
        let rig = Rig()
        let session = try await rig.verified()
        await session.deploy(try confirmation(session))
        try #require(session.canUnscopeNow, "\(String(describing: session.outcome))")
        rig.once.arm(OnceServer.wait, when: OnceServer.isClassicPut)
        let stopper = rig.stopFirstWait()
        await session.unscopeClassic()
        await stopper.value
        guard case let .failed(report) = session.unscopeStatus else { Issue.record("\(session.unscopeStatus)"); return }
        #expect(report.title == ClassicScopeService.stoppedUnscopeMessage)
        #expect(session.canRestoreScope)
    }

    @Test("Stop during a wait on Restore: may already be restored, check the profile, Restore still available")
    func stopRestore() async throws {
        let rig = Rig()
        let session = try await rig.verified()
        await session.deploy(try confirmation(session))
        await session.unscopeClassic()
        try #require(session.canRestoreScope, "\(session.unscopeStatus)")
        rig.once.arm(OnceServer.wait, when: OnceServer.isClassicPut)
        let stopper = rig.stopFirstWait()
        await session.restoreClassicScope()
        await stopper.value
        guard case let .failed(report) = session.unscopeStatus else { Issue.record("\(session.unscopeStatus)"); return }
        #expect(report.title == ClassicScopeService.stoppedRestoreMessage)
        #expect(session.canRestoreScope, "Restore stays available")
        #expect(session.scopeBackup != nil)
    }

    @Test("A deploy POST answered 503 leaves a history line saying it may have started")
    func deployServerError() async throws {
        let rig = Rig()
        let session = try await rig.verified()
        rig.once.arm(OnceServer.status(503), when: OnceServer.isDeploy)
        await session.deploy(try confirmation(session))
        #expect(rig.lastDeployLine?.result == .failure)
        #expect(rig.lastDeployLine?.message.contains("may or may not have started") == true, "\(String(describing: rig.lastDeployLine))")
        #expect(!session.canDeploy, "it may have started: verify again first")
    }

    @Test("A deploy that may have started and is still running: Verify Again follows it instead of offering Deploy")
    func verifyFollowsRunningDeployment() async throws {
        let rig = Rig(server: DemoJamfPlatformServer(pollsToSucceed: 3))
        let session = try await rig.verified()
        // The deploy reaches Jamf, but its answer is a 503.
        rig.once.arm(OnceServer.status(503), forward: true, when: OnceServer.isDeploy)
        await session.deploy(try confirmation(session))
        #expect(rig.server.deployCount == 1)
        #expect(session.deployMayHaveStarted)
        #expect(!session.canDeploy)
        await session.verify()
        guard case .deployed = session.state else { Issue.record("\(session.state)"); return }
        #expect(!session.canDeploy)
        #expect(rig.server.deployCount == 1, "never deployed a second time")
        #expect(rig.workspace.history.records.contains { $0.message.contains("following it instead of offering Deploy again") })
    }

    @Test("A deploy that may have started and failed: Verify Again says so before Deploy is offered")
    func verifyReportsFailedDeployment() async throws {
        let rig = Rig(server: DemoJamfPlatformServer(pollsToSucceed: 0, failDeployments: true))
        let session = try await rig.verified()
        rig.once.arm(OnceServer.status(503), forward: true, when: OnceServer.isDeploy)
        await session.deploy(try confirmation(session))
        #expect(!session.canDeploy)
        await session.verify()
        let notice = try #require(session.deploymentNotice, "\(session.state)")
        #expect(notice.contains("has failed"))
        #expect(session.canDeploy, "offered again, after the notice")
        #expect(rig.workspace.history.records.last { $0.action == .deploymentResult }?.message == notice)
        #expect(rig.server.deployCount == 1)
    }

    @Test("A deploy POST refused with 400 leaves a history line saying it didn't start")
    func deployRefused() async throws {
        let rig = Rig()
        let session = try await rig.verified()
        rig.once.arm(OnceServer.status(400), when: OnceServer.isDeploy)
        await session.deploy(try confirmation(session))
        #expect(rig.lastDeployLine?.message.contains("didn’t start") == true, "\(String(describing: rig.lastDeployLine))")
        #expect(session.canDeploy)
    }

    @Test("The Blueprint read before the deploy fails (404): nothing was sent, still deployable")
    func readStageFails() async throws {
        let rig = Rig()
        let session = try await rig.verified()
        rig.once.arm(OnceServer.status(404), when: OnceServer.isBlueprintRead)
        await session.deploy(try confirmation(session))
        #expect(rig.server.deployCount == 0)
        #expect(session.lastError?.title.contains("couldn’t be read before deploying") == true, "\(String(describing: session.lastError))")
        #expect(session.lastError?.title.contains("Nothing was sent") == true)
        #expect(rig.lastDeployLine?.message.contains("Nothing was sent") == true)
        #expect(session.canDeploy)
    }

    @Test("Stop while reading the Blueprint before the deploy: nothing was sent")
    func readStageStopped() async throws {
        let rig = Rig()
        let session = try await rig.verified()
        rig.once.arm(OnceServer.wait, when: OnceServer.isBlueprintRead)
        let stopper = rig.stopFirstWait()
        await session.deploy(try confirmation(session))
        await stopper.value
        #expect(rig.server.deployCount == 0)
        #expect(session.lastError?.title.hasPrefix(StoppedWaiting.message) == true, "\(String(describing: session.lastError))")
        #expect(session.canDeploy)
    }
}

@Suite("A real tenant's workspace", .serialized)
@MainActor
struct TenantWorkspaceTests {
    @Test("Has retry waits, and its classic scope switch is read live")
    func wiring() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "p2b-tenant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(store: TenantStore(fileURL: folder.appending(path: "tenants.json")),
                             secrets: InMemorySecretStore(),
                             session: DemoNetwork(servers: [:]).session,
                             history: HistoryStore(fileURL: folder.appending(path: "history.json")),
                             scopeBackups: ScopeBackupStore(fileURL: folder.appending(path: "b.json")),
                             sessionStates: SessionStateStore(fileURL: folder.appending(path: "s.json")),
                             demoMode: false)
        var tenant = Tenant(name: "Example", region: .eu, environmentID: "0f0e0d0c-0b0a-4000-8000-00000000abcd",
                            clientID: "client", allowClassicScopeChanges: true)
        try model.connections.save(tenant, secrets: [.main: "secret"])
        model.makeCurrent(tenant.id)
        let environment = try model.activeWorkspace().environment
        #expect(!environment.isDemo)
        #expect(environment.waits != nil)
        #expect(environment.classicScopeWriter != nil)
        tenant.allowClassicScopeChanges = false
        try model.connections.save(tenant, secrets: [:])
        #expect(environment.classicScopeWriter == nil, "the old workspace sees the switch turned off")
    }
}

@Suite("Reload Profiles while work runs", .serialized)
@MainActor
struct ReloadBlockTests {
    @Test("Unavailable while a migration step is busy or a batch runs")
    func blocked() async throws {
        let rig = Rig()
        let session = try #require(rig.workspace.session(for: loginItems))
        await session.waitUntilReady()
        #expect(!rig.workspace.isReloadBlocked)
        // Hold the create in a wait, so the step stays busy.
        rig.once.arm(OnceServer.wait, when: OnceServer.isCreate)
        let create = Task { await session.create() }
        for _ in 0..<1_000 where rig.waits.current.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.isBusy)
        #expect(rig.workspace.isReloadBlocked)
        let before = rig.workspace.detailsLoaded
        rig.workspace.reload()
        #expect(rig.workspace.listPhase == .loaded && rig.workspace.detailsLoaded == before, "reload refused")
        rig.waits.cancelAll()
        await create.value
        #expect(!rig.workspace.isReloadBlocked)

        rig.workspace.batchRunning = true
        #expect(rig.workspace.isReloadBlocked)
        rig.workspace.batchRunning = false
        #expect(!rig.workspace.isReloadBlocked)
    }
}
