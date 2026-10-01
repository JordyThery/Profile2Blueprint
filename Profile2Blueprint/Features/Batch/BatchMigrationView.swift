import SwiftUI

/// Batch migration: a per-item summary, sequential create + verify, and one deploy
/// confirmation that lists every target.
struct BatchMigrationView: View {
    let workspace: Workspace
    let profileIDs: [Int]

    @Environment(\.dismiss) private var dismiss
    @State private var dryRun = true
    @State private var running = false
    @State private var showingDeploy = false
    @State private var progressText: String?

    private var sessions: [MigrationSession] {
        profileIDs.compactMap { workspace.session(for: $0) }
    }

    private var notLoaded: Int { profileIDs.count - sessions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Batch migration").font(.title2.weight(.semibold))
                Spacer()
                Text(workspace.environment.displayName).foregroundStyle(workspace.environment.isDemo ? Color.secondary : Color.orange)
            }
            Text("Each profile is created as its own blueprint (not deployed) and verified. Items that need attention are skipped unless you include them, and blocked items are always skipped. Group choices come from each profile's Scope tab.")
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
                    .help(session.effectiveReport.status == .needsAttention ? "Including acknowledges this item's warnings" : "")
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
                    Text(session.selectedGroups.isEmpty ? "None" : session.selectedGroups.map(\.name).joined(separator: ", "))
                        .foregroundStyle(session.selectedGroups.isEmpty ? .orange : .primary)
                }
                TableColumn("Devices") { session in Text("\(session.deviceCount)").monospacedDigit() }
                    .width(60)
                TableColumn("Status") { session in statusText(session) }
                    .width(min: 160, ideal: 220)
            })
            .frame(minHeight: 260)

            if notLoaded > 0 {
                Label("\(notLoaded) selected profile(s) are still loading or failed to load and are not included.", systemImage: "hourglass")
                    .foregroundStyle(.orange)
            }

            Toggle("Dry run (write nothing)", isOn: $dryRun).disabled(running)

            HStack {
                if let progressText { Text(progressText).font(.callout) }
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                Button(dryRun ? "Dry Run \(eligible.count)" : "Create \(eligible.count) (Not Deployed)") {
                    Task { await run() }
                }
                .disabled(running || eligible.isEmpty)
                Button("Deploy \(deployable.count) Verified…") { showingDeploy = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || deployable.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 520)
        .sheet(isPresented: $showingDeploy) {
            DeployConfirmationSheet(
                items: deployable.map { session in
                    DeployItem(blueprintID: session.blueprintID ?? "", blueprintName: session.createdName ?? session.blueprintName,
                               sourceName: session.profile.name, groups: session.selectedGroups,
                               warnings: session.fidelity?.caseChanges.count ?? 0)
                },
                environmentName: workspace.environment.displayName,
                isDemo: workspace.environment.isDemo
            ) { confirmations in
                Task { await deploy(confirmations) }
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

    private func run() async {
        running = true
        defer { running = false; progressText = nil }
        let items = eligible
        for (index, session) in items.enumerated() {
            progressText = "\(dryRun ? "Checking" : "Creating") \(index + 1) of \(items.count): \(session.profile.name)"
            if dryRun {
                await session.runDryRun()
            } else {
                session.dryRun = false
                await session.create()
            }
        }
    }

    private func deploy(_ confirmations: [DeployConfirmation]) async {
        running = true
        defer { running = false; progressText = nil }
        for (index, confirmation) in confirmations.enumerated() {
            guard let session = sessions.first(where: { $0.blueprintID == confirmation.blueprintID }) else { continue }
            progressText = "Deploying \(index + 1) of \(confirmations.count): \(confirmation.blueprintName)"
            await session.deploy(confirmation)
        }
    }

    @ViewBuilder
    private func statusText(_ session: MigrationSession) -> some View {
        if session.isBusy {
            HStack { ProgressView().controlSize(.mini); Text("Working…") }
        } else if let error = session.lastError {
            Text(error.title).foregroundStyle(.red).lineLimit(2).help(error.title)
        } else if session.duplicates != nil {
            Text("Name exists. Resolve it in the profile's Migrate tab.").foregroundStyle(.orange)
        } else if case let .deployed(report) = session.state {
            Text("Deployed" + (report.map { " · \($0.succeeded)/\($0.total) ok" } ?? "")).foregroundStyle(.green)
        } else if case .deploying = session.state {
            Text(session.deployment?.displayText ?? "Deploying…")
        } else if let fidelity = session.fidelity {
            Text(fidelity.passed ? "Created · verified" : "Created · \(fidelity.mismatches.count) mismatch(es)")
                .foregroundStyle(fidelity.passed ? .green : .red)
        } else if session.effectiveReport.status == .blocked {
            Text(session.effectiveReport.reasons.first?.title ?? "Blocked").foregroundStyle(.red)
        } else if !included(session) {
            Text("Skipped: needs attention").foregroundStyle(.secondary)
        } else if session.selectedGroupIDs.isEmpty {
            Text("Skipped: no target group").foregroundStyle(.orange)
        } else if session.dryRunSummary != nil {
            Text("Dry run OK").foregroundStyle(.secondary)
        } else {
            Text("Ready").foregroundStyle(.secondary)
        }
    }
}
