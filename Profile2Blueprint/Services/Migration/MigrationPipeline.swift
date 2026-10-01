import Foundation
import OSLog

/// The migration state machine:
/// `idle → fetched → validated → built → created → verified → deploying → deployed / failed`.
nonisolated enum MigrationState: Hashable, Sendable {
    case idle
    case fetched
    case validated
    case built
    case created(blueprintID: String)
    case verified(passed: Bool)
    case deploying(DeploymentState?)
    case deployed(BlueprintReport?)
    case failed(stage: String, ErrorReport)
}

/// Proof that a person confirmed deploying one specific blueprint. Only the deploy
/// confirmation sheet creates these; the pipeline refuses to deploy without one
/// that names the blueprint it created.
nonisolated struct DeployConfirmation: Hashable, Sendable {
    let blueprintID: String
    let blueprintName: String
    let groupNames: [String]
    let deviceCount: Int
    let confirmedAt: Date
}

nonisolated enum DeploymentOutcome: Hashable, Sendable {
    case succeeded(BlueprintReport?)
    case failed(DeploymentState)
    case timedOut(DeploymentState?)
}

nonisolated struct PipelineError: Error, LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// A same-named blueprint already exists. Carries the matches so callers can offer
/// rename / skip / open-existing instead of a plain failure.
nonisolated struct DuplicateNameError: Error, LocalizedError, Sendable {
    var existing: [BlueprintOverview]
    var errorDescription: String? {
        "A blueprint with this name already exists. Rename, skip, or open the existing one."
    }
}

/// Bounded polling: starts at `initialInterval`, grows ×1.5 up to `maxInterval`, gives up at `timeout`.
/// The report fields pace the slower post-deploy device-report refresh.
nonisolated struct PollingPolicy: Sendable {
    var initialInterval: Duration = .seconds(2)
    var maxInterval: Duration = .seconds(10)
    var timeout: Duration = .seconds(300)
    var reportInterval: Duration = .seconds(20)
    var reportTimeout: Duration = .seconds(1_800)
}

