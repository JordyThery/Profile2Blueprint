import Foundation
import Observation

/// Result of the most recent "Test connection" for a tenant.
enum ConnectionState: Equatable {
    case idle
    case testing
    case succeeded(groups: [PlatformGroup], at: Date)
    case failed(ErrorReport)
}

/// App-wide state: saved tenants, the current tenant, and connection checks.
@Observable
final class AppModel {
    private(set) var tenants: [Tenant] = []
    private(set) var currentTenantID: UUID?
    private(set) var connectionStates: [UUID: ConnectionState] = [:]
    /// Set when persisting tenants or secrets fails, shown as an alert.
    var persistenceError: String?

    /// Offline demo mode runs everything against bundled fixtures; no tenant is contacted.
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
    /// Cache only; views observe `isDemoMode` / `currentTenantID`, which drive rebuilds.
    @ObservationIgnored private var workspace: Workspace?

    private let store: TenantStore
    private let secrets: any SecretStore
    private let session: URLSession
    private static let demoModeKey = "demoMode"

    init(
        store: TenantStore = .appDefault(),
        secrets: any SecretStore = KeychainStore(),
        session: URLSession = .shared,
        history: HistoryStore = .appDefault(),
        activity: ActivityStore = .appDefault(),
        demoMode: Bool? = nil
    ) {
        self.store = store
        self.secrets = secrets
        self.session = session
        let activityLog = ActivityLog(store: activity)
        self.activity = activityLog
        self.history = HistoryLog(store: history, activity: activityLog)
        let configuration = store.load()
        tenants = configuration.tenants
        currentTenantID = configuration.currentTenantID.flatMap { id in
            configuration.tenants.contains { $0.id == id } ? id : nil
        }
        isDemoMode = demoMode ?? UserDefaults.standard.bool(forKey: Self.demoModeKey)
    }

    // MARK: - Workspace

