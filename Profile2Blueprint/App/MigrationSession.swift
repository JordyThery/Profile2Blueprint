import Foundation
import JTKit
import Observation

/// Progress of the optional classic profile cleanup.
enum UnscopeStatus: Equatable {
    case notRequested
    /// Opted in; waiting for a clean device report.
    case waiting(String)
    /// Opted in, but the automatic cleanup won't run (the classic scope reaches
    /// devices the Blueprint doesn't, or the report stopped refreshing).
    case heldBack(String)
    case unscoped(Date)
    /// A scope change whose outcome isn't known: Restore is offered.
    case uncertain(Date)
    case restored(Date)
    case failed(ErrorReport)
}

/// What the user chose after the duplicate-name check found a match.
enum DuplicateResolution {
    case skip
    case rename
    case openExisting(JamfPlatform.BlueprintOverview)
}

/// Main-actor state for migrating one profile: the editable draft plus the results
/// of each pipeline stage. Every network action goes through `MigrationPipeline`.
@Observable
final class MigrationSession: Identifiable {
    let key: ProfileKey
    var id: ProfileKey { key }
    var platform: ProfilePlatform { key.platform }
    private(set) var profile: ClassicProfile
    private(set) var report: EligibilityReport
    /// Weak back-reference: the workspace owns its sessions. Groups are snapshotted
    /// so in-flight work continues if the workspace is replaced mid-migration.
    private weak var workspace: Workspace?
    private let environment: MigrationEnvironment
    private let history: HistoryLog
    private let groupsSnapshot: [JamfPlatform.DeviceGroup]
    private let pipeline: MigrationPipeline
    private let scopeBackups: ScopeBackupStore
    private let sessionStates: SessionStateStore
    @ObservationIgnored private var reportMonitor: Task<Void, Never>?
    /// Reading the scope backup and the saved migration from an earlier launch.
    @ObservationIgnored private var savedStateTask: Task<Void, Never>?
    /// The automatic cleanup came due while another action was running; it
    /// runs as soon as that action ends.
    @ObservationIgnored private var cleanupQueued = false
    /// The last report and deferral written to the history, so Refresh Status
    /// doesn't repeat the same line.
    @ObservationIgnored private var recordedReport: JamfPlatform.BlueprintReport??
    @ObservationIgnored private var recordedDeferral: String?

    // MARK: Draft

    var blueprintName: String
    var blueprintDescription: String
    /// Selected platform group IDs, in scope order.
    var selectedGroupIDs: [String]
    /// Required to continue when eligibility is "needs attention".
    var acknowledgedWarnings = false
    /// Dry run is the default; creating requires switching it off.
    var dryRun = true
    /// Per-profile opt-in: unscope the classic profile once the Blueprint is deployed
    /// to every device. Only offered when classic scope changes are on for the tenant.
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
    /// Same-named Blueprints found right before create; non-nil means "ask the user".
    private(set) var duplicates: [JamfPlatform.BlueprintOverview]?
    private(set) var blueprintID: String?
    private(set) var readBack: JamfPlatform.BlueprintDetail?
    private(set) var fidelity: FidelityReport?
    private(set) var deployment: JamfPlatform.DeploymentStatus?
    private(set) var outcome: DeploymentOutcome?
    private(set) var deviceReport: JamfPlatform.BlueprintReport?
    /// Name that was actually sent on create (the draft may be edited afterwards).
    private(set) var createdName: String?
    /// The most recent unrestored scope backup for this profile whose change
    /// may have happened, if any.
    private(set) var scopeBackup: ScopeBackup?
    /// The app changed this profile's scope before (restored since or not):
    /// the automatic cleanup runs at most once, so a Restore is never undone.
    private(set) var scopeChangedBefore = false
    private(set) var unscopeStatus: UnscopeStatus = .notRequested
    /// The device report is being refreshed in the background after a deployment.
    private(set) var reportMonitorActive = false
    /// The scope backup and a Blueprint from an earlier launch are being read
    /// and re-attached; create, dry run, verify and deploy wait for it.
    private(set) var isLoadingSavedState = true
    /// The workspace was replaced: no more cleanup from this session.
    private(set) var isClosed = false