/// Runs the staged migration of one classic profile. Each stage checks it is
/// called in order, so the UI can't skip validation, verification or confirmation.
actor MigrationPipeline {
    private let classic: any ClassicAPI
    private let blueprints: any BlueprintsAPI
    private let polling: PollingPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private let clock = ContinuousClock()

    private(set) var state: MigrationState = .idle
    private(set) var profile: ClassicProfile?
    private(set) var report: EligibilityReport?
    private(set) var request: BlueprintRequest?
    private(set) var blueprintID: String?
    private(set) var readBack: BlueprintDetail?
    private(set) var fidelity: FidelityReport?

    init(
        classic: any ClassicAPI,
        blueprints: any BlueprintsAPI,
        polling: PollingPolicy = PollingPolicy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.classic = classic
        self.blueprints = blueprints
        self.polling = polling
        self.sleep = sleep
    }

    // MARK: Stages

    /// 1. Read the classic profile (GET only).
    func fetch(profileID: Int) async throws -> ClassicProfile {
        do {
            let fetched = try await classic.profile(id: profileID)
            reset()
            profile = fetched
            state = .fetched
            return fetched
        } catch {
            state = .failed(stage: "fetch", ErrorReport(error))
            throw error
        }
    }

    /// Adopts an already fetched profile (e.g. from the list cache).
    func load(_ fetched: ClassicProfile) {
        reset()
        profile = fetched
        state = .fetched
    }

    /// 2. Validate eligibility.
    func validate(platformGroups: [PlatformGroup]) throws -> EligibilityReport {
        guard let profile else { throw PipelineError(message: "Fetch the profile before validating.") }
        let result = EligibilityChecker.check(profile, platformGroups: platformGroups)
        report = result
        state = .validated
        return result
    }

    /// 3+4+5. Distill, map scope and build the request body.
    func build(name: String, description: String?, deviceGroupIDs: [String], acknowledgedWarnings: Bool) throws -> BlueprintRequest {
        guard let profile, let report else { throw PipelineError(message: "Validate the profile before building.") }
        guard report.status != .blocked else {
            throw PipelineError(message: "This profile is blocked: " + report.reasons.filter { $0.severity == .blocker }.map(\.title).joined(separator: ", "))
        }
        guard report.status == .ready || acknowledgedWarnings else {
            throw PipelineError(message: "Review and acknowledge the warnings before building.")
        }
        let built = try BlueprintBuilder.build(profile: profile, name: name, description: description, deviceGroupIDs: deviceGroupIDs)
        request = built
        blueprintID = nil
        readBack = nil
        fidelity = nil
        state = .built
        return built
    }

    /// Existing blueprints with the same name (idempotency check).
    func existingBlueprints() async throws -> [BlueprintOverview] {
        guard let request else { throw PipelineError(message: "Build the blueprint first.") }
        return try await blueprints.blueprints(named: request.name)
    }

    /// 6. Create the blueprint, not deployed. Throws `DuplicateNameError` — leaving the
    /// pipeline at `built` so the caller can rename and retry — when the name is taken.
    func create() async throws -> BlueprintCreated {
        guard let request, state == .built else { throw PipelineError(message: "Build the blueprint before creating it.") }
        do {
            let existing = try await blueprints.blueprints(named: request.name)
            if !existing.isEmpty { throw DuplicateNameError(existing: existing) }
            let created = try await blueprints.create(request)
            blueprintID = created.id
            state = .created(blueprintID: created.id)
            Log.app.info("Created blueprint \(created.id, privacy: .public) (not deployed)")
            return created
        } catch let duplicate as DuplicateNameError {
            throw duplicate
        } catch {
            state = .failed(stage: "create", ErrorReport(error))
            throw error
        }
    }

    /// Uses an existing blueprint instead of creating one ("open existing").
    func adoptExisting(id: String) throws {
        guard request != nil else { throw PipelineError(message: "Build the blueprint first.") }
        blueprintID = id
        state = .created(blueprintID: id)
    }

    /// 7. Read back and compare against the source.
    func verify() async throws -> FidelityReport {
        guard let blueprintID, let profile, let request else { throw PipelineError(message: "Create the blueprint before verifying.") }
        guard case let .success(document) = profile.document else { throw PipelineError(message: "The source profile can't be parsed.") }
        do {
            let detail = try await blueprints.blueprint(id: blueprintID)
            let result = FidelityVerifier.verify(document: document, expectedGroupIDs: request.deviceGroupIDs, detail: detail)
            readBack = detail
            fidelity = result
            state = .verified(passed: result.passed)
            return result
        } catch {
            state = .failed(stage: "verify", ErrorReport(error))
            throw error
        }
    }

    /// 8. Deploy, only with a confirmation for this exact blueprint, then poll.
    func deploy(
        confirmation: DeployConfirmation,
        onProgress: @Sendable (DeploymentState?) async -> Void = { _ in }
    ) async throws -> DeploymentOutcome {
        guard let blueprintID, case let .verified(passed) = state else {
            throw PipelineError(message: "Verify the blueprint before deploying.")
        }
        guard confirmation.blueprintID == blueprintID else {
            throw PipelineError(message: "The confirmation is for a different blueprint. Nothing was deployed.")
        }
        guard passed else {
            throw PipelineError(message: "Verification found mismatches. Deploying was refused.")
        }

        do {
            state = .deploying(nil)
            try await blueprints.deploy(id: blueprintID)
            Log.app.info("Deploy accepted for blueprint \(blueprintID, privacy: .public)")
            return try await monitor(id: blueprintID, onProgress: onProgress)
        } catch {
            state = .failed(stage: "deploy", ErrorReport(error))
            throw error
        }
    }

    /// Polls deployment state with bounded backoff, then fetches the device report.
    /// Sets the terminal pipeline state; a timeout leaves `.deploying` so the UI can re-check.
    func monitor(id: String, onProgress: @Sendable (DeploymentState?) async -> Void = { _ in }) async throws -> DeploymentOutcome {
        let deadline = clock.now.advanced(by: polling.timeout)
        var interval = polling.initialInterval
        var last: DeploymentState?

        while clock.now < deadline {
            try Task.checkCancellation()
            let detail = try await blueprints.blueprint(id: id)
            last = detail.deploymentState
            state = .deploying(last)
            await onProgress(last)

            if detail.deploymentState.isDeployedSuccessfully {
                let report = try? await blueprints.report(id: id)
                state = .deployed(report)
                return .succeeded(report)
            }
            if detail.deploymentState.hasFailed {
                state = .failed(stage: "deploy", ErrorReport(PipelineError(message: "Deployment failed: \(detail.deploymentState.displayText)")))
                return .failed(detail.deploymentState)
            }
            try await sleep(interval)
            interval = min(interval * 1.5, polling.maxInterval)
        }
        return .timedOut(last)
    }

    /// Refreshes the device report until no device is pending, the timeout passes, or
    /// the task is cancelled. Returns the last report seen (the caller judges cleanliness).
    func monitorReport(
        id: String,
        onUpdate: @Sendable (BlueprintReport) async -> Void = { _ in }
    ) async throws -> BlueprintReport? {
        let deadline = clock.now.advanced(by: polling.reportTimeout)
        var last: BlueprintReport?

        while clock.now < deadline {
            try Task.checkCancellation()
            let report = try await blueprints.report(id: id)
            last = report
            await onUpdate(report)
            if report.pending == 0 { return report }
            try await sleep(polling.reportInterval)
        }
        return last
    }

    private func reset() {
        profile = nil
        report = nil
        request = nil
        blueprintID = nil
        readBack = nil
        fidelity = nil
        state = .idle
    }
}
