import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

// Four problems the release check found, one test each, so they stay fixed.

/// Contoso's "Engineering Macs".
private let engineersGroup = DemoFixtures.platformGroups[2]

// MARK: 1. A sandbox run keeps a tenant's scope backups and sessions in its temporary folder

@Suite("Sandbox run: a tenant workspace's files", .serialized)
@MainActor
struct SandboxWorkspaceFilesTests {
    @Test("A sandbox run's workspace for a real tenant uses the sandbox's files, never Application Support")
    func sandboxWorkspaceStaysInTheTemporaryFolder() async throws {
        let suite = "be.jordythery.profile2blueprint.tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let demo = DemoMode(key: AppModel.demoModeKey, defaults: defaults,
                            arguments: [DemoMode.sandboxArgument, "YES", DemoMode.launchArgument, "NO"])
        #expect(demo.isSandbox && !demo.isOn)
        let model = AppModel.sandbox(demo: demo)
        let tenant = Tenant(name: "Sandbox tenant", region: .eu, environmentID: UUID().uuidString, clientID: "client")
        try model.connections.save(tenant, secrets: [.main: "secret"])
        model.makeCurrent(tenant.id)

        let workspace = try model.activeWorkspace()
        #expect(!workspace.environment.isDemo)
        let folder = demo.scratchDirectory.standardizedFileURL.path
        let backups = await workspace.scopeBackups.fileURL, sessions = await workspace.sessionStates.fileURL
        #expect(backups.standardizedFileURL.path.hasPrefix(folder), "\(backups.path)")
        #expect(sessions.standardizedFileURL.path.hasPrefix(folder), "\(sessions.path)")
        #expect(backups != (await ScopeBackupStore.appDefault().fileURL))
        #expect(sessions != (await SessionStateStore.appDefault().fileURL))
    }

    @Test("Outside the sandbox a tenant workspace still uses the real files")
    func normalRunUsesTheRealFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "p2b-findings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(store: TenantStore(fileURL: folder.appending(path: "tenants.json")),
                             secrets: InMemorySecretStore(),
                             history: HistoryStore(fileURL: folder.appending(path: "history.json")),
                             demoMode: false)
        let tenant = Tenant(name: "Tenant", region: .eu, environmentID: UUID().uuidString, clientID: "client")
        try model.connections.save(tenant, secrets: [.main: "secret"])
        model.makeCurrent(tenant.id)
        let workspace = try model.activeWorkspace()
        #expect(await workspace.scopeBackups.fileURL == ScopeBackupStore.appDefault().fileURL)
        #expect(await workspace.sessionStates.fileURL == SessionStateStore.appDefault().fileURL)
    }
}

// MARK: 2. A refused deploy leaves no "confirmed" history line

@Suite("Deploy history", .serialized)
@MainActor
struct DeployHistoryTests {
    @Test("A deploy the pipeline refuses records nothing; an accepted one records the confirmation")
    func refusedDeployLeavesNoConfirmedLine() async throws {
        let workspace = Workspace.previewDemo()
        let session = try #require(workspace.session(for: ProfileKey(platform: .macOS, id: 101)))
        session.dryRun = false
        await session.create()
        let blueprintID = try #require(session.blueprintID)
        #expect(session.fidelity?.passed == true)

        // A confirmation for another Blueprint: refused before anything is sent.
        await session.deploy(DeployConfirmation(blueprintID: "some-other-blueprint", blueprintName: "n",
                                                groupNames: ["Engineering Macs"], deviceCount: 12, confirmedAt: Date()))
        #expect(session.lastError != nil)
        #expect(session.outcome == nil)
        #expect(!workspace.history.records.contains { $0.action == .deploy }, "no “confirmed” line for a refused deploy")

        await session.deploy(DeployConfirmation(blueprintID: blueprintID, blueprintName: "n",
                                                groupNames: ["Engineering Macs"], deviceCount: 12, confirmedAt: Date()))
        #expect(workspace.history.records.filter { $0.action == .deploy && $0.result == .success }.count == 1)
        #expect(workspace.history.records.contains { $0.action == .deploymentResult })
    }

    @Test("checkDeployable refuses before verification and for another Blueprint, and sends nothing")
    func checkDeployable() async throws {
        let server = DemoJamfPlatformServer()
        let pipeline = MigrationPipeline(classic: demoClassicAPI(), blueprints: JamfPlatform.Blueprints(client: server.client(log: nil)))
        let confirmation = { (id: String) in
            DeployConfirmation(blueprintID: id, blueprintName: "n", groupNames: [], deviceCount: 0, confirmedAt: Date())
        }
        _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 101))
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineersGroup.id], acknowledgedWarnings: false)
        let id = try await pipeline.create()
        await #expect(throws: PipelineError.self) { try await pipeline.checkDeployable(confirmation: confirmation(id)) }
        _ = try await pipeline.verify()
        await #expect(throws: PipelineError.self) { try await pipeline.checkDeployable(confirmation: confirmation("other")) }
        #expect(try await pipeline.checkDeployable(confirmation: confirmation(id)) == id)
        #expect(server.deployCount == 0)
    }
}