    init(profile: ClassicProfile, report: EligibilityReport, workspace: Workspace) {
        key = profile.key
        self.profile = profile
        self.report = report
        self.workspace = workspace
        environment = workspace.environment
        history = workspace.history
        groupsSnapshot = workspace.groups
        scopeBackups = workspace.scopeBackups
        sessionStates = workspace.sessionStates
        pipeline = MigrationPipeline(classic: workspace.environment.classic, blueprints: workspace.environment.blueprints)
        blueprintName = BlueprintBuilder.defaultName(for: profile, naming: workspace.environment.naming)
        blueprintDescription = BlueprintBuilder.defaultDescription(for: profile, template: workspace.environment.descriptionTemplate)
        selectedGroupIDs = ScopeMapper.automaticSelection(report.scopeMapping)
        let key = profile.key
        let environment = workspace.environment
        let environmentKey = environment.environmentID ?? environment.displayName
        savedStateTask = Task { [scopeBackups, sessionStates] in
            if let existing = await scopeBackups.latest(key: key, environment: environment) {
                // A change whose outcome wasn't recorded is checked against the profile first.
                if let settled = await ClassicScopeService.settle(existing, environment: environment, backups: scopeBackups) {
                    self.showBackup(settled)
                }
            }
            self.scopeChangedBefore = await scopeBackups.hasScopeChange(key: key, environment: environment)
            if let saved = await sessionStates.record(environmentKey: environmentKey, key: key) {
                await self.restore(from: saved)
            }
            self.isLoadingSavedState = false
        }
    }

    /// Waits until the saved state from an earlier launch is read and re-attached.
    func waitUntilReady() async {
        await savedStateTask?.value
    }

    /// The workspace was replaced: stops watching the report and never runs
    /// the cleanup again.
    func close() {
        isClosed = true
        cleanupQueued = false
        stopReportMonitor()
    }

    private func showBackup(_ backup: ScopeBackup) {
        scopeBackup = backup
        unscopeStatus = backup.writeState == .written ? .unscoped(backup.createdAt) : .uncertain(backup.createdAt)
    }

    /// Live groups from the workspace, or the snapshot if it has gone away.
    private var platformGroups: [JamfPlatform.DeviceGroup] {
        workspace?.groups ?? groupsSnapshot
    }

    // MARK: Derived

    /// The request that would be sent with the current draft, or why it can't be built.
    var preview: Result<BlueprintRequest, BlueprintBuildError> {
        Result { () throws(BlueprintBuildError) in
            try BlueprintBuilder.build(profile: profile, name: blueprintName, description: blueprintDescription, deviceGroupIDs: selectedGroupIDs)
        }
    }

    var selectedGroups: [JamfPlatform.DeviceGroup] { selectedGroupIDs.compactMap { id in platformGroups.first { $0.id == id } } }

    /// Sum of the known member counts. Groups can overlap, so this is an upper
    /// bound when > 1 group; a group without a count adds nothing (see `deviceCountIsPartial`).
    var deviceCount: Int { selectedGroups.knownDeviceCount }

