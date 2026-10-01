import Foundation
import Observation

/// Progress of the optional classic-profile cleanup.
enum UnscopeStatus: Equatable {
    case notRequested
    case waiting(String)
    case unscoped(Date)
    case restored(Date)
    case failed(ErrorReport)
}

/// What the user chose after the duplicate-name check found a match.
enum DuplicateResolution {
    case skip
    case rename
    case openExisting(BlueprintOverview)
}

/// Main-actor state for migrating one profile: the editable draft plus the results
/// of each pipeline stage. Every network action goes through `MigrationPipeline`.
@Observable
final class MigrationSession: Identifiable {
    let profileID: Int
    var id: Int { profileID }
    private(set) var profile: ClassicProfile
    private(set) var report: EligibilityReport
    /// Weak back-reference: the workspace owns its sessions. Groups are snapshotted
    /// so in-flight work continues if the workspace is replaced mid-migration.
    private weak var workspace: Workspace?
    private let environment: MigrationEnvironment
    private let history: HistoryLog
    private let groupsSnapshot: [PlatformGroup]
    private let pipeline: MigrationPipeline
    private let scopeBackups: ScopeBackupStore
    private let sessionStates: SessionStateStore
    @ObservationIgnored private var reportMonitor: Task<Void, Never>?

    // MARK: Draft

    var blueprintName: String
    var blueprintDescription: String
    /// Selected platform group IDs, in scope order.
    var selectedGroupIDs: [String]
    /// Required to continue when eligibility is "needs attention".
    var acknowledgedWarnings = false
    /// Dry run is the default; creating requires switching it off.
    var dryRun = true
    /// Per-profile opt-in: unscope the classic profile once the blueprint is deployed
    /// to every device. Only offered when classic scope changes are enabled for the tenant.
    var unscopeAfterDeploy = false {
        didSet {
            if blueprintID != nil, oldValue != unscopeAfterDeploy { persistSessionRecord() }
        }
    }

    // MARK: Results

    private(set) var state: MigrationState = .idle
    private(set) var isBusy = false
    private(set) var lastError: ErrorReport?
    private(set) var dryRunSummary: String?
    /// Same-named blueprints found right before create; non-nil means "ask the user".
    private(set) var duplicates: [BlueprintOverview]?
    private(set) var blueprintID: String?
    private(set) var readBack: BlueprintDetail?
    private(set) var fidelity: FidelityReport?
    private(set) var deployment: DeploymentState?
    private(set) var outcome: DeploymentOutcome?
    private(set) var deviceReport: BlueprintReport?
    /// Name that was actually sent on create (the draft may be edited afterwards).
    private(set) var createdName: String?
    /// The most recent unrestored scope backup for this profile, if any.
    private(set) var scopeBackup: ScopeBackup?
    private(set) var unscopeStatus: UnscopeStatus = .notRequested
    /// The device report is being refreshed in the background after a deployment.
    private(set) var reportMonitorActive = false
    /// A blueprint from an earlier launch is being re-attached.
    private(set) var isRestoring = false

    init(profile: ClassicProfile, report: EligibilityReport, workspace: Workspace) {
        profileID = profile.id
        self.profile = profile
        self.report = report
        self.workspace = workspace
        environment = workspace.environment
        history = workspace.history
        groupsSnapshot = workspace.groups
        scopeBackups = workspace.scopeBackups
        sessionStates = workspace.sessionStates
        pipeline = MigrationPipeline(classic: workspace.environment.classic, blueprints: workspace.environment.blueprints)
        blueprintName = BlueprintBuilder.defaultName(for: profile)
        blueprintDescription = BlueprintBuilder.defaultDescription(for: profile)
        selectedGroupIDs = ScopeMapper.automaticSelection(report.scopeMapping)
        let profileID = profile.id
        let environment = workspace.environment
        let environmentKey = environment.environmentID ?? environment.displayName
        Task { [scopeBackups, sessionStates] in
            if let existing = await scopeBackups.latest(profileID: profileID, environmentID: environment.environmentID,
                                                        environmentName: environment.displayName) {
                self.scopeBackup = existing
                self.unscopeStatus = .unscoped(existing.createdAt)
            }
            if let saved = await sessionStates.record(environmentKey: environmentKey, profileID: profileID) {
                await self.restore(from: saved)
            }
        }
    }

