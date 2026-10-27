import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

private func temporaryStore() -> SessionStateStore {
    SessionStateStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "p2b-sessions-\(UUID().uuidString).json"))
}

/// Polls a main-actor condition until it holds or the timeout passes.
@MainActor
private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw PipelineError(message: "Timed out waiting for condition") }
        try await Task.sleep(for: .milliseconds(25))
    }
}

@Suite("Session state store")
struct SessionStateStoreTests {
    private func record(profileID: Int = 101, blueprintID: String = "bp-1") -> PersistedMigration {
        PersistedMigration(environmentKey: "env", platform: .macOS, profileID: profileID, blueprintID: blueprintID,
                           blueprintName: "Name", selectedGroupIDs: ["g1"], unscopeAfterDeploy: true)
    }

    @Test("Round-trips, replaces per profile, removes, and caps")
    func roundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "p2b-sessions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SessionStateStore(fileURL: url, limit: 3)

        await store.save(record())
        await store.save(record(blueprintID: "bp-2"))
        let loaded = await SessionStateStore(fileURL: url).record(environmentKey: "env", key: ProfileKey(platform: .macOS, id: 101))
        #expect(loaded?.blueprintID == "bp-2", "same profile replaces, persisted to disk")
        #expect(loaded?.unscopeAfterDeploy == true)
        #expect(loaded?.selectedGroupIDs == ["g1"])

        for id in 102...105 { await store.save(record(profileID: id)) }
        #expect(await store.record(environmentKey: "env", key: ProfileKey(platform: .macOS, id: 101)) == nil, "oldest dropped at the cap")

        await store.remove(environmentKey: "env", key: ProfileKey(platform: .macOS, id: 105))
        #expect(await store.record(environmentKey: "env", key: ProfileKey(platform: .macOS, id: 105)) == nil)
    }
}

@Suite("Session restore", .serialized)
@MainActor
struct SessionRestoreTests {

    @Test("A created blueprint re-attaches after a relaunch and is deployable again")
    func restoreAfterRelaunch() async throws {
        let environment = MigrationEnvironment.demo()
        let states = temporaryStore()

        // First launch: create, don't deploy.
        let first = Workspace.previewDemo(environment: environment, sessionStates: states)
        let session1 = try #require(first.session(for: ProfileKey(platform: .macOS, id: 101)))
        session1.dryRun = false
        await session1.create()
        let blueprintID = try #require(session1.blueprintID)
        #expect(session1.fidelity?.passed == true)
        session1.unscopeAfterDeploy = true

        // The record is saved by a background task; wait for the flag to land.
        var saved: PersistedMigration?
        for _ in 0..<200 where saved?.unscopeAfterDeploy != true {
            saved = await states.record(environmentKey: MigrationEnvironment.demoDisplayName, key: ProfileKey(platform: .macOS, id: 101))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(saved?.unscopeAfterDeploy == true)

        // Second launch: same environment and store, fresh workspace.
        let second = Workspace.previewDemo(environment: environment, sessionStates: states)
        let session2 = try #require(second.session(for: ProfileKey(platform: .macOS, id: 101)))
        try await waitUntil { session2.blueprintID != nil && session2.fidelity != nil && !session2.isBusy }

        #expect(session2.blueprintID == blueprintID)
        #expect(session2.unscopeAfterDeploy, "opt-in restored")
        #expect(session2.fidelity?.passed == true, "restored session re-verified")
        #expect(session2.canDeploy)
        #expect(session2.lastError == nil)
    }

    @Test("A restored session whose blueprint is already deployed resumes at the deployed stage")
    func restoreDeployed() async throws {
        let environment = MigrationEnvironment.demo()
        let states = temporaryStore()

        let first = Workspace.previewDemo(environment: environment, sessionStates: states)
        let session1 = try #require(first.session(for: ProfileKey(platform: .macOS, id: 101)))
        session1.dryRun = false
        await session1.create()
        let blueprintID = try #require(session1.blueprintID)
        await session1.deploy(DeployConfirmation(blueprintID: blueprintID, blueprintName: "n",
                                                 groupNames: ["Engineering Macs"], deviceCount: 12, confirmedAt: Date()))
        guard case .deployed = session1.state else { Issue.record("\(session1.state)"); return }

        let second = Workspace.previewDemo(environment: environment, sessionStates: states)
        let session2 = try #require(second.session(for: ProfileKey(platform: .macOS, id: 101)))
        try await waitUntil {
            if case .deployed = session2.state { return !session2.isBusy }
            return false
        }
        #expect(session2.deviceReport?.pending == 0)
        #expect(!session2.canDeploy, "already deployed; offer refresh instead")
    }

    @Test("A stale record (blueprint deleted on the server) is cleared with an explanation")
    func staleRecordCleared() async throws {
        let states = temporaryStore()
        await states.save(PersistedMigration(environmentKey: MigrationEnvironment.demoDisplayName, platform: .macOS, profileID: 101,
                                             blueprintID: "deleted-on-server", blueprintName: "Gone",
                                             selectedGroupIDs: [DemoFixtures.engineersPlatformGroupID],
                                             unscopeAfterDeploy: false))

        // Fresh demo environment: the blueprint does not exist there.
        let workspace = Workspace.previewDemo(environment: .demo(), sessionStates: states)
        let session = try #require(workspace.session(for: ProfileKey(platform: .macOS, id: 101)))
        try await waitUntil { session.lastError != nil && !session.isBusy }

        #expect(session.blueprintID == nil)
        #expect(session.lastError?.title.contains("no longer exists") == true)
        #expect(await states.record(environmentKey: MigrationEnvironment.demoDisplayName, key: ProfileKey(platform: .macOS, id: 101)) == nil, "record removed")
        #expect(session.canCreate == false || session.dryRun, "back to the normal create flow")
    }
}

@Suite("Effective eligibility")
@MainActor
struct EffectiveEligibilityTests {

