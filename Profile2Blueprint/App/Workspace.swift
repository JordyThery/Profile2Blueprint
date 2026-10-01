import Foundation
import Observation

/// The APIs and identity of the place migrations run against: a live tenant or offline demo.
nonisolated struct MigrationEnvironment: Sendable {
    let displayName: String
    let isDemo: Bool
    let environmentID: String?
    /// Prefix/suffix for suggested blueprint names, from the tenant's settings.
    let naming: BlueprintNaming
    let classic: any ClassicAPI
    let groups: any DeviceGroupsAPI
    let blueprints: any BlueprintsAPI
    /// Present only when classic scope changes are explicitly enabled for the tenant.
    let classicScopeWriter: (any ClassicScopeWriter)?

    init(
        displayName: String, isDemo: Bool, environmentID: String?,
        naming: BlueprintNaming = .default,
        classic: any ClassicAPI, groups: any DeviceGroupsAPI, blueprints: any BlueprintsAPI,
        classicScopeWriter: (any ClassicScopeWriter)? = nil
    ) {
        self.displayName = displayName
        self.isDemo = isDemo
        self.environmentID = environmentID
        self.naming = naming
        self.classic = classic
        self.groups = groups
        self.blueprints = blueprints
        self.classicScopeWriter = classicScopeWriter
    }

    /// Offline demo. Classic scope changes are enabled here (in memory only) so the
    /// full flow, including unscope and restore, can be tried without a tenant.
    static func demo() -> MigrationEnvironment {
        let classicServer = DemoClassicServer()
        return MigrationEnvironment(
            displayName: "Offline demo",
            isDemo: true,
            environmentID: nil,
            classic: DemoClassicAPI(server: classicServer),
            groups: DemoDeviceGroupsAPI(),
            blueprints: DemoBlueprintsAPI(server: DemoBlueprintServer()),
            classicScopeWriter: DemoClassicScopeWriter(server: classicServer)
        )
    }
}

enum LoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(ErrorReport)
}

/// Everything loaded from one environment: profile list, details, groups and eligibility.
@Observable
final class Workspace {
    let environment: MigrationEnvironment
    let history: HistoryLog
    let scopeBackups: ScopeBackupStore
    let sessionStates: SessionStateStore

    private(set) var summaries: [ClassicProfileSummary] = []
    private(set) var listPhase: LoadPhase = .idle
    private(set) var groups: [PlatformGroup] = []
    private(set) var groupsError: ErrorReport?
    private(set) var profiles: [Int: ClassicProfile] = [:]
    private(set) var profileErrors: [Int: ErrorReport] = [:]
    private(set) var reports: [Int: EligibilityReport] = [:]
    private(set) var detailsLoaded = 0
    /// Lazily created from view bodies, so not observed.
    @ObservationIgnored private var sessions: [Int: MigrationSession] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Maximum parallel profile fetches, kept low to limit Classic API load.
    var detailConcurrency = 4

    init(
        environment: MigrationEnvironment,
        history: HistoryLog,
        scopeBackups: ScopeBackupStore = .appDefault(),
        sessionStates: SessionStateStore = .appDefault()
    ) {
        self.environment = environment
        self.history = history
        self.scopeBackups = scopeBackups
        self.sessionStates = sessionStates
    }

    var isLoadingDetails: Bool { listPhase == .loaded && detailsLoaded < summaries.count }

    func status(for id: Int) -> EligibilityStatus? { reports[id]?.status }

    func count(of status: EligibilityStatus) -> Int {
        reports.values.filter { $0.status == status }.count
    }

    // MARK: Loading

    func loadIfNeeded() {
        if listPhase == .idle { reload() }
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func load() async {
        listPhase = .loading
        detailsLoaded = 0
        profiles = [:]
        profileErrors = [:]
        reports = [:]
        groupsError = nil

        let classic = environment.classic
        let groupsAPI = environment.groups
        async let listResult = Result { try await classic.listProfiles() }
        async let groupResult = Result { try await groupsAPI.computerGroups() }

        switch await groupResult {
        case let .success(groups): self.groups = groups
        case let .failure(error): groupsError = ErrorReport(error); groups = []
        }
        switch await listResult {
        case let .success(list):
            summaries = list
            listPhase = .loaded
        case let .failure(error):
            summaries = []
            listPhase = .failed(ErrorReport(error))
            return
        }

        await loadDetails(ids: summaries.map(\.id))
    }

    /// Fetches full profiles with bounded concurrency, updating badges as they arrive.
    private func loadDetails(ids: [Int]) async {
        let classic = environment.classic
        await withTaskGroup(of: (Int, Result<ClassicProfile, any Error>).self) { group in
            var iterator = ids.makeIterator()
            func enqueue() {
                guard let id = iterator.next() else { return }
                group.addTask { (id, await Result { try await classic.profile(id: id) }) }
            }
            for _ in 0..<detailConcurrency { enqueue() }
            while let (id, result) = await group.next() {
                if Task.isCancelled { group.cancelAll(); return }
                apply(id: id, result: result)
                detailsLoaded += 1
                enqueue()
            }
        }
    }

    func reloadProfile(id: Int) async {
        let result = await Result { try await environment.classic.profile(id: id) }
        apply(id: id, result: result)
        if case let .success(profile) = result {
            sessions[id]?.sourceDidChange(profile: profile, report: reports[id])
        }
    }

    private func apply(id: Int, result: Result<ClassicProfile, any Error>) {
        switch result {
        case let .success(profile):
            profiles[id] = profile
            profileErrors[id] = nil
            reports[id] = EligibilityChecker.check(profile, platformGroups: groups)
        case let .failure(error):
            profileErrors[id] = ErrorReport(error)
        }
    }

    #if DEBUG
    /// A demo workspace filled synchronously from fixtures, for previews and tests.
    /// Pass a shared environment and stores to simulate a relaunch against the same data.
    static func previewDemo(
        environment: MigrationEnvironment = .demo(),
        sessionStates: SessionStateStore? = nil
    ) -> Workspace {
        let temp = FileManager.default.temporaryDirectory
        let workspace = Workspace(
            environment: environment,
            history: HistoryLog(store: HistoryStore(fileURL: temp.appending(path: "preview-history-\(UUID().uuidString).json"))),
            scopeBackups: ScopeBackupStore(fileURL: temp.appending(path: "preview-scope-backups-\(UUID().uuidString).json")),
            sessionStates: sessionStates ?? SessionStateStore(fileURL: temp.appending(path: "preview-sessions-\(UUID().uuidString).json"))
        )
        workspace.groups = DemoFixtures.platformGroups
        workspace.summaries = (try? ClassicXMLParser.parseProfileList(Data(DemoFixtures.profileListXML.utf8))) ?? []
        for summary in workspace.summaries {
            if let xml = DemoFixtures.profilesByID[summary.id], let profile = try? ClassicXMLParser.parseProfile(Data(xml.utf8)) {
                workspace.apply(id: summary.id, result: .success(profile))
            }
        }
        workspace.detailsLoaded = workspace.summaries.count
        workspace.listPhase = .loaded
        return workspace
    }
    #endif

    // MARK: Sessions

    /// The migration session for a loaded profile (created on first use).
    func session(for id: Int) -> MigrationSession? {
        if let existing = sessions[id] { return existing }
        guard let profile = profiles[id], let report = reports[id] else { return nil }
        let session = MigrationSession(profile: profile, report: report, workspace: self)
        sessions[id] = session
        return session
    }
}

extension Result where Failure == any Error {
    /// `Result` from an async throwing closure.
    nonisolated init(_ body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
