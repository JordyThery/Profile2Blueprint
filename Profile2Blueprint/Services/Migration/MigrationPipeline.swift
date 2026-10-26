import Foundation
import JTKit
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
    case deploying(JamfPlatform.DeploymentStatus?)
    case deployed(JamfPlatform.BlueprintReport?)
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
    case succeeded(JamfPlatform.BlueprintReport?)
    case failed(JamfPlatform.DeploymentStatus)
    case timedOut(JamfPlatform.DeploymentStatus?)
}

nonisolated struct PipelineError: Error, LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// A same-named blueprint already exists. Carries the matches so callers can offer
/// rename / skip / open-existing instead of a plain failure.
nonisolated struct DuplicateNameError: Error, LocalizedError, Sendable {
    var existing: [JamfPlatform.BlueprintOverview]
    var errorDescription: String? {
        "A blueprint with this name already exists. Rename, skip, or open the existing one."
    }
}

/// How long the app waits, on JTKit's waiting (`JamfPlatform.Poller`). The
/// deployment follows JTKit's standard (2 s growing to 10 s, at most 5 minutes);
/// the device report is the app's own setting: every 20 s for up to 30 minutes,
/// because devices pick up a deployment much more slowly than Jamf starts it.
nonisolated struct WatchPolicy: Sendable {
    var deployment = JamfPlatform.PollingPolicy.standard
    var report = Self.reportWatch

    static let reportWatch = JamfPlatform.PollingPolicy(
        firstInterval: .seconds(20), growth: 1, longestInterval: .seconds(20), timeLimit: .seconds(1_800))
}

/// Runs the staged migration of one classic profile. Each stage checks it is
/// called in order, so the UI can't skip validation, verification or confirmation.
actor MigrationPipeline {
    private let classic: any ClassicAPI
    private let blueprints: JamfPlatform.Blueprints
    private let watch: WatchPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    /// When the Blueprint's last deployment started before this session's
    /// deploy, so the watch can tell the new deployment from the previous one.
    private var previousDeploymentStart: String?

    private(set) var state: MigrationState = .idle
    private(set) var profile: ClassicProfile?
    private(set) var report: EligibilityReport?
    private(set) var request: BlueprintRequest?
    private(set) var blueprintID: String?
    private(set) var readBack: JamfPlatform.BlueprintDetail?
    private(set) var fidelity: FidelityReport?

    init(
        classic: any ClassicAPI,
        blueprints: JamfPlatform.Blueprints,
        watch: WatchPolicy = WatchPolicy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.classic = classic
        self.blueprints = blueprints
        self.watch = watch
        self.sleep = sleep
    }

    // MARK: Stages

    /// 1. Read the classic profile (GET only).
    func fetch(key: ProfileKey) async throws -> ClassicProfile {
        do {
            let fetched = try await classic.profile(key: key)
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
    func validate(platformGroups: [JamfPlatform.DeviceGroup]) throws -> EligibilityReport {
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
    func existingBlueprints() async throws -> [JamfPlatform.BlueprintOverview] {
        guard let request else { throw PipelineError(message: "Build the blueprint first.") }
        return try await blueprints.blueprints(named: request.name)
    }

    /// 6. Create the blueprint, not deployed. Throws `DuplicateNameError` — leaving the
    /// pipeline at `built` so the caller can rename and retry — when the name is taken.
    /// Returns the new Blueprint's ID.
    func create() async throws -> String {
        guard let request, state == .built else { throw PipelineError(message: "Build the blueprint before creating it.") }
        do {
            let existing = try await blueprints.blueprints(named: request.name)
            if !existing.isEmpty { throw DuplicateNameError(existing: existing) }
            let id = try await blueprints.create(name: request.name, description: request.description,
                                                 deviceGroups: request.deviceGroupIDs, steps: request.steps)
            blueprintID = id
            state = .created(blueprintID: id)
            Log.app.info("Created blueprint \(id, privacy: .public) (not deployed)")
            return id
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
            let detail = try await blueprints.detail(id: blueprintID)
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
        onProgress: @Sendable (JamfPlatform.DeploymentStatus) async -> Void = { _ in }
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
            previousDeploymentStart = try await blueprints.startDeployment(id: blueprintID)
            Log.app.info("Deploy accepted for blueprint \(blueprintID, privacy: .public)")
            return try await monitor(id: blueprintID, onProgress: onProgress)
        } catch {
            state = .failed(stage: "deploy", ErrorReport(error))
            throw error
        }
    }

    /// Follows the deployment this session started (JTKit's deploy watch), then
    /// reads the device report. Sets the terminal pipeline state; a timeout leaves
    /// `.deploying` so the UI can re-check.
    func monitor(id: String, onProgress: @Sendable (JamfPlatform.DeploymentStatus) async -> Void = { _ in }) async throws -> DeploymentOutcome {
        let outcome = try await blueprints.watchDeployment(
            id: id,
            previousStart: previousDeploymentStart,
            poller: JamfPlatform.Poller(policy: watch.deployment, sleep: sleep)
        ) { status in
            await self.noteProgress(status)
            await onProgress(status)
        }
        switch outcome {
        case let .finished(status) where status.didSucceed:
            let report = await blueprints.reportIfAny(id: id)
            state = .deployed(report)
            return .succeeded(report)
        case let .finished(status):
            state = .failed(stage: "deploy", ErrorReport(PipelineError(message: "Deployment failed: \(status.displayText)")))
            return .failed(status)
        case let .timedOut(last):
            return .timedOut(last)
        }
    }

    private func noteProgress(_ status: JamfPlatform.DeploymentStatus) {
        state = .deploying(status)
    }

    /// Refreshes the device report until no device is pending, the time limit
    /// (`WatchPolicy.report`) passes, or the task is cancelled. Returns the last
    /// report seen (the caller judges cleanliness). No report yet is checked again.
    func monitorReport(
        id: String,
        onUpdate: @Sendable (JamfPlatform.BlueprintReport) async -> Void = { _ in }
    ) async throws -> JamfPlatform.BlueprintReport? {
        let blueprints = blueprints
        let outcome = try await JamfPlatform.Poller(policy: watch.report, sleep: sleep).poll(
            check: { try await blueprints.report(id: id) },
            isDone: { $0?.pending == 0 },
            progress: { report in
                if let report { await onUpdate(report) }
            }
        )
        return outcome.value ?? nil
    }

    private func reset() {
        profile = nil
        report = nil
        request = nil
        blueprintID = nil
        readBack = nil
        fidelity = nil
        previousDeploymentStart = nil
        state = .idle
    }
}