    /// Live groups from the workspace, or the snapshot if it has gone away.
    private var platformGroups: [PlatformGroup] {
        workspace?.groups ?? groupsSnapshot
    }

    // MARK: Derived

    /// The request that would be sent with the current draft, or why it can't be built.
    var preview: Result<BlueprintRequest, BlueprintBuildError> {
        Result { () throws(BlueprintBuildError) in
            try BlueprintBuilder.build(profile: profile, name: blueprintName, description: blueprintDescription, deviceGroupIDs: selectedGroupIDs)
        }
    }

    var selectedGroups: [PlatformGroup] { selectedGroupIDs.compactMap { id in platformGroups.first { $0.id == id } } }

    /// Sum of member counts. Groups can overlap, so this is an upper bound when > 1 group.
    var deviceCount: Int { selectedGroups.reduce(0) { $0 + $1.memberCount } }

    /// Eligibility with the pick-a-group findings resolved by the current selection.
    /// Warnings about information loss (exclusions, limitations, …) remain.
    var effectiveReport: EligibilityReport {
        guard !selectedGroupIDs.isEmpty else { return report }
        var resolved = report
        resolved.findings.removeAll {
            $0.kind == .noMappedGroup || $0.kind == .unmatchedGroups || $0.kind == .ambiguousGroups
        }
        return resolved
    }

    var needsAcknowledgement: Bool { effectiveReport.status == .needsAttention }

    var canCreate: Bool {
        !isBusy && !dryRun && blueprintID == nil && effectiveReport.status != .blocked
            && (!needsAcknowledgement || acknowledgedWarnings) && (try? preview.get()) != nil
    }

    var canDeploy: Bool {
        guard !isBusy, blueprintID != nil, let fidelity else { return false }
        if case .deployed = state { return false }
        if case .deploying = state { return false }
        return fidelity.passed
    }

    /// Classic scope changes are enabled for this tenant (explicit opt-in in tenant settings).
    var canChangeClassicScope: Bool { environment.classicScopeWriter != nil }

    /// Manual unscope is allowed only after a clean deployment and when nothing is backed up yet.
    var canUnscopeNow: Bool {
        canChangeClassicScope && !isBusy && scopeBackup == nil && ClassicScopeService.deploymentAllowsUnscope(outcome)
    }

    var canRestoreScope: Bool { canChangeClassicScope && !isBusy && scopeBackup != nil }

    // MARK: Draft editing

    func toggleGroup(_ id: String) {
        if let index = selectedGroupIDs.firstIndex(of: id) {
            selectedGroupIDs.remove(at: index)
        } else {
            selectedGroupIDs.append(id)
        }
    }

    func sourceDidChange(profile: ClassicProfile, report: EligibilityReport?) {
        guard blueprintID == nil else { return }
        self.profile = profile
        if let report { self.report = report }
    }

    // MARK: Stages

    /// Validates and builds locally, and checks for name clashes. Nothing is written.
    func runDryRun() async {
        await perform { [self] in
            let request = try await prepareRequest()
            let existing = try await pipeline.existingBlueprints()
            let groups = selectedGroups.map(\.name).joined(separator: ", ")
            let payloads = profile.document.payloadCount
            var summary = "Would create “\(request.name)” (not deployed) with \(payloads) payload\(payloads == 1 ? "" : "s"), targeting \(groups) — \(deviceCount) device\(deviceCount == 1 ? "" : "s")."
            if !existing.isEmpty {
                summary += " A blueprint with this name already exists (\(existing.map(\.id).joined(separator: ", ")))."
            }
            dryRunSummary = summary
            history.record(.dryRun, environment: environment, profile: profile, blueprintName: request.name,
                                     result: existing.isEmpty ? .success : .warning, message: summary)
        }
    }

