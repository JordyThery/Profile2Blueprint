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

    /// Offline demo mode runs everything against bundled fixtures; no tenant is contacted.
    /// It is a setting of its own, never a tenant in the list.
    var isDemoMode: Bool {
        didSet {
            UserDefaults.standard.set(isDemoMode, forKey: Self.demoModeKey)
            workspace = nil
            workspaceGeneration += 1
            activity.app("Offline demo mode turned \(isDemoMode ? "on" : "off").")
        }
    }

    let history: HistoryLog
    let activity: ActivityLog
    let updates: UpdateChecker
    /// Cache only; views observe `isDemoMode` / `currentTenantID`, which drive rebuilds.
    @ObservationIgnored private var workspace: Workspace?

    @ObservationIgnored private let store: TenantStore
    @ObservationIgnored private let secrets: RecordingSecretStore
    private let session: URLSession
    private static let demoModeKey = "demoMode"

    init(
        store: TenantStore = .appDefault(),
        secrets: any SecretStore = KeychainSecretStore.profile2Blueprint(),
        session: URLSession = .shared,
        history: HistoryStore = .appDefault(),
        demoMode: Bool? = nil
    ) {
        self.store = store
        let recording = RecordingSecretStore(secrets)
        self.secrets = recording
        self.session = session
        // JTKit's in-memory log (Window › Activity Log). The activity.json of
        // earlier versions stays on disk untouched and is no longer read.
        let activityLog = ActivityLog()
        self.activity = activityLog
        self.history = HistoryLog(store: history, activity: activityLog)
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
        isDemoMode = demoMode ?? UserDefaults.standard.bool(forKey: Self.demoModeKey)
        store.didSaveTenants = { [weak self] old, new in
            self?.tenantsSaved(old: old, new: new)
        }
    }

    // MARK: - Workspace

    /// The workspace for demo mode or the current tenant, created on demand.
    /// Throws when the current tenant can't be used (missing or invalid settings).
    func activeWorkspace() throws -> Workspace {
        if let workspace { return workspace }
        let environment: MigrationEnvironment
        if isDemoMode {
            environment = .demo(log: activity)
        } else {
            guard let tenant = currentTenant else {
                throw APIError.invalidConfiguration("Choose a current tenant, or turn on offline demo mode.")
            }
            let client = try makeClient(for: tenant)
            environment = MigrationEnvironment(
                displayName: tenant.displayName,
                isDemo: false,
                environmentID: tenant.normalizedEnvironmentID,
                naming: tenant.naming,
                descriptionTemplate: tenant.descriptionTemplate,
                jamfProLinks: tenant.jamfProLinks,
                classic: LiveClassicAPI(client: client),
                platform: client,
                classicScopeWriter: tenant.allowClassicScopeChanges ? LiveClassicScopeWriter(client: client) : nil
            )
        }
        // Called from view bodies; defer the log write so it doesn't mutate state mid-update.
        let activity = self.activity
        let name = environment.displayName
        Task { activity.app("Opened workspace for \(name).", environment: name) }
        let created = Workspace(environment: environment, history: history)
        workspace = created
        return created
    }

    /// Drops the cached workspace so the next access rebuilds it with fresh settings.
    private func invalidateWorkspace(for tenantID: UUID?) {
        guard !isDemoMode else { return }
        if tenantID == nil || tenantID == currentTenantID {
            workspace = nil
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
            persistenceError = "Could not save the current tenant: \(error.localizedDescription)"
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
        for tenant in new {
            guard let before = previous[tenant.id] else {
                activity.app("Added tenant “\(tenant.displayName)”.")
                continue
            }
            if before.allowClassicScopeChanges != tenant.allowClassicScopeChanges {
                activity.app("Classic scope changes \(tenant.allowClassicScopeChanges ? "ENABLED" : "disabled") for “\(tenant.displayName)”.",
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
    /// credentials without writing them to the Keychain.
    func makeClient(for tenant: Tenant, secretOverride: String? = nil) throws -> JamfPlatform.Client {
        if let issue = tenant.validationIssues.first {
            throw APIError.invalidConfiguration(issue)
        }
        guard let baseURL = tenant.baseURL else {
            throw APIError.invalidConfiguration("Invalid host.")
        }
        let recorder = RequestRecorder(session: session, log: activity,
                                       service: ConnectionService.jamfPlatform.displayName,
                                       connection: tenant.displayName)
        let tokens: JamfTokenProvider
        do {
            tokens = try JamfTokenProvider(connection: tenant.connection, secret: secret(for: tenant, override: secretOverride),
                                           recorder: recorder)
        } catch let error as HTTPError {
            throw JamfPlatformError(error)
        }
        let classicWrites: ClassicWritePolicy = tenant.allowClassicScopeChanges ? .scopeOnly : .denied
        return try JamfPlatform.Client(
            baseURL: baseURL,
            scope: .environment(tenant.normalizedEnvironmentID),
            tokens: tokens,
            recorder: recorder,
            permits: { RequestPolicy.isPermitted($0, classicWrites: classicWrites) },
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