    /// Some selected group came without a member count.
    var deviceCountIsPartial: Bool { selectedGroups.hasUnknownDeviceCount }

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
        !isBusy && !isLoadingSavedState && !dryRun && blueprintID == nil && effectiveReport.status != .blocked
            && (!needsAcknowledgement || acknowledgedWarnings) && (try? preview.get()) != nil
    }

    /// A dry run is for before create; afterwards it would start the pipeline over.
    var canRunDryRun: Bool {
        !isBusy && !isLoadingSavedState && blueprintID == nil && effectiveReport.status != .blocked
            && (!needsAcknowledgement || acknowledgedWarnings) && (try? preview.get()) != nil
    }

    var canDeploy: Bool {
        guard !isBusy, !isLoadingSavedState, blueprintID != nil, let fidelity else { return false }
        if case .deployed = state { return false }
        if case .deploying = state { return false }
        return fidelity.passed
    }

    /// Classic scope changes are on for this tenant (explicit opt-in in its
    /// settings), read live: turning the switch off stops every scope change.
    var canChangeClassicScope: Bool { environment.classicScopeWriter != nil }

    /// Manual unscope is allowed only after a clean deployment and when nothing is backed up yet.
    var canUnscopeNow: Bool {
        canChangeClassicScope && !isBusy && !isLoadingSavedState && !isClosed && scopeBackup == nil
            && ClassicScopeService.deploymentAllowsUnscope(outcome)
    }

    var canRestoreScope: Bool { canChangeClassicScope && !isBusy && !isClosed && scopeBackup != nil }

    /// What the Blueprint targets: its read-back scope once it exists.
    var scopeCoverage: ScopeCoverage {
        ScopeCoverage(platform: platform, platformGroups: platformGroups,
                      blueprintGroupIDs: readBack?.scopeDeviceGroups ?? selectedGroupIDs)
    }

    /// Classic scope targets the Blueprint's groups don't cover; unscoping
    /// would remove the profile from those devices. Empty when all are covered.
    var uncoveredClassicTargets: [String] { scopeCoverage.uncovered(in: profile.scope) }

    // MARK: Draft editing

    func toggleGroup(_ id: String) {
        if let index = selectedGroupIDs.firstIndex(of: id) {
            selectedGroupIDs.remove(at: index)
        } else {
            selectedGroupIDs.append(id)
        }
    }

    /// The profile was fetched again (Reload or Reload Profile). Ignored once
    /// a Blueprint exists: the migration stays with what it created.
    func sourceDidChange(profile: ClassicProfile, report: EligibilityReport) {
        guard blueprintID == nil else { return }
        self.profile = profile
        self.report = report
    }

    // MARK: Stages

    /// Validates and builds locally, and checks for name clashes. Nothing is written.
    func runDryRun() async {
        await waitUntilReady()
        guard canRunDryRun else { return }
        await perform { [self] in
            let request = try await prepareRequest()
            let existing = try await pipeline.existingBlueprints()
            let groups = selectedGroups.map(\.name).joined(separator: ", ")
            let payloads = profile.document.payloadCount
            let devices = "\(deviceCountIsPartial ? "at least " : "")\(deviceCount) device\(deviceCount == 1 ? "" : "s")"
            var summary = "Would create “\(request.name)” (not deployed) with \(payloads) payload\(payloads == 1 ? "" : "s"), targeting \(groups): \(devices)."
            if !existing.isEmpty {
                summary += " A Blueprint with this name already exists (\(existing.map(\.id).joined(separator: ", ")))."
            }
            dryRunSummary = summary
            history.record(.dryRun, environment: environment, profile: profile, blueprintName: request.name,
                                     result: existing.isEmpty ? .success : .warning, message: summary)
        }
    }

    /// Creates the Blueprint without deploying, then reads it back and verifies it.
    func create() async {
        await waitUntilReady()
        guard canCreate else { return }
        await perform { [self] in
            let request = try await prepareRequest()
            let createdID: String
            do {
                createdID = try await pipeline.create()
            } catch let duplicate as DuplicateNameError {
                duplicates = duplicate.existing
                state = await pipeline.state
                return
            }
            blueprintID = createdID
            createdName = request.name
            persistSessionRecord()
            state = await pipeline.state
            var message = "Created, not deployed. Scope: \(selectedGroups.map(\.name).joined(separator: ", "))."
            let unlisted = profile.document.unrecognizedPayloadTypes
            if !unlisted.isEmpty {
                message += " The API accepted \(unlisted.joined(separator: ", ")), which the app’s payload-type registry doesn’t list; the registry may have grown."
            }
            history.record(.create, environment: environment, profile: profile, blueprintID: createdID, blueprintName: request.name,
                                     result: .success, message: message)
            try await verifyStage()
        }
    }

    func resolveDuplicate(_ resolution: DuplicateResolution) async {
        let found = duplicates ?? []
        duplicates = nil
        switch resolution {
        case .skip:
            history.record(.skipExisting, environment: environment, profile: profile, blueprintID: found.first?.id,
                                     blueprintName: blueprintName, result: .warning, message: "Skipped: a Blueprint with this name already exists.")
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
                                         blueprintName: existing.name, result: .success, message: "Using the existing Blueprint instead of creating one.")
                try await verifyStage()
            }
        }
    }

    /// Reads the Blueprint back again. While a deployment may still be
    /// running this only refreshes the check; it never makes the Blueprint
    /// deployable on top of it.
    func verify() async {
        await waitUntilReady()
        await perform { [self] in try await verifyStage() }
    }

    /// Deploys after the confirmation sheet, then polls until done or timed out.
    func deploy(_ confirmation: DeployConfirmation) async {
        await waitUntilReady()
        stopReportMonitor()
        await perform { [self] in
            // Recorded only once the pipeline accepts this confirmation; a
            // refused deploy sends nothing and leaves no "confirmed" line.
            try await pipeline.checkDeployable(confirmation: confirmation)
            let devices = "\(confirmation.deviceCount) device\(confirmation.deviceCount == 1 ? "" : "s")"
            history.record(.deploy, environment: environment, profile: profile, blueprintID: confirmation.blueprintID,
                                     blueprintName: confirmation.blueprintName, result: .success,
                                     message: "Confirmed by user for \(confirmation.groupNames.joined(separator: ", ")) (\(devices)).")
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

    /// Puts the backed-up scope back. The automatic cleanup is turned off for
    /// good, so no later refresh or relaunch unscopes the profile again.
    func restoreClassicScope() async {
        guard canRestoreScope, let backup = scopeBackup else { return }
        await perform { [self] in
            do {
                _ = try await ClassicScopeService.restore(backup, environment: environment, backups: scopeBackups)
                scopeBackup = nil
                scopeChangedBefore = true
                cleanupQueued = false
                unscopeAfterDeploy = false
                unscopeStatus = .restored(Date())
                history.record(.restoreClassicScope, environment: environment, profile: profile, blueprintID: blueprintID,
                               blueprintName: createdName, result: .success, message: "Restored the classic profile’s scope from the backup taken \(backup.createdAt.formatted()).")
            } catch {
                unscopeStatus = .failed(ErrorReport(error))
                history.record(.restoreClassicScope, environment: environment, profile: profile, blueprintID: blueprintID,
                               blueprintName: createdName, result: .failure, message: error.localizedDescription)
                throw error
            }
        }
    }

    /// Unscopes the classic profile. `automatic` (the opt-in cleanup) also
    /// requires the Blueprint's groups to cover the fresh classic scope.
    private func unscopeStage(automatic: Bool = false) async throws {
        guard !isClosed else { return }
        do {
            let result = try await ClassicScopeService.unscope(key: key, blueprintID: blueprintID,
                                                              environment: environment, backups: scopeBackups,
                                                              requiring: automatic ? scopeCoverage : nil)
            scopeChangedBefore = true
            showBackup(result.backup)
            history.record(.unscopeClassic, environment: environment, profile: profile, blueprintID: blueprintID, blueprintName: createdName,
                           result: .success, message: "Removed all scope targets from the classic profile (payloads untouched). Scope backup saved; restore is available.")
        } catch {
            // If the change reached Jamf Pro before the error (the read-back
            // failed, say), its backup is offered for Restore right away.
            if let backup = await scopeBackups.latest(key: key, environment: environment) {
                scopeBackup = backup
                scopeChangedBefore = true
            }
            unscopeStatus = .failed(ErrorReport(error))
            history.record(.unscopeClassic, environment: environment, profile: profile, blueprintID: blueprintID, blueprintName: createdName,
                           result: .failure, message: error.localizedDescription)
            throw error
        }
    }

    /// The user opted into cleanup, it can still run, and it hasn't run before.
    private var autoUnscopeRequested: Bool {
        unscopeAfterDeploy && canChangeClassicScope && scopeBackup == nil && !scopeChangedBefore && !isClosed
    }

    /// The cleanup will run once the deployment is clean: requested, and the
    /// Blueprint's groups cover the classic scope. The deploy confirmation reads
    /// this, so the sheet promises cleanup exactly when the session would run it.
    var autoUnscopeArmed: Bool {
        autoUnscopeRequested && uncoveredClassicTargets.isEmpty
    }

    /// Runs the opt-in auto-unscope after a deployment result, if (and only if)
    /// the Blueprint covers the classic scope and the deployment was clean.
    private func autoUnscopeIfRequested() async throws {
        guard autoUnscopeRequested else { return }
        let uncovered = uncoveredClassicTargets
        if !uncovered.isEmpty {
            holdBack(ClassicScopeService.uncoveredMessage(uncovered))
        } else if ClassicScopeService.deploymentAllowsUnscope(outcome) {
            try await unscopeStage(automatic: true)
        } else {
            let detail = deviceReport.map { "\($0.failed) failed, \($0.pending) pending" + ($0.succeeded == 0 ? ", none succeeded" : "") }
                ?? "no device report yet"
            unscopeStatus = .waiting("Not unscoped yet: \(detail). The report refreshes automatically and cleanup runs once every device succeeds.")
            recordDeferral("Auto-unscope deferred: \(detail). Watching the device report.", result: .warning)
        }
    }

    /// The automatic cleanup won't run by itself; says why, once in the history.
    private func holdBack(_ reason: String) {
        unscopeStatus = .heldBack(reason)
        recordDeferral(reason, result: .warning)
    }

    private func recordDeferral(_ message: String, result: MigrationResult) {
        guard message != recordedDeferral else { return }
        recordedDeferral = message
        history.record(.unscopeClassic, environment: environment, profile: profile, blueprintID: blueprintID, blueprintName: createdName,
                       result: result, message: message)
    }

    // MARK: Session persistence

    private var environmentKey: String { environment.environmentID ?? environment.displayName }

    /// Saves enough to re-attach this migration after a relaunch.
    private func persistSessionRecord() {
        guard let blueprintID else { return }
        let record = PersistedMigration(
            environmentKey: environmentKey,
            platform: platform,
            profileID: key.id,
            blueprintID: blueprintID,
            blueprintName: createdName ?? blueprintName,
            selectedGroupIDs: selectedGroupIDs,
            unscopeAfterDeploy: unscopeAfterDeploy,
            blueprintDescription: blueprintDescription
        )
        Task { [sessionStates] in
            do {
                try await sessionStates.save(record)
            } catch {
                lastError = ErrorReport(PipelineError(message: "This migration couldn’t be saved for the next launch: \(error.localizedDescription)"))
            }
        }
    }

    /// Re-attaches a Blueprint created in an earlier launch: rebuilds the request,
    /// adopts the Blueprint and verifies it. A 404 clears the stale record.
    private func restore(from record: PersistedMigration) async {
        blueprintName = record.blueprintName
        if let description = record.blueprintDescription { blueprintDescription = description }
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
                if let error = error as? JamfPlatform.APIError, error.status == 404 {
                    try? await sessionStates.remove(environmentKey: environmentKey, key: key)
                    blueprintID = nil
                    createdName = nil
                    state = .fetched
                    throw PipelineError(message: "The Blueprint created in an earlier session no longer exists on the server. The saved reference was removed; create it again if needed.")
                }
                throw error
            }
        }
    }

    // MARK: Device report monitor

    /// Refreshes the device report in the background until no device is pending,
    /// then runs the opt-in classic cleanup. A time-out or error says so.
    private func startReportMonitor() {
        guard let blueprintID, !isClosed else { return }
        reportMonitor?.cancel()
        reportMonitorActive = true
        reportMonitor = Task { [pipeline] in
            let result = await Result {
                try await pipeline.monitorReport(id: blueprintID) { [weak self] update in
                    await MainActor.run {
                        self?.deviceReport = update
                        self?.outcome = .succeeded(update)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            reportMonitorActive = false
            switch result {
            case let .success(final) where final?.pending == 0:
                await reportBecameFinal(final)
            case let .success(final):
                if let final { deviceReport = final }
                if autoUnscopeRequested {
                    holdBack("Stopped watching the device report after 30 minutes with devices still pending. Click Refresh Status to check again; cleanup runs only after a clean report.")
                }
            case let .failure(error):
                if autoUnscopeRequested {
                    holdBack("The device report couldn’t be refreshed (\(error.localizedDescription)). Click Refresh Status to check again; cleanup runs only after a clean report.")
                }
            }
        }
    }

    private func stopReportMonitor() {
        reportMonitor?.cancel()
        reportMonitor = nil
        reportMonitorActive = false
    }

    /// The device report stopped changing (or a queued cleanup came due).
    /// Internal for tests; the app calls it from the report watch.
    func reportBecameFinal(_ report: JamfPlatform.BlueprintReport?) async {
        if let report {
            deviceReport = report
            outcome = .succeeded(report)
            state = .deployed(report)
        }
        guard autoUnscopeRequested else { return }
        // Another action is running: the cleanup waits for it instead of being dropped.
        if isBusy {
            cleanupQueued = true
            return
        }
        await perform { [self] in try await autoUnscopeIfRequested() }
    }

    // MARK: Helpers

    private func finish(_ result: DeploymentOutcome) async {
        outcome = result
        state = await pipeline.state
        switch result {
        case let .succeeded(report):
            deviceReport = report
            // Refresh Status reads the same result again; it's written once.
            if recordedReport != .some(report) {
                recordedReport = .some(report)
                let counts = report.map { "succeeded \($0.succeeded), failed \($0.failed), pending \($0.pending)" } ?? "report unavailable"
                history.record(.deploymentResult, environment: environment, profile: profile, blueprintID: blueprintID,
                                         blueprintName: createdName, result: (report?.failed ?? 0) > 0 ? .warning : .success,
                                         message: "Deployed. Devices: \(counts).")
            }
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

    /// Starts the pipeline from the profile and builds the request. Only before
    /// a Blueprint exists: loading starts the pipeline over.
    private func prepareRequest() async throws -> BlueprintRequest {
        guard blueprintID == nil else {
            throw PipelineError(message: "This migration has already created its Blueprint.")
        }
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
        // An already-deployed Blueprint (restored session, or adopted duplicate) resumes
        // at the deployed stage, with the report refreshing until it is clean.
        if let detail = readBack, detail.overview.deploymentState?.isDeployedSuccessfully == true {
            let report = await environment.blueprints.reportIfAny(id: detail.id)
            deviceReport = report
            outcome = .succeeded(report)
            state = .deployed(report)
            if (report?.pending ?? 1) > 0 {
                startReportMonitor()
            } else {
                // Runs after this action ends (it queues while busy).
                Task { await reportBecameFinal(report) }
            }
        }
        let summary = result.passed
            ? FidelityReport.allMatchSentence
                + (result.caseChanges.isEmpty ? "" : " \(result.caseChanges.count) key casing change\(result.caseChanges.count == 1 ? "" : "s") to review.")
            : "\(result.mismatches.count) mismatch\(result.mismatches.count == 1 ? "" : "es"): " + result.mismatches.prefix(3).map(\.field).joined(separator: "; ")
        history.record(.verify, environment: environment, profile: profile, blueprintID: blueprintID, blueprintName: createdName,
                                 result: result.passed ? (result.caseChanges.isEmpty ? .success : .warning) : .failure, message: summary)
    }

    private func perform(_ work: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        do {
            try await work()
        } catch {
            lastError = ErrorReport(error)
            state = await pipeline.state
        }
        isBusy = false
        if cleanupQueued {
            cleanupQueued = false
            await reportBecameFinal(nil)
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

    /// Payload types outside the app's known registry (neither supported nor blocked).
    nonisolated var unrecognizedPayloadTypes: [String] {
        let types = (try? get())?.payloads.compactMap(\.type) ?? []
        var seen = Set<String>()
        return types.filter {
            !EligibilityChecker.supportedPayloadTypes.contains($0)
                && !EligibilityChecker.blockedPayloadTypes.contains($0)
                && seen.insert($0).inserted
        }
    }
}
