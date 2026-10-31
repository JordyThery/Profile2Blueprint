import Foundation
import JTKit
import Observation

/// App-wide state: saved tenants, the current tenant, and connection checks.
@Observable
final class AppModel {
    /// The saved tenants, edited in Settings › Connections (JTKit's shared list).
    let connections: ConnectionStore<Tenant>
    private(set) var currentTenantID: UUID?
    /// Set when persisting tenants or secrets fails, shown as an alert.
    var persistenceError: String?

    /// JTKit's demo mode: Contoso's sample tenant, answered inside the app; no
    /// tenant is contacted. A setting of its own, never a tenant in the list.
    /// Saved under `demoMode`.
    let demo: DemoMode

    /// Demo mode on or off, through JTKit's switch.
    var isDemoMode: Bool {
        get { demo.isOn }
        set { demo.requestSwitch(to: newValue) }
    }

    let history: HistoryLog
    /// Demo mode's own history, kept in `demoFiles`, never in the real file.
    let demoHistory: HistoryLog
    let activity: ActivityLog
    let updates: UpdateChecker
    /// Cache only; views observe `isDemoMode` / `currentTenantID`, which drive rebuilds.
    @ObservationIgnored private var workspace: Workspace?

    @ObservationIgnored private let store: TenantStore
    @ObservationIgnored private let secrets: RecordingSecretStore
    @ObservationIgnored private let demoFiles: DemoFiles
    /// Where tenant workspaces keep scope backups and sessions, passed in or
    /// the real files in Application Support (opened on first use). One store
    /// per file for every workspace, so none overwrites another's records.
    @ObservationIgnored private let givenScopeBackups: ScopeBackupStore?
    @ObservationIgnored private let givenSessionStates: SessionStateStore?
    @ObservationIgnored private var openedScopeBackups: ScopeBackupStore?
    @ObservationIgnored private var openedSessionStates: SessionStateStore?
    /// Demo mode's stores, in `demoFiles`, opened once.
    @ObservationIgnored private let demoScopeBackups: ScopeBackupStore
    @ObservationIgnored private let demoSessionStates: SessionStateStore
    /// Each tenant's "Allow classic scope changes" switch as it's saved now,
    /// read by its client and workspace at every scope change.
    @ObservationIgnored private var scopeSwitches: [UUID: ClassicWriteSwitch] = [:]
    /// The network for real tenants, also while demo mode is on (Test Connection).
    private let session: URLSession
    /// Demo mode as the workspace was last built for, to notice a switch.
    @ObservationIgnored private var workspaceIsDemo: Bool
    static let demoModeKey = "demoMode"