    /// Creates the blueprint without deploying, then reads it back and verifies it.
    func create() async {
        guard canCreate else { return }
        await perform { [self] in
            let request = try await prepareRequest()
            let existing = try await pipeline.existingBlueprints()
            if !existing.isEmpty {
                duplicates = existing
                state = await pipeline.state
                return
            }
            let created = try await pipeline.create()
            blueprintID = created.id
            createdName = request.name
            persistSessionRecord()
            state = await pipeline.state
            history.record(.create, environment: environment, profile: profile, blueprintID: created.id, blueprintName: request.name,
                                     result: .success, message: "Created, not deployed. Scope: \(selectedGroups.map(\.name).joined(separator: ", ")).")
            try await verifyStage()
        }
    }

    func resolveDuplicate(_ resolution: DuplicateResolution) async {
        let found = duplicates ?? []
        duplicates = nil
        switch resolution {
        case .skip:
            history.record(.skipExisting, environment: environment, profile: profile, blueprintID: found.first?.id,
                                     blueprintName: blueprintName, result: .warning, message: "Skipped: a blueprint with this name already exists.")
        case .rename:
            blueprintName = Self.nextName(after: blueprintName)
        case let .openExisting(existing):
            await perform { [self] in
                try await pipeline.adoptExisting(id: existing.id)
                blueprintID = existing.id
                createdName = existing.name
                persistSessionRecord()
                state = await pipeline.state
                history.record(.adoptExisting, environment: environment, profile: profile, blueprintID: existing.id,
                                         blueprintName: existing.name, result: .success, message: "Using the existing blueprint instead of creating one.")
                try await verifyStage()
            }
        }
    }

    func verify() async {
        await perform { [self] in try await verifyStage() }
    }

    /// Deploys after the confirmation sheet, then polls until done or timed out.
    func deploy(_ confirmation: DeployConfirmation) async {
        stopReportMonitor()
        await perform { [self] in
            history.record(.deploy, environment: environment, profile: profile, blueprintID: confirmation.blueprintID,
                                     blueprintName: confirmation.blueprintName, result: .success,
                                     message: "Confirmed by user for \(confirmation.groupNames.joined(separator: ", ")) (\(confirmation.deviceCount) devices).")
            let result = try await pipeline.deploy(confirmation: confirmation) { [weak self] progress in
                await MainActor.run { self?.deployment = progress }
            }
            await finish(result)
        }
    }

    /// Re-polls after a timeout.
    func recheckDeployment() async {
        guard let blueprintID else { return }
        stopReportMonitor()
        await perform { [self] in
            let result = try await pipeline.monitor(id: blueprintID) { [weak self] progress in
                await MainActor.run { self?.deployment = progress }
            }
            await finish(result)
        }
    }

    // MARK: Classic cleanup

    /// Unscopes the classic profile (after the user confirmed in the UI).
    func unscopeClassic() async {
        guard canUnscopeNow else { return }
        await perform { [self] in try await unscopeStage() }
    }

    /// Puts the backed-up scope back.
    func restoreClassicScope() async {
        guard canRestoreScope, let backup = scopeBackup else { return }
        await perform { [self] in
            do {
                _ = try await ClassicScopeService.restore(backup, environment: environment, backups: scopeBackups)
                scopeBackup = nil
                unscopeStatus = .restored(Date())
                history.record(.restoreClassicScope, environment: environment, profile: profile, blueprintID: blueprintID,
                               blueprintName: createdName, result: .success, message: "Restored the classic profile's scope from the backup taken \(backup.createdAt.formatted()).")
            } catch {
                unscopeStatus = .failed(ErrorReport(error))
                history.record(.restoreClassicScope, environment: environment, profile: profile, blueprintID: blueprintID,
                               blueprintName: createdName, result: .failure, message: error.localizedDescription)
                throw error
            }
        }
    }