    /// The workspace for demo mode or the current tenant, created on demand.
    /// Throws when the current tenant can't be used (missing or invalid settings).
    func activeWorkspace() throws -> Workspace {
        if let workspace { return workspace }
        let environment: MigrationEnvironment
        if isDemoMode {
            environment = .demo()
        } else {
            guard let tenant = currentTenant else {
                throw APIError.invalidConfiguration("Choose a current tenant, or turn on offline demo mode.")
            }
            let client = try makeClient(for: tenant)
            environment = MigrationEnvironment(
                displayName: tenant.displayName,
                isDemo: false,
                environmentID: tenant.normalizedEnvironmentID,
                classic: LiveClassicAPI(client: client),
                groups: LiveDeviceGroupsAPI(client: client),
                blueprints: LiveBlueprintsAPI(client: client),
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

    var currentTenant: Tenant? {
        tenants.first { $0.id == currentTenantID }
    }

    func tenant(id: UUID) -> Tenant? {
        tenants.first { $0.id == id }
    }

    func connectionState(for id: UUID) -> ConnectionState {
        connectionStates[id] ?? .idle
    }

    // MARK: - Tenant management

    @discardableResult
    func addTenant() -> Tenant {
        let tenant = Tenant(name: "New tenant")
        tenants.append(tenant)
        activity.app("Added tenant “\(tenant.displayName)”.")
        if currentTenantID == nil { currentTenantID = tenant.id }
        persist()
        return tenant
    }

    /// Saves tenant settings. A non-empty `secret` replaces the stored Keychain secret.
    func save(_ tenant: Tenant, secret: String?) {
        let previous = self.tenant(id: tenant.id)
        if previous?.allowClassicScopeChanges != tenant.allowClassicScopeChanges, previous != nil || tenant.allowClassicScopeChanges {
            activity.app("Classic scope changes \(tenant.allowClassicScopeChanges ? "ENABLED" : "disabled") for “\(tenant.displayName)”.",
                         environment: tenant.displayName, level: tenant.allowClassicScopeChanges ? .warning : .info, category: .classicWrite)
        }
        if let index = tenants.firstIndex(where: { $0.id == tenant.id }) {
            tenants[index] = tenant
        } else {
            tenants.append(tenant)
        }
        if let secret, !secret.isEmpty {
            do {
                try secrets.setSecret(secret, for: tenant.id.uuidString)
                activity.app("Stored a new client secret in the Keychain for “\(tenant.displayName)” (value not logged).", category: .auth)
            } catch {
                persistenceError = error.localizedDescription
            }
        }
        connectionStates[tenant.id] = .idle
        activity.app("Saved settings for “\(tenant.displayName)” (\(tenant.host)).")
        invalidateWorkspace(for: tenant.id)
        persist()
    }

    func delete(_ id: UUID) {
        if let removed = tenant(id: id) {
            activity.app("Deleted tenant “\(removed.displayName)” and its Keychain secret from this Mac.")
        }
        tenants.removeAll { $0.id == id }
        connectionStates[id] = nil
        do {
            try secrets.deleteSecret(for: id.uuidString)
        } catch {
            persistenceError = error.localizedDescription
        }
        invalidateWorkspace(for: id)
        if currentTenantID == id { currentTenantID = tenants.first?.id }
        persist()
    }

    func makeCurrent(_ id: UUID) {
        guard tenants.contains(where: { $0.id == id }) else { return }
        currentTenantID = id
        activity.app("Current tenant is now “\(currentTenant?.displayName ?? "?")”.")
        invalidateWorkspace(for: nil)
        persist()
    }

    func hasStoredSecret(for id: UUID) -> Bool {
        ((try? secrets.secret(for: id.uuidString)) ?? nil)?.isEmpty == false
    }

    private func persist() {
        do {
            try store.save(TenantConfiguration(tenants: tenants, currentTenantID: currentTenantID))
        } catch {
            persistenceError = "Could not save tenants: \(error.localizedDescription)"
        }
    }

    // MARK: - Networking

    /// Builds an authenticated client for a tenant. `secretOverride` lets the
    /// Connect screen test unsaved credentials without writing them to the Keychain.
    func makeClient(for tenant: Tenant, secretOverride: String? = nil) throws -> HTTPClient {
        if let issue = tenant.validationIssues.first {
            throw APIError.invalidConfiguration(issue)
        }
        guard let baseURL = tenant.baseURL else {
            throw APIError.invalidConfiguration("Invalid host.")
        }
        let secrets = self.secrets
        let account = tenant.id.uuidString
        let override = secretOverride.flatMap { $0.isEmpty ? nil : $0 }
        let tokens = TokenProvider(
            tokenURL: baseURL.appending(path: "auth/token"),
            clientID: tenant.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: {
                if let override { return override }
                guard let stored = try secrets.secret(for: account), !stored.isEmpty else {
                    throw APIError.missingSecret
                }
                return stored
            },
            session: session,
            environmentName: tenant.displayName,
            activity: activity.recorder
        )
        return HTTPClient(
            baseURL: baseURL,
            environmentID: tenant.normalizedEnvironmentID,
            tokens: tokens,
            session: session,
            classicWritePolicy: tenant.allowClassicScopeChanges ? .scopeOnly : .denied,
            environmentName: tenant.displayName,
            activity: activity.recorder
        )
    }

    /// Requests a token and lists computer device groups.
    func testConnection(_ tenant: Tenant, secretOverride: String? = nil) async {
        connectionStates[tenant.id] = .testing
        activity.app("Testing connection to “\(tenant.displayName)”.", environment: tenant.displayName)
        do {
            let client = try makeClient(for: tenant, secretOverride: secretOverride)
            let groups = try await LiveDeviceGroupsAPI(client: client).computerGroups()
            connectionStates[tenant.id] = .succeeded(groups: groups, at: Date())
        } catch is CancellationError {
            connectionStates[tenant.id] = .idle
        } catch {
            connectionStates[tenant.id] = .failed(ErrorReport(error))
        }
    }
}