    /// - Parameters:
    ///   - demo: the app passes its saved demo mode (`forLaunch()`).
    ///   - demoMode: for tests and previews, demo mode on or off for this
    ///     model only, never saved. Without either, demo mode is off and not saved.
    ///   - demoFiles: where demo mode keeps its files; `demo`'s temporary folder by default.
    ///   - scopeBackups, sessionStates: a tenant workspace's files; the real
    ///     ones in Application Support when nil.
    init(
        store: TenantStore = .appDefault(),
        secrets: any SecretStore = KeychainSecretStore.profile2Blueprint(),
        session: URLSession = .shared,
        history: HistoryStore = .appDefault(),
        scopeBackups: ScopeBackupStore? = nil,
        sessionStates: SessionStateStore? = nil,
        demo: DemoMode? = nil,
        demoFiles: DemoFiles? = nil,
        demoMode: Bool? = nil
    ) {
        givenScopeBackups = scopeBackups
        givenSessionStates = sessionStates
        let demo = demo ?? DemoMode(key: Self.demoModeKey,
                                    arguments: [DemoMode.launchArgument, demoMode == true ? "YES" : "NO"])
        self.demo = demo
        workspaceIsDemo = demo.isOn
        let demoFiles = demoFiles ?? DemoFiles(folder: demo.scratchDirectory)
        self.store = store
        self.demoFiles = demoFiles
        demoScopeBackups = demoFiles.scopeBackups
        demoSessionStates = demoFiles.sessionStates
        let recording = RecordingSecretStore(secrets)
        self.secrets = recording
        self.session = session
        // JTKit's in-memory log (Window › Activity Log). The app doesn't read
        // or change activity.json, which may still be on disk.
        let activityLog = ActivityLog()
        self.activity = activityLog
        self.history = HistoryLog(store: history, activity: activityLog)
        demoHistory = HistoryLog(store: demoFiles.history, activity: activityLog)
        updates = UpdateChecker(configuration: .profile2Blueprint) { line in
            // JTKit reports plain lines; failures keep their warning level in Activity.
            activityLog.app(line, level: line.hasPrefix("Update check failed") ? .warning : .info)
        }
        let connections = ConnectionStore<Tenant>(
            storage: store,
            secrets: [.main: SecretLocation(store: recording)],
            log: { activityLog.app($0, level: .warning) }
        )
        self.connections = connections
        currentTenantID = store.currentTenantID.flatMap { id in
            connections.record(id: id) != nil ? id : nil
        }
        persistenceError = connections.problem?.localizedDescription
        store.didSaveTenants = { [weak self] old, new in
            self?.tenantsSaved(old: old, new: new)
        }
        for log in [self.history, demoHistory] {
            log.onSaveFailure = { [weak self] message in self?.persistenceError = message }
        }
        observeDemoSwitch()
        Task { [history] in
            if let problem = await history.problem { self.persistenceError = problem }
        }
    }

    /// The model for this launch: the saved tenants and demo mode, or, for a
    /// sandbox run (`-JTKitSandbox YES`, UI tests), tenants, secrets and
    /// history in demo mode's temporary folder and in memory.
    static func forLaunch() -> AppModel {
        let demo = DemoMode(key: demoModeKey)
        guard demo.isSandbox else { return AppModel(demo: demo) }
        return sandbox(demo: demo)
    }

    /// A sandbox run's model: tenants, history, scope backups and sessions in
    /// `demo`'s temporary folder, secrets in memory, a network that reaches nothing.
    static func sandbox(demo: DemoMode) -> AppModel {
        let folder = demo.scratchDirectory
        return AppModel(store: TenantStore(fileURL: folder.appending(path: "sandbox-tenants.json")),
                        secrets: SandboxSecretStore(),
                        session: DemoNetwork(servers: [:]).session,
                        history: HistoryStore(fileURL: folder.appending(path: "sandbox-history.json")),
                        scopeBackups: ScopeBackupStore(fileURL: folder.appending(path: "sandbox-scope-backups.json")),
                        sessionStates: SessionStateStore(fileURL: folder.appending(path: "sandbox-sessions.json")),
                        demo: demo)
    }

    // MARK: - Demo mode