    private func unscopeStage() async throws {
        do {
            let result = try await ClassicScopeService.unscope(profileID: profileID, blueprintID: blueprintID,
                                                              environment: environment, backups: scopeBackups)
            scopeBackup = result.backup
            unscopeStatus = .unscoped(result.backup.createdAt)
            history.record(.unscopeClassic, environment: environment, profile: profile, blueprintID: blueprintID, blueprintName: createdName,
                           result: .success, message: "Removed all scope targets from the classic profile (payloads untouched). Scope backup saved; restore is available.")
        } catch {
            unscopeStatus = .failed(ErrorReport(error))
            history.record(.unscopeClassic, environment: environment, profile: profile, blueprintID: blueprintID, blueprintName: createdName,
                           result: .failure, message: error.localizedDescription)
            throw error
        }
    }

    /// Runs the opt-in auto-unscope after a deployment result, if (and only if) it was clean.
    private func autoUnscopeIfRequested() async throws {
        guard unscopeAfterDeploy, canChangeClassicScope, scopeBackup == nil else { return }
        if ClassicScopeService.deploymentAllowsUnscope(outcome) {
            try await unscopeStage()
        } else {
            let detail = deviceReport.map { "\($0.failed) failed, \($0.pending) pending" } ?? "no device report yet"
            unscopeStatus = .waiting("Not unscoped yet: \(detail). The report refreshes automatically and cleanup runs once every device succeeds.")
            history.record(.unscopeClassic, environment: environment, profile: profile, blueprintID: blueprintID, blueprintName: createdName,
                           result: .warning, message: "Auto-unscope deferred: \(detail). Watching the device report.")
        }
    }

    // MARK: Session persistence

    private var environmentKey: String { environment.environmentID ?? environment.displayName }

    /// Saves enough to re-attach this migration after a relaunch.
    private func persistSessionRecord() {
        guard let blueprintID else { return }
        let record = PersistedMigration(
            environmentKey: environmentKey,
            profileID: profileID,
            blueprintID: blueprintID,
            blueprintName: createdName ?? blueprintName,
            selectedGroupIDs: selectedGroupIDs,
            unscopeAfterDeploy: unscopeAfterDeploy
        )
        Task { [sessionStates] in await sessionStates.save(record) }
    }

    /// Re-attaches a blueprint created in an earlier launch: rebuilds the request,
    /// adopts the blueprint and verifies it. A 404 clears the stale record.
    private func restore(from record: PersistedMigration) async {
        isRestoring = true
        defer { isRestoring = false }
        blueprintName = record.blueprintName
        selectedGroupIDs = record.selectedGroupIDs
        unscopeAfterDeploy = record.unscopeAfterDeploy
        if effectiveReport.status == .needsAttention {
            acknowledgedWarnings = true // accepted when the blueprint was created
        }
        await perform { [self] in
            do {
                _ = try await prepareRequest()
                try await pipeline.adoptExisting(id: record.blueprintID)
                blueprintID = record.blueprintID
                createdName = record.blueprintName
                state = await pipeline.state
                try await verifyStage()
            } catch {
                if case APIError.http(404, _, _, _, _) = error {
                    await sessionStates.remove(environmentKey: environmentKey, profileID: profileID)
                    blueprintID = nil
                    createdName = nil
                    state = .fetched
                    throw PipelineError(message: "The blueprint created in an earlier session no longer exists on the server. The saved reference was removed; create it again if needed.")
                }
                throw error
            }
        }
    }

    // MARK: Device report monitor

    /// Refreshes the device report in the background until no device is pending,
    /// then runs the opt-in classic cleanup.
    private func startReportMonitor() {
        guard let blueprintID else { return }
        reportMonitor?.cancel()
        reportMonitorActive = true
        reportMonitor = Task { [pipeline] in
            let final = try? await pipeline.monitorReport(id: blueprintID) { [weak self] update in
                await MainActor.run {
                    self?.deviceReport = update
                    self?.outcome = .succeeded(update)
                }
            }
            guard !Task.isCancelled else { return }
            reportMonitorActive = false
            await reportBecameFinal(final)
        }
    }

    private func stopReportMonitor() {
        reportMonitor?.cancel()
        reportMonitor = nil
        reportMonitorActive = false
    }

