import Foundation
import JTKit
import Observation

/// The APIs and identity of the place migrations run against: a live tenant or offline demo.
nonisolated struct MigrationEnvironment: Sendable {
    let displayName: String
    let isDemo: Bool
    let environmentID: String?
    /// Prefix/suffix for suggested blueprint names, from the tenant's settings.
    let naming: BlueprintNaming
    /// Template for suggested blueprint descriptions, from the tenant's settings.
    let descriptionTemplate: String
    /// Links into the Jamf Pro console, when the tenant has its address set.
    let jamfProLinks: JamfProLinks?
    let classic: any ClassicAPI
    /// JTKit's Jamf Platform API client: device groups and Blueprints. In demo
    /// mode its requests are answered by `DemoBlueprintServer`, inside the app.
    let platform: JamfPlatform.Client
    /// Present only when classic scope changes are explicitly enabled for the tenant.
    let classicScopeWriter: (any ClassicScopeWriter)?

    init(
        displayName: String, isDemo: Bool, environmentID: String?,
        naming: BlueprintNaming = .default,
        descriptionTemplate: String = BlueprintBuilder.defaultDescriptionTemplate,
        jamfProLinks: JamfProLinks? = nil,
        classic: any ClassicAPI, platform: JamfPlatform.Client,
        classicScopeWriter: (any ClassicScopeWriter)? = nil
    ) {
        self.displayName = displayName
        self.isDemo = isDemo
        self.environmentID = environmentID
        self.naming = naming
        self.descriptionTemplate = descriptionTemplate
        self.jamfProLinks = jamfProLinks
        self.classic = classic
        self.platform = platform
        self.classicScopeWriter = classicScopeWriter
    }

    var blueprints: JamfPlatform.Blueprints { JamfPlatform.Blueprints(client: platform) }

    /// The offline demo's name, in history, scope backups and the activity log.
    static let demoDisplayName = "Offline demo"

    /// Offline demo. Classic scope changes are enabled here (in memory only) so the
    /// full flow, including unscope and restore, can be tried without a tenant.
    /// With a log, the demo's Platform API requests show in the activity log.
    static func demo(
        log: ActivityLog? = nil,
        server: DemoBlueprintServer = DemoBlueprintServer(),
        classicServer: DemoClassicServer = DemoClassicServer()
    ) -> MigrationEnvironment {
        MigrationEnvironment(
            displayName: demoDisplayName,
            isDemo: true,
            environmentID: nil,
            classic: DemoClassicAPI(server: classicServer),
            platform: server.client(log: log),
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
    private(set) var groups: [JamfPlatform.DeviceGroup] = []
    private(set) var groupsError: ErrorReport?
    private(set) var profiles: [ProfileKey: ClassicProfile] = [:]
    private(set) var profileErrors: [ProfileKey: ErrorReport] = [:]
    private(set) var reports: [ProfileKey: EligibilityReport] = [:]
    private(set) var detailsLoaded = 0
    /// Lazily created from view bodies, so not observed.
    @ObservationIgnored private var sessions: [ProfileKey: MigrationSession] = [:]
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

    func status(for key: ProfileKey) -> EligibilityStatus? { reports[key]?.status }

    /// Groups a profile of this platform can target.
    func groups(for platform: ProfilePlatform) -> [JamfPlatform.DeviceGroup] {
        groups.filter { $0.deviceType == platform.deviceGroupType }
    }

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
        let platform = environment.platform
        async let macResult = Result { try await classic.listProfiles(platform: .macOS) }
        async let mobileResult = Result { try await classic.listProfiles(platform: .mobile) }
        // Every group, unfiltered: migrations match each profile against groups of
        // its own platform, and one paged read serves both.
        async let groupResult = Result { try await platform.deviceGroups() }

        switch await groupResult {
        case let .success(groups): self.groups = groups
        case let .failure(error): groupsError = ErrorReport(error); groups = []
        }
        switch (await macResult, await mobileResult) {
        case let (.success(mac), .success(mobile)):
            summaries = (mac + mobile).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            listPhase = .loaded
        case let (.failure(error), _), let (_, .failure(error)):
            summaries = []
            listPhase = .failed(ErrorReport(error))
            return
        }

        await loadDetails(keys: summaries.map(\.key))
    }

    /// Fetches full profiles with bounded concurrency, updating badges as they arrive.
    private func loadDetails(keys: [ProfileKey]) async {
        let classic = environment.classic
        await withTaskGroup(of: (ProfileKey, Result<ClassicProfile, any Error>).self) { group in
            var iterator = keys.makeIterator()
            func enqueue() {
                guard let key = iterator.next() else { return }
                group.addTask { (key, await Result { try await classic.profile(key: key) }) }
            }
            for _ in 0..<detailConcurrency { enqueue() }
            while let (key, result) = await group.next() {
                if Task.isCancelled { group.cancelAll(); return }
                apply(key: key, result: result)
                detailsLoaded += 1
                enqueue()
            }
        }
    }

    func reloadProfile(key: ProfileKey) async {
        let result = await Result { try await environment.classic.profile(key: key) }
        apply(key: key, result: result)
        if case let .success(profile) = result {
            sessions[key]?.sourceDidChange(profile: profile, report: reports[key])
        }
    }

    private func apply(key: ProfileKey, result: Result<ClassicProfile, any Error>) {
        switch result {
        case let .success(profile):
            profiles[key] = profile
            profileErrors[key] = nil
            reports[key] = EligibilityChecker.check(profile, platformGroups: groups)
        case let .failure(error):
            profileErrors[key] = ErrorReport(error)
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
        workspace.summaries = ProfilePlatform.allCases.flatMap { platform in
            (try? ClassicProfileList.parse(Data(DemoFixtures.profileListJSON(platform: platform).utf8), platform: platform)) ?? []
        }
        for summary in workspace.summaries {
            if let xml = DemoFixtures.profilesByKey[summary.key],
               let profile = try? ClassicXMLParser.parseProfile(Data(xml.utf8), platform: summary.platform) {
                workspace.apply(key: summary.key, result: .success(profile))
            }
        }
        workspace.detailsLoaded = workspace.summaries.count
        workspace.listPhase = .loaded
        return workspace
    }
    #endif

    // MARK: Sessions

    /// The migration session for a loaded profile (created on first use).
    func session(for key: ProfileKey) -> MigrationSession? {
        if let existing = sessions[key] { return existing }
        guard let profile = profiles[key], let report = reports[key] else { return nil }
        let session = MigrationSession(profile: profile, report: report, workspace: self)
        sessions[key] = session
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