    @Test("Picking a group resolves an unmatched-scope warning to Ready, no acknowledgement needed")
    func unmatchedResolvedBySelection() throws {
        // Fixture 103 is Needs attention solely because no platform group matches.
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: ProfileKey(platform: .macOS, id: 103)))
        #expect(session.report.status == .needsAttention)
        #expect(session.selectedGroupIDs.isEmpty)
        #expect(session.effectiveReport.status == .needsAttention)

        session.toggleGroup(DemoFixtures.engineersPlatformGroupID)
        #expect(session.effectiveReport.status == .ready)
        #expect(!session.needsAcknowledgement)
        session.dryRun = false
        #expect(session.canCreate, "selection replaces the acknowledgement for pick-a-group warnings")
        #expect(session.report.status == .needsAttention, "base report unchanged")
    }

    @Test("Information-loss warnings still require acknowledgement after picking a group")
    func lossWarningsRemain() throws {
        // Fixture 105 has All computers, exclusions and limitations.
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: ProfileKey(platform: .macOS, id: 105)))
        session.toggleGroup(DemoFixtures.engineersPlatformGroupID)

        let kinds = Set(session.effectiveReport.reasons.map(\.kind))
        #expect(!kinds.contains(.noMappedGroup))
        #expect(kinds.contains(.exclusions) && kinds.contains(.limitations) && kinds.contains(.allDevices))
        #expect(session.effectiveReport.status == .needsAttention)
        #expect(session.needsAcknowledgement)
    }

    @Test("Create goes through on a selection-resolved profile and the pipeline accepts it")
    func createWithoutAcknowledgement() async throws {
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: ProfileKey(platform: .macOS, id: 103)))
        session.toggleGroup(DemoFixtures.engineersPlatformGroupID)
        session.dryRun = false
        await session.create()
        #expect(session.lastError == nil)
        #expect(session.blueprintID != nil)
        #expect(session.fidelity?.passed == true)
    }
}