// MARK: 3. The stages run in order

@Suite("Pipeline stage order")
struct PipelineStageOrderTests {
    private func createdPipeline() async throws -> (MigrationPipeline, String) {
        let pipeline = MigrationPipeline(classic: demoClassicAPI(),
                                         blueprints: JamfPlatform.Blueprints(client: DemoJamfPlatformServer().client(log: nil)))
        _ = try await pipeline.fetch(key: ProfileKey(platform: .macOS, id: 101))
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        _ = try await pipeline.build(name: "x", description: nil, deviceGroupIDs: [engineersGroup.id], acknowledgedWarnings: false)
        return (pipeline, try await pipeline.create())
    }

    @Test("After create, validating or building again is refused and the Blueprint is kept")
    func noGoingBackAfterCreate() async throws {
        let (pipeline, id) = try await createdPipeline()
        await #expect(throws: PipelineError.self) { _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups) }
        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.build(name: "y", description: nil, deviceGroupIDs: [engineersGroup.id], acknowledgedWarnings: false)
        }
        #expect(await pipeline.state == .created(blueprintID: id))
        #expect(await pipeline.blueprintID == id)

        _ = try await pipeline.verify()
        await #expect(throws: PipelineError.self) { _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups) }
        guard case .verified = await pipeline.state else { Issue.record("not verified: \(await pipeline.state)"); return }
    }

    @Test("Build needs a validation first; loading the profile again starts over")
    func buildNeedsValidationAndLoadStartsOver() async throws {
        let (pipeline, _) = try await createdPipeline()
        let profile = try #require(await pipeline.profile)
        await pipeline.load(profile)
        #expect(await pipeline.state == .fetched)
        #expect(await pipeline.blueprintID == nil)
        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.build(name: "y", description: nil, deviceGroupIDs: [engineersGroup.id], acknowledgedWarnings: false)
        }
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups)
        _ = try await pipeline.validate(platformGroups: DemoFixtures.platformGroups) // validating again before create is fine
        _ = try await pipeline.build(name: "y", description: nil, deviceGroupIDs: [engineersGroup.id], acknowledgedWarnings: false)
        #expect(await pipeline.state == .built)
    }
}

// MARK: 4. Restore is offered only for a backup Restore accepts

@Suite("Scope backup lookup")
struct ScopeBackupLookupTests {
    private func environment(_ name: String, id: String?, demo: Bool) -> MigrationEnvironment {
        MigrationEnvironment(displayName: name, isDemo: demo, environmentID: id,
                             classic: demoClassicAPI(), platform: DemoJamfPlatformServer().client(log: nil))
    }

    @Test("The backup the session offers is always one Restore accepts")
    func latestMatchesRestore() async throws {
        let store = ScopeBackupStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "p2b-lookup-\(UUID().uuidString).json"))
        let key = ProfileKey(platform: .macOS, id: 102)
        let backups = [
            (MigrationEnvironment.demoDisplayName, nil as String?),
            (MigrationEnvironment.earlierDemoDisplayName, nil),
            ("Lab", "env-a"),
            ("Lab", nil),
            ("Lab", "env-b"),
        ].map { name, id in
            ScopeBackup(environmentName: name, environmentID: id, platform: .macOS, profileID: key.id,
                        profileName: "p", blueprintID: nil, scopeXML: "<scope/>")
        }
        for backup in backups { try await store.save(backup) }

        let environments = [
            environment(MigrationEnvironment.demoDisplayName, id: nil, demo: true),
            environment("Lab", id: "env-a", demo: false),
            environment("Lab", id: nil, demo: false),
            environment(MigrationEnvironment.earlierDemoDisplayName, id: nil, demo: false),
            environment("Other", id: "env-c", demo: false),
        ]
        for environment in environments {
            let offered = await store.latest(key: key, environment: environment)
            #expect(offered?.id == backups.last { $0.belongs(to: environment) }?.id, "\(environment.displayName)")
            if let offered { #expect(offered.belongs(to: environment)) }
        }
        // The case the earlier lookup got wrong: a real tenant without an
        // Environment ID named like the earlier demo matched that demo's backup,
        // which Restore then refused.
        #expect(await store.latest(key: key, environment: environment(MigrationEnvironment.earlierDemoDisplayName, id: nil, demo: false)) == nil)
    }
}
