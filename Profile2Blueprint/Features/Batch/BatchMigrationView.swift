import SwiftUI
import JTKit

/// Batch migration: a per-item summary, sequential create + verify, and one deploy
/// confirmation that lists every target.
struct BatchMigrationView: View {
    let workspace: Workspace
    let profileKeys: [ProfileKey]

    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    /// The deploy confirmation, shown in place of the list (not as a second sheet).
    @State private var confirmingDeploy = false
    /// Stop was pressed: the run ends after the current item.
    @State private var stopRequested = false
    @State private var progressText: String?

    private var sessions: [MigrationSession] {
        profileKeys.compactMap { workspace.session(for: $0) }
    }

    private var notLoaded: Int { profileKeys.count - sessions.count }

    var body: some View {
        Group {
            if confirmingDeploy {
                DeployConfirmationView(
                    items: deployable.compactMap(\.deployItem),
                    environmentName: workspace.environment.displayName,
                    isDemo: workspace.environment.isDemo,
                    onCancel: { confirmingDeploy = false },
                    onConfirm: { confirmations in
                        confirmingDeploy = false
                        Task { await deploy(confirmations) }
                    }
                )
            } else {
                list
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 520)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Batch Migration").font(.title2.weight(.semibold))
                Spacer()
                Label(workspace.environment.displayName,
                      systemImage: workspace.environment.isDemo ? "testtube.2" : "bolt.horizontal.circle.fill")
                    .labelStyle(.tintedIcon(workspace.environment.isDemo ? Color.secondary : Color.accentColor))
            }
            Text("Each profile is created as its own Blueprint (not deployed) and verified. Items that need attention are skipped unless you include them, and blocked items are always skipped. Group choices come from each profile’s Scope tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(sessions, columns: {
                TableColumn("Include") { session in
                    Toggle("Include \(session.profile.name)", isOn: Binding(
                        get: { included(session) },
                        set: { session.acknowledgedWarnings = $0 }
                    ))
                    .labelsHidden()
                    .disabled(session.effectiveReport.status != .needsAttention || session.blueprintID != nil || running)
                    .help(session.effectiveReport.status == .needsAttention ? Text("Including acknowledges this item’s warnings") : Text(verbatim: ""))
                }
                .width(50)
                TableColumn("Profile") { session in
                    VStack(alignment: .leading) {
                        Text(session.profile.name)
                        Text(session.blueprintName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Eligibility") { session in EligibilityBadge(status: session.effectiveReport.status) }
                    .width(min: 110, ideal: 130)
                TableColumn("Target") { session in
                    if session.selectedGroups.isEmpty {
                        WarningLabel("None")
                    } else {
                        Text(session.selectedGroups.map(\.name).joined(separator: ", "))
                    }
                }
                TableColumn("Devices") { session in Text("\(session.deviceCount)").monospacedDigit() }
                    .width(60)
                TableColumn("Status") { session in statusText(session) }
                    .width(min: 160, ideal: 220)
            })
            .frame(minHeight: 260)

            if notLoaded > 0 {
                Label("^[\(notLoaded) selected profile](inflect: true) still loading or failed to load — not included.", systemImage: "hourglass")
                    .labelStyle(.tintedIcon(.orange))
            }

            RetryWaitBanner(waits: workspace.environment.waits)

            HStack {
                if let progressText { Text(progressText).font(.callout) }
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if running {
                    // Ends the run after the current item, and any wait before a retry now.
                    Button("Stop") {
                        stopRequested = true
                        workspace.environment.waits?.cancelAll()
                    }
                    .disabled(stopRequested)
                    .help("Stop after the current item; nothing more is created or deployed")
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Button("Dry Run \(eligible.count)") { Task { await run(dryRun: true) } }
                    .disabled(running || eligible.isEmpty)
                    .help("Validate each item and check for a Blueprint with the same name. Writes nothing.")
                Button("Create \(eligible.count) (Not Deployed)") { Task { await run(dryRun: false) } }
                    .disabled(running || eligible.isEmpty)
                Button("Deploy \(deployable.count) Verified…") { confirmingDeploy = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || deployable.isEmpty)
            }
        }
    }

    // MARK: Logic

    private func included(_ session: MigrationSession) -> Bool {
        switch session.effectiveReport.status {
        case .ready: true
        case .needsAttention: session.acknowledgedWarnings
        case .blocked: false
        }
    }

    /// Items that will be processed by the next dry run / create.
    private var eligible: [MigrationSession] {
        sessions.filter { included($0) && $0.blueprintID == nil && !$0.selectedGroupIDs.isEmpty && (try? $0.preview.get()) != nil }
    }

    private var deployable: [MigrationSession] {
        sessions.filter(\.canDeploy)
    }

    private func run(dryRun: Bool) async {
        running = true
        workspace.batchRunning = true
        stopRequested = false
        defer { running = false; workspace.batchRunning = false; progressText = nil }
        await BatchMigration.run(eligible, dryRun: dryRun, shouldStop: { stopRequested }) { progressText = $0 }
    }

    private func deploy(_ confirmations: [DeployConfirmation]) async {
        running = true
        workspace.batchRunning = true
        stopRequested = false
        defer { running = false; workspace.batchRunning = false; progressText = nil }
        await BatchMigration.deploy(confirmations, sessions: sessions, shouldStop: { stopRequested }) { progressText = $0 }
    }

    @ViewBuilder
    private func statusText(_ session: MigrationSession) -> some View {
        if session.isBusy {
            HStack { ProgressView().controlSize(.mini); Text("Working…") }
        } else if let error = session.lastError {
            Label(error.title, systemImage: "xmark.octagon.fill").labelStyle(.tintedIcon(.red)).lineLimit(2).help(error.title)
        } else if session.duplicates != nil {
            WarningLabel("Name exists. Resolve it in the profile’s Migrate tab.")
        } else if case let .deployed(report) = session.state {
            Label("Deployed" + (report.map { " · \($0.succeeded)/\($0.total) ok" } ?? ""), systemImage: "checkmark.circle.fill").labelStyle(.tintedIcon(.green))
        } else if case .deploying = session.state {
            Text(session.deployment?.displayText ?? "Deploying…")
        } else if let fidelity = session.fidelity {
            Label(fidelity.passed ? "Created · verified" : "Created · ^[\(fidelity.mismatches.count) mismatch](inflect: true)",
                  systemImage: fidelity.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .labelStyle(.tintedIcon(fidelity.passed ? .green : .red))
        } else if session.effectiveReport.status == .blocked {
            Label(session.effectiveReport.reasons.first?.title ?? "Blocked", systemImage: "xmark.octagon.fill").labelStyle(.tintedIcon(.red))
        } else if !included(session) {
            Text("Skipped: needs attention").foregroundStyle(.secondary)
        } else if session.selectedGroupIDs.isEmpty {
            WarningLabel("Skipped: no target group")
        } else if session.dryRunSummary != nil {
            Text("Dry run OK").foregroundStyle(.secondary)
        } else {
            Text("Ready").foregroundStyle(.secondary)
        }
    }
}

/// The batch's two loops. One item's failure, refusal or name clash is left
/// on that item (its status column) and never stops the others.
enum BatchMigration {
    /// - Parameter shouldStop: asked before each item; true ends the run there.
    static func run(_ sessions: [MigrationSession], dryRun: Bool, shouldStop: () -> Bool = { false },
                    progress: (String) -> Void = { _ in }) async {
        for (index, session) in sessions.enumerated() {
            if shouldStop() { return }
            progress("\(dryRun ? "Checking" : "Creating") \(index + 1) of \(sessions.count): \(session.profile.name)")
            if dryRun {
                await session.runDryRun()
            } else {
                await session.create()
            }
        }
    }

    /// Each confirmation goes to the session that created its Blueprint, and only there.
    static func deploy(_ confirmations: [DeployConfirmation], sessions: [MigrationSession],
                       shouldStop: () -> Bool = { false }, progress: (String) -> Void = { _ in }) async {
        for (index, confirmation) in confirmations.enumerated() {
            if shouldStop() { return }
            guard let session = sessions.first(where: { $0.blueprintID == confirmation.blueprintID }) else { continue }
            progress("Deploying \(index + 1) of \(confirmations.count): \(confirmation.blueprintName)")
            await session.deploy(confirmation)
        }
    }
}
