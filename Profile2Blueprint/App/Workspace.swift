import Foundation
import JTKit
import Observation
import os

/// The APIs and identity of the place migrations run against: a live tenant or demo mode.
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
    /// JTKit's Jamf Platform API client: device groups, Blueprints and the
    /// Classic API. In demo mode its requests are answered by JTKit's demo
    /// server and the app's `DemoClassicServer`, inside the app.
    let platform: JamfPlatform.Client
    private let scopeWriter: (any ClassicScopeWriter)?
    /// The tenant's "Allow classic scope changes" switch as it is now, so a
    /// migration still running when it's turned off can't change the scope.
    private let scopeChanges: ClassicWriteSwitch

    /// Present only while classic scope changes are turned on for the tenant;
    /// read at every use.
    var classicScopeWriter: (any ClassicScopeWriter)? { scopeChanges.isOn ? scopeWriter : nil }

    init(
        displayName: String, isDemo: Bool, environmentID: String?,
        naming: BlueprintNaming = .default,
        descriptionTemplate: String = BlueprintBuilder.defaultDescriptionTemplate,
        jamfProLinks: JamfProLinks? = nil,
        classic: any ClassicAPI, platform: JamfPlatform.Client,
        classicScopeWriter: (any ClassicScopeWriter)? = nil,
        scopeChanges: ClassicWriteSwitch = ClassicWriteSwitch(true)
    ) {
        self.displayName = displayName
        self.isDemo = isDemo
        self.environmentID = environmentID
        self.naming = naming
        self.descriptionTemplate = descriptionTemplate
        self.jamfProLinks = jamfProLinks
        self.classic = classic
        self.platform = platform
        scopeWriter = classicScopeWriter
        self.scopeChanges = scopeChanges
    }

    var blueprints: JamfPlatform.Blueprints { JamfPlatform.Blueprints(client: platform) }
}

/// A tenant's "Allow classic scope changes" switch, shared by its client's
/// allow-list and its workspace and changed when the tenant is saved.
nonisolated final class ClassicWriteSwitch: Sendable {
    private let state: OSAllocatedUnfairLock<Bool>

    init(_ isOn: Bool) {
        state = OSAllocatedUnfairLock(initialState: isOn)
    }

    var isOn: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    var policy: ClassicWritePolicy { isOn ? .scopeOnly : .denied }
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
    /// A platform whose profile list couldn't be read while the other's could.
    private(set) var listErrors: [ProfilePlatform: ErrorReport] = [:]
    private(set) var profiles: [ProfileKey: ClassicProfile] = [:]
    private(set) var profileErrors: [ProfileKey: ErrorReport] = [:]
    private(set) var reports: [ProfileKey: EligibilityReport] = [:]
    private(set) var detailsLoaded = 0
    /// Lazily created from view bodies, so not observed.
    @ObservationIgnored private var sessions: [ProfileKey: MigrationSession] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Maximum parallel profile fetches, kept low to limit Classic API load.
    var detailConcurrency = 4

    /// The stores are shared by every workspace on the same files (`AppModel`
    /// owns them), so no two copies overwrite each other.
    init(
        environment: MigrationEnvironment,
        history: HistoryLog,
        scopeBackups: ScopeBackupStore,
        sessionStates: SessionStateStore
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
        listErrors = [:]

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
        // One platform's list failing (e.g. no permission for mobile device
        // profiles) still shows the other's profiles, with the error beside them.
        var listed: [ClassicProfileSummary] = []
        var firstError: (any Error)?
        for (platform, result) in [(ProfilePlatform.macOS, await macResult), (.mobile, await mobileResult)] {
            switch result {
            case let .success(list): listed += list
            case let .failure(error):
                listErrors[platform] = ErrorReport(error)
                firstError = firstError ?? error
            }
        }
        if let firstError, listErrors.count == ProfilePlatform.allCases.count {
            summaries = []
            listErrors = [:]
            listPhase = .failed(ErrorReport(firstError))
            return
        }
        summaries = listed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        listPhase = .loaded

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
        apply(key: key, result: await Result { try await environment.classic.profile(key: key) })
    }

    /// Stores a fetched profile and passes it to its open migration, so Reload
    /// and Reload Profile both migrate what the Source tab shows.
    private func apply(key: ProfileKey, result: Result<ClassicProfile, any Error>) {
        switch result {
        case let .success(profile):
            profiles[key] = profile
            profileErrors[key] = nil
            let report = EligibilityChecker.check(profile, platformGroups: groups)
            reports[key] = report
            sessions[key]?.sourceDidChange(profile: profile, report: report)
        case let .failure(error):
            profileErrors[key] = ErrorReport(error)
        }
    }

    #if DEBUG
    /// A demo workspace filled synchronously from fixtures, for previews and tests.
    /// Pass a shared environment and stores to simulate a relaunch against the same data.
    static func previewDemo(
        environment: MigrationEnvironment = .demo(),
        scopeBackups: ScopeBackupStore? = nil,
        sessionStates: SessionStateStore? = nil
    ) -> Workspace {
        let temp = FileManager.default.temporaryDirectory
        let workspace = Workspace(
            environment: environment,
            history: HistoryLog(store: HistoryStore(fileURL: temp.appending(path: "preview-history-\(UUID().uuidString).json"))),
            scopeBackups: scopeBackups ?? ScopeBackupStore(fileURL: temp.appending(path: "preview-scope-backups-\(UUID().uuidString).json")),
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

    /// This workspace was replaced (another tenant, changed settings, demo
    /// mode switched): loading stops, and its migrations stop watching
    /// deployments and never change a classic scope again.
    private(set) var isClosed = false

    func close() {
        isClosed = true
        loadTask?.cancel()
        for session in sessions.values { session.close() }
    }

    /// The migration session for a loaded profile (created on first use).
    func session(for key: ProfileKey) -> MigrationSession? {
        if let existing = sessions[key] { return existing }
        guard !isClosed, let profile = profiles[key], let report = reports[key] else { return nil }
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