    /// Follows JTKit's switch (the picker, the Connection menu, "Try Demo Mode").
    private func observeDemoSwitch() {
        withObservationTracking { _ = demo.isOn } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.demoSwitched() }
        }
    }

    private func demoSwitched() {
        observeDemoSwitch()
        guard demo.isOn != workspaceIsDemo else { return }
        workspaceIsDemo = demo.isOn
        // A view may already have built the new mode's workspace; keep that one.
        if workspace?.environment.isDemo != demo.isOn { closeWorkspace() }
        workspaceGeneration += 1
        activity.app("\(DemoMode.title) turned \(demo.isOn ? "on" : "off").")
    }

    // MARK: - Workspace

    /// The workspace for demo mode or the current tenant, created on demand.
    /// Throws when the current tenant can't be used (missing or invalid settings).
    func activeWorkspace() throws -> Workspace {
        // A workspace built before the switch was noticed is never used.
        if let workspace, workspace.environment.isDemo == isDemoMode { return workspace }
        let environment: MigrationEnvironment
        if isDemoMode {
            // JTKit's demo connection and network, never a saved tenant or the Keychain.
            let source = demo.jamfPlatform()
            environment = .demo(log: activity, server: demo.jamfPlatformServer, session: source.session)
        } else {
            guard let tenant = currentTenant else {
                throw APIError.invalidConfiguration("Choose a current tenant, or turn on \(DemoMode.title).")
            }
            let scopeChanges = scopeSwitch(for: tenant)
            let client = try makeClient(for: tenant, scopeChanges: scopeChanges)
            environment = MigrationEnvironment(
                displayName: tenant.displayName,
                isDemo: false,
                environmentID: tenant.normalizedEnvironmentID,
                naming: tenant.naming,
                descriptionTemplate: tenant.descriptionTemplate,
                jamfProLinks: tenant.jamfProLinks,
                classic: LiveClassicAPI(client: client),
                platform: client,
                classicScopeWriter: LiveClassicScopeWriter(client: client),
                scopeChanges: scopeChanges
            )
        }
        // Called from view bodies; defer the log write so it doesn't mutate state mid-update.
        let activity = self.activity
        let name = environment.displayName
        Task { activity.app("Opened workspace for \(name).", environment: name) }
        let created = isDemoMode
            ? Workspace(environment: environment, history: demoHistory,
                        scopeBackups: demoScopeBackups, sessionStates: demoSessionStates)
            : Workspace(environment: environment, history: history,
                        scopeBackups: tenantScopeBackups, sessionStates: tenantSessionStates)
        workspace = created
        reportStoreProblems(scopeBackups: created.scopeBackups, sessionStates: created.sessionStates)
        return created
    }

    private var tenantScopeBackups: ScopeBackupStore {
        if let store = givenScopeBackups ?? openedScopeBackups { return store }
        let opened = ScopeBackupStore.appDefault()
        openedScopeBackups = opened
        return opened
    }

    private var tenantSessionStates: SessionStateStore {
        if let store = givenSessionStates ?? openedSessionStates { return store }
        let opened = SessionStateStore.appDefault()
        openedSessionStates = opened
        return opened
    }

    /// Shows a scope backup or session file that couldn't be read (nothing is
    /// saved to it, and no scope change runs without a backup).
    private func reportStoreProblems(scopeBackups: ScopeBackupStore, sessionStates: SessionStateStore) {
        Task {
            let problems = [await scopeBackups.problem, await sessionStates.problem].compactMap { $0 }
            if !problems.isEmpty { persistenceError = problems.joined(separator: "\n\n") }
        }
    }

    /// The tenant's switch, set to its saved "Allow classic scope changes".
    private func scopeSwitch(for tenant: Tenant) -> ClassicWriteSwitch {
        let existing = scopeSwitches[tenant.id] ?? ClassicWriteSwitch(tenant.allowClassicScopeChanges)
        existing.isOn = tenant.allowClassicScopeChanges
        scopeSwitches[tenant.id] = existing
        return existing
    }

    /// Stops the replaced workspace's loading, deployment watches and pending cleanups.
    private func closeWorkspace() {
        workspace?.close()
        workspace = nil
    }

    /// The history the History page shows: demo mode's own while it's on.
    var currentHistory: HistoryLog { isDemoMode ? demoHistory : history }

    /// Drops the cached workspace so the next access rebuilds it with fresh settings.
    private func invalidateWorkspace(for tenantID: UUID?) {
        guard !isDemoMode else { return }
        if tenantID == nil || tenantID == currentTenantID {
            closeWorkspace()
            workspaceGeneration += 1
        }
    }

    /// Bumped whenever the active workspace is replaced; views key on it.
    private(set) var workspaceGeneration = 0

    var tenants: [Tenant] { connections.records }

    var currentTenant: Tenant? {
        tenants.first { $0.id == currentTenantID }
    }

    func tenant(id: UUID) -> Tenant? {
        connections.record(id: id)
    }

    // MARK: - Tenant management

    /// Makes a saved tenant the current one, from the toolbar picker or
    /// "Use This Connection" in Settings.
    func makeCurrent(_ id: UUID?) {
        setCurrent(id, among: tenants)
    }

    private func setCurrent(_ id: UUID?, among tenants: [Tenant]) {
        guard id != currentTenantID, id == nil || tenants.contains(where: { $0.id == id }) else { return }
        do {
            try store.saveCurrentTenantID(id)
        } catch {
            persistenceError = "The current tenant couldn’t be saved: \(error.localizedDescription)"
            return
        }
        currentTenantID = id
        if let tenant = tenants.first(where: { $0.id == id }) {
            activity.app("Current tenant is now “\(tenant.displayName)”.")
        }
        invalidateWorkspace(for: nil)
    }

    /// Called after Settings › Connections wrote the tenants: logs what changed,
    /// rebuilds the workspace when the current tenant changed, and keeps a
    /// current tenant, as before (the first one added; the next one after a delete).
    private func tenantsSaved(old: [Tenant], new: [Tenant]) {
        let newSecrets = secrets.takeWrittenAccounts()
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remaining = Set(new.map(\.id))
        // A switch turned off (or a tenant deleted) stops scope changes at once,
        // also in migrations that are still running.
        for tenant in new { scopeSwitches[tenant.id]?.isOn = tenant.allowClassicScopeChanges }
        for removed in old where !remaining.contains(removed.id) { scopeSwitches[removed.id]?.isOn = false }
        for tenant in new {
            guard let before = previous[tenant.id] else {
                activity.app("Added tenant “\(tenant.displayName)”.")
                continue
            }
            if before.allowClassicScopeChanges != tenant.allowClassicScopeChanges {
                activity.app("Classic scope changes turned \(tenant.allowClassicScopeChanges ? "on" : "off") for “\(tenant.displayName)”.",
                             environment: tenant.displayName, level: tenant.allowClassicScopeChanges ? .warning : .info, category: .classicWrite)
            }
            let hasNewSecret = newSecrets.contains(tenant.id.uuidString)
            if hasNewSecret {
                activity.app("Stored a new client secret in the Keychain for “\(tenant.displayName)” (value not logged).", category: .auth)
            }
            if before != tenant || hasNewSecret {
                activity.app("Saved settings for “\(tenant.displayName)” (\(tenant.host)).")
                invalidateWorkspace(for: tenant.id)
            }
        }
        for removed in old where !remaining.contains(removed.id) {
            activity.app("Deleted tenant “\(removed.displayName)” and its Keychain secret from this Mac.")
            invalidateWorkspace(for: removed.id)
        }
        if let current = currentTenantID, !remaining.contains(current) {
            setCurrent(new.first?.id, among: new)
        } else if currentTenantID == nil, let added = new.first(where: { previous[$0.id] == nil }) {
            setCurrent(added.id, among: new)
        }
    }

    // MARK: - Networking

    /// Builds JTKit's client for a tenant, with the app's list of allowed
    /// requests. `secretOverride` lets the Connect screen test unsaved
    /// credentials without writing them to the Keychain. `scopeChanges` is
    /// the switch the allow-list reads at every request; by default a fixed
    /// one from `tenant`.
    func makeClient(for tenant: Tenant, secretOverride: String? = nil,
                    scopeChanges: ClassicWriteSwitch? = nil) throws -> JamfPlatform.Client {
        if let issue = tenant.validationIssues.first {
            throw APIError.invalidConfiguration(issue)
        }
        guard let baseURL = tenant.baseURL else {
            throw APIError.invalidConfiguration("Invalid host.")
        }
        let recorder = RequestRecorder(session: session, log: activity,
                                       service: ConnectionService.jamfPlatform.displayName,
                                       connection: tenant.displayName)
        let tokens: JamfPlatform.TokenProvider
        do {
            tokens = try JamfPlatform.TokenProvider(connection: tenant.connection, secret: secret(for: tenant, override: secretOverride),
                                           recorder: recorder)
        } catch let error as HTTPError {
            throw JamfPlatform.APIError(error)
        }
        let scopeChanges = scopeChanges ?? ClassicWriteSwitch(tenant.allowClassicScopeChanges)
        return try JamfPlatform.Client(
            baseURL: baseURL,
            scope: .environment(tenant.normalizedEnvironmentID),
            tokens: tokens,
            recorder: recorder,
            permits: { RequestPolicy.isPermitted($0, classicWrites: scopeChanges.policy) },
            hints: RequestPolicy.hints(for:)
        )
    }

    /// The tenant's client secret, read when signing in: a typed one first,
    /// else the one in the Keychain.
    private func secret(for tenant: Tenant, override: String?) -> @Sendable () throws -> String {
        let secrets = self.secrets
        let account = tenant.id.uuidString
        let override = override.flatMap { $0.isEmpty ? nil : $0 }
        return {
            if let override { return override }
            guard let stored = secrets.secret(for: account), !stored.isEmpty else {
                throw APIError.missingSecret
            }
            return stored
        }
    }

    /// The read permissions Test Connection checks. Write permissions can't be
    /// checked without writing, so they stay in the footer.
    static let readChecks: [JamfPlatform.PermissionCheck] = [
        .deviceGroupsRead,
        .blueprintsRead,
        JamfPlatform.PermissionCheck("Read classic configuration profiles", path: "proclassic/osxconfigurationprofiles",
                                     query: [], permission: "configuration-profiles:read",
                                     jamfProPrivilege: ProfilePlatform.macOS.readPrivilege.rawValue),
    ]

    /// Test Connection in Settings › Connections: signs in, checks that the
    /// lists the app reads can be read, and counts the platform device groups,
    /// with the values in the editor, saved or not.
    func testConnection(_ tenant: Tenant, secretOverride: String? = nil) async throws -> String {
        activity.app("Testing connection to “\(tenant.displayName)”.", environment: tenant.displayName)
        let client: JamfPlatform.Client
        do {
            client = try makeClient(for: tenant, secretOverride: secretOverride)
            try await client.signIn()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConnectionTestError(report: ErrorReport(error))
        }
        if let problem = JamfPlatform.PermissionProblem(await client.checkPermissions(Self.readChecks)) { throw problem }
        do {
            let groups = try await client.deviceGroups()
            let computers = groups.count(where: { $0.deviceType == .computer })
            let mobile = groups.count(where: { $0.deviceType == .mobile })
            return "Connected · \(groups.count) device group\(groups.count == 1 ? "" : "s") (\(computers) computer, \(mobile) mobile)"
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConnectionTestError(report: ErrorReport(error))
        }
    }

    /// Load Environments in Settings › Connections: the environments the
    /// editor's integration can see. No Environment ID is needed for this.
    func environments(for tenant: Tenant, secretOverride: String? = nil) async throws -> [JamfPlatform.Environment] {
        let recorder = RequestRecorder(session: session, log: activity,
                                       service: ConnectionService.jamfPlatform.displayName,
                                       connection: tenant.displayName)
        return try await JamfPlatform.environments(
            for: tenant.connection, secret: secret(for: tenant, override: secretOverride), recorder: recorder,
            permits: { RequestPolicy.isPermitted($0) })
    }
}

extension UpdateConfiguration {
    /// Where Profile2Blueprint's releases live. The saved-settings keys keep JTKit's
    /// defaults, which are the names this app has always used.
    static let profile2Blueprint = UpdateConfiguration(
        owner: "JordyThery",
        repository: "Profile2Blueprint",
        appName: "Profile2Blueprint"
    )
}