/// A fake server returning scripted device reports, then repeating the last one,
/// reached through JTKit's client.
nonisolated final class ScriptedReports: @unchecked Sendable {
    private final class Script: @unchecked Sendable {
        let lock = NSLock()
        var reports: [JamfPlatform.BlueprintReport]
        var count = 0
        init(_ reports: [JamfPlatform.BlueprintReport]) { self.reports = reports }

        func next() -> JamfPlatform.BlueprintReport {
            lock.withLock {
                count += 1
                return reports.count > 1 ? reports.removeFirst() : reports[0]
            }
        }
    }

    private let script: Script
    let server: MockServer

    var calls: Int { script.lock.withLock { script.count } }

    init(_ reports: [JamfPlatform.BlueprintReport]) {
        let script = Script(reports)
        self.script = script
        server = MockServer { request in
            guard request.path.hasSuffix("/report") else { return .json(404, "{}") }
            let report = script.next()
            return .json(200, #"{"succeeded":\#(report.succeeded),"failed":\#(report.failed),"pending":\#(report.pending)}"#)
        }
    }

    func blueprints() throws -> JamfPlatform.Blueprints {
        JamfPlatform.Blueprints(client: try JamfPlatform.Client(
            baseURL: URL(string: "https://us.api.jamfcloud.com")!, scope: .environment(DemoSamples.platformEnvironmentID),
            tokens: NoSignIn(), recorder: RequestRecorder(session: server.session, log: nil)))
    }
}

private struct NoSignIn: BearerTokenSource {
    func token() async throws -> String { "token" }
    func forgetToken() async {}
}

@Suite("Report monitor")
struct ReportMonitorTests {
    private func pipeline(_ api: ScriptedReports, timeout: Duration = .seconds(60)) throws -> MigrationPipeline {
        MigrationPipeline(
            classic: demoClassicAPI(),
            blueprints: try api.blueprints(),
            watch: WatchPolicy(report: JamfPlatform.PollingPolicy(
                firstInterval: .milliseconds(1), growth: 1, longestInterval: .milliseconds(1), timeLimit: timeout)),
            sleep: { _ in await Task.yield() }
        )
    }

    @Test("The device report is checked every 20 s for up to 30 minutes (the app's setting on JTKit's waiting)")
    func reportWatchSetting() {
        let policy = WatchPolicy().report
        #expect((1...5).map(policy.interval(afterCheck:)) == Array(repeating: .seconds(20), count: 5))
        #expect(policy.timeLimit == .seconds(1_800))
        #expect(WatchPolicy().deployment == .standard, "the deployment itself follows JTKit's standard")
    }

    @Test("Polls until no device is pending and reports every update")
    func pollsUntilClean() async throws {
        let api = ScriptedReports([
            JamfPlatform.BlueprintReport(succeeded: 0, failed: 0, pending: 3),
            JamfPlatform.BlueprintReport(succeeded: 2, failed: 0, pending: 1),
            JamfPlatform.BlueprintReport(succeeded: 3, failed: 0, pending: 0),
        ])
        let updates = Counter()
        let final = try await pipeline(api).monitorReport(id: "bp") { _ in _ = updates.next() }
        #expect(final == JamfPlatform.BlueprintReport(succeeded: 3, failed: 0, pending: 0))
        #expect(api.calls == 3)
        #expect(updates.value == 3)
    }

    @Test("Stops with failures present once nothing is pending (caller gates cleanup)")
    func stopsWithFailures() async throws {
        let api = ScriptedReports([
            JamfPlatform.BlueprintReport(succeeded: 1, failed: 0, pending: 2),
            JamfPlatform.BlueprintReport(succeeded: 2, failed: 1, pending: 0),
        ])
        let final = try await pipeline(api).monitorReport(id: "bp")
        #expect(final?.failed == 1 && final?.pending == 0)
        #expect(ClassicScopeService.deploymentAllowsUnscope(.succeeded(final)) == false)
    }

    @Test("Gives up at the timeout and returns the last report")
    func timesOut() async throws {
        let api = ScriptedReports([JamfPlatform.BlueprintReport(succeeded: 1, failed: 0, pending: 9)])
        // Real 5 ms sleeps against a 1 s deadline: several polls, then a guaranteed stop.
        // The margin absorbs scheduling stalls when the whole suite runs in parallel.
        let pipeline = MigrationPipeline(
            classic: demoClassicAPI(),
            blueprints: try api.blueprints(),
            watch: WatchPolicy(report: JamfPlatform.PollingPolicy(
                firstInterval: .milliseconds(5), growth: 1, longestInterval: .milliseconds(5), timeLimit: .seconds(1))),
            sleep: { try await Task.sleep(for: $0) }
        )
        let final = try await pipeline.monitorReport(id: "bp")
        #expect(final?.pending == 9)
        #expect(api.calls >= 2, "kept polling until the deadline")
    }
}