    private func reportBecameFinal(_ report: BlueprintReport?) async {
        if let report {
            deviceReport = report
            outcome = .succeeded(report)
            state = .deployed(report)
        }
        guard unscopeAfterDeploy, canChangeClassicScope, scopeBackup == nil,
              ClassicScopeService.deploymentAllowsUnscope(outcome) else { return }
        await perform { [self] in try await unscopeStage() }
    }

    // MARK: Helpers

    private func finish(_ result: DeploymentOutcome) async {
        outcome = result
        state = await pipeline.state
        switch result {
        case let .succeeded(report):
            deviceReport = report
            let counts = report.map { "succeeded \($0.succeeded), failed \($0.failed), pending \($0.pending)" } ?? "report unavailable"
            history.record(.deploymentResult, environment: environment, profile: profile, blueprintID: blueprintID,
                                     blueprintName: createdName, result: (report?.failed ?? 0) > 0 ? .warning : .success,
                                     message: "Deployed. Devices: \(counts).")
            try? await autoUnscopeIfRequested()
            if (report?.pending ?? 1) > 0 { startReportMonitor() }
        case let .failed(deployment):
            history.record(.deploymentResult, environment: environment, profile: profile, blueprintID: blueprintID,
                                     blueprintName: createdName, result: .failure, message: "Deployment failed: \(deployment.displayText).")
        case let .timedOut(last):
            history.record(.deploymentResult, environment: environment, profile: profile, blueprintID: blueprintID,
                                     blueprintName: createdName, result: .warning,
                                     message: "Still in progress when polling stopped (\(last?.displayText ?? "no status")).")
        }
    }

    private func prepareRequest() async throws -> BlueprintRequest {
        await pipeline.load(profile)
        _ = try await pipeline.validate(platformGroups: platformGroups)
        let request = try await pipeline.build(
            name: blueprintName,
            description: blueprintDescription,
            deviceGroupIDs: selectedGroupIDs,
            // The pipeline re-checks base eligibility; a selection that resolves every
            // pick-a-group warning counts as acknowledged.
            acknowledgedWarnings: acknowledgedWarnings || effectiveReport.status == .ready
        )
        state = await pipeline.state
        return request
    }

    private func verifyStage() async throws {
        let result = try await pipeline.verify()
        fidelity = result
        readBack = await pipeline.readBack
        state = await pipeline.state
        // An already-deployed blueprint (restored session, or adopted duplicate) resumes
        // at the deployed stage, with the report refreshing until it is clean.
        if let detail = readBack, detail.deploymentState.isDeployedSuccessfully {
            let report = try? await environment.blueprints.report(id: detail.id)
            deviceReport = report
            outcome = .succeeded(report)
            state = .deployed(report)
            if (report?.pending ?? 1) > 0 {
                startReportMonitor()
            } else {
                Task { await reportBecameFinal(report) }
            }
        }
        let summary = result.passed
            ? "All identity, order, count, settings and scope checks match."
                + (result.caseChanges.isEmpty ? "" : " \(result.caseChanges.count) key casing change\(result.caseChanges.count == 1 ? "" : "s") to review.")
            : "\(result.mismatches.count) mismatch\(result.mismatches.count == 1 ? "" : "es"): " + result.mismatches.prefix(3).map(\.field).joined(separator: "; ")
        history.record(.verify, environment: environment, profile: profile, blueprintID: blueprintID, blueprintName: createdName,
                                 result: result.passed ? (result.caseChanges.isEmpty ? .success : .warning) : .failure, message: summary)
    }

    private func perform(_ work: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            lastError = ErrorReport(error)
            state = await pipeline.state
        }
    }

    /// "Name (migrated)" → "Name (migrated) 2" → "Name (migrated) 3".
    nonisolated static func nextName(after name: String) -> String {
        if let match = name.firstMatch(of: /^(.*) (\d+)$/), let number = Int(match.2) {
            return "\(match.1) \(number + 1)"
        }
        return "\(name) 2"
    }
}

extension Result<ProfileDocument, PlistParseError> {
    nonisolated var payloadCount: Int { (try? get())?.payloads.count ?? 0 }
}
