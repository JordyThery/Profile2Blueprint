import SwiftUI
import JTKit

/// Review & create → Verify → Deploy, with an explicit confirmation before deploy.
struct MigrateTab: View {
    let workspace: Workspace
    @Bindable var session: MigrationSession
    @State private var showingDeploySheet = false
    @State private var confirmingUnscope = false
    @State private var confirmingRestore = false

    private var environment: MigrationEnvironment { workspace.environment }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StepIndicator(state: session.state, hasBlueprint: session.blueprintID != nil, fidelity: session.fidelity,
                              cleanupDone: session.scopeBackup != nil)
                RetryWaitBanner(waits: environment.waits)
                environmentBanner
                review
                if let duplicates = session.duplicates {
                    duplicatePrompt(duplicates)
                }
                if let error = session.lastError {
                    GroupBox { APIErrorView(report: error).frame(maxWidth: .infinity, alignment: .leading).padding(4) }
                }
                if session.blueprintID != nil {
                    verifySection
                    deploySection
                    cleanupSection
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingDeploySheet) {
            if let item = session.deployItem {
                DeployConfirmationSheet(
                    items: [item],
                    environmentName: environment.displayName,
                    isDemo: environment.isDemo
                ) { confirmations in
                    if let confirmation = confirmations.first {
                        Task { await session.deploy(confirmation) }
                    }
                }
            }
        }
    }

    // MARK: Sections

    private var environmentBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: environment.isDemo ? "testtube.2" : "bolt.horizontal.circle.fill")
                .foregroundStyle(environment.isDemo ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            Text(environment.isDemo
                 ? "\(DemoMode.title): nothing is sent to Jamf."
                 : "Live tenant “\(environment.displayName)”: create and deploy change this environment.")
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(environment.isDemo ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(Color.accentColor.opacity(0.1)),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var review: some View {
        GroupBox("1 · Review & create") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    MetadataRow(label: "Source", value: "\(session.profile.name) (#\(session.profile.id)) — left untouched")
                    MetadataRow(label: "Blueprint", value: session.blueprintName)
                    MetadataRow(label: "Payloads", value: "\(session.profile.document.payloadCount)")
                    MetadataRow(label: "Target groups", value: session.selectedGroups.map { "\($0.name) (\($0.memberCountShort))" }.joined(separator: ", "))
                    MetadataRow(label: "Devices", value: session.selectedGroups.isEmpty ? "" : "\(session.selectedGroups.count > 1 ? "up to " : "")\(session.deviceCount)")
                    GridRow {
                        Text("Eligibility").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        EligibilityBadge(status: session.effectiveReport.status)
                    }
                }

                switch session.effectiveReport.status {
                case .blocked:
                    FindingsList(findings: session.effectiveReport.reasons.filter { $0.severity == .blocker })
                    Text("This profile can’t be migrated as a 1:1 legacy-profile Blueprint.").foregroundStyle(.secondary)
                case .needsAttention:
                    FindingsList(findings: session.effectiveReport.reasons)
                    Toggle(isOn: $session.acknowledgedWarnings) {
                        Text("I understand that the transform may not be seamless: the DDM profile could be rejected, or conflict with the classic profile that is still installed. Continue anyway.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(session.blueprintID != nil)
                case .ready:
                    Label(session.report.status == .ready
                          ? "All automated checks pass."
                          : "All automated checks pass with the selected groups.",
                          systemImage: "checkmark.circle").labelStyle(.tintedIcon(.green))
                }

                if let problems = previewProblems {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.circle").labelStyle(.tintedIcon(.orange)) }
                }

                Divider()

                HStack {
                    Button("Run Dry Run", systemImage: "eye") {
                        Task { await session.runDryRun() }
                    }
                    .disabled(!session.canRunDryRun)
                    .help("Validate, build the request and check for a Blueprint with the same name. Writes nothing.")

                    Button("Create Blueprint (Not Deployed)", systemImage: "plus.square.on.square") {
                        Task { await session.create() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canCreate)
                    .help("Creates the Blueprint without deploying it")

                    if session.isBusy || session.isLoadingSavedState { ProgressView().controlSize(.small) }
                }

                if let summary = session.dryRunSummary {
                    Label(summary, systemImage: "eye").font(.callout).textSelection(.enabled)
                }
                if let id = session.blueprintID {
                    Label("Blueprint \(id) exists (not deployed by this step).", systemImage: "checkmark.seal").textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var previewProblems: [String]? {
        if case let .failure(error) = session.preview { return error.problems }
        return nil
    }

    private func duplicatePrompt(_ duplicates: [JamfPlatform.BlueprintOverview]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("A Blueprint named “\(session.blueprintName)” already exists", systemImage: "doc.on.doc.fill")
                    .font(.headline)
                    .labelStyle(.tintedIcon(.orange))
                ForEach(duplicates) { existing in
                    HStack {
                        Text(existing.id).font(.callout.monospaced()).textSelection(.enabled)
                        Text(existing.deploymentState?.displayText ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Existing") { Task { await session.resolveDuplicate(.openExisting(existing)) } }
                    }
                }
                HStack {
                    Button("Skip") { Task { await session.resolveDuplicate(.skip) } }
                    Button("Rename") { Task { await session.resolveDuplicate(.rename) } }
                    Text("Rename suggests “\(MigrationSession.nextName(after: session.blueprintName))”.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var verifySection: some View {
        GroupBox("2 · Verify") {
            VStack(alignment: .leading, spacing: 10) {
                if let fidelity = session.fidelity {
                    if fidelity.passed {
                        Label(fidelity.caseChanges.isEmpty
                              ? FidelityReport.allMatchSentence
                              : "Matches; review ^[\(fidelity.caseChanges.count) key casing change](inflect: true).",
                              systemImage: fidelity.caseChanges.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .labelStyle(.tintedIcon(fidelity.caseChanges.isEmpty ? .green : .orange))
                    } else {
                        Label("^[\(fidelity.mismatches.count) mismatch](inflect: true). The in-place transform wouldn’t be seamless, so deploying is turned off.",
                              systemImage: "xmark.seal.fill")
                            .labelStyle(.tintedIcon(.red))
                    }
                    FidelityTable(rows: fidelity.rows)
                        .frame(minHeight: 220, idealHeight: 320)
                } else {
                    Text("Not verified yet.").foregroundStyle(.secondary)
                }
                Button("Verify Again", systemImage: "arrow.triangle.2.circlepath") { Task { await session.verify() } }
                    .disabled(session.isBusy || session.isLoadingSavedState)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var deploySection: some View {
        GroupBox("3 · Deploy") {
            VStack(alignment: .leading, spacing: 10) {
                switch session.state {
                case let .deploying(deployment):
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(deployment?.displayText ?? "Deployment requested…")
                    }
                    if case .timedOut = session.outcome {
                        Label("Polling stopped after the timeout while deployment was still in progress.", systemImage: "clock.badge.exclamationmark").labelStyle(.tintedIcon(.orange))
                        Button("Refresh Status") { Task { await session.recheckDeployment() } }.disabled(session.isBusy)
                    }
                case let .deployed(report):
                    Label("Deployed.", systemImage: "checkmark.circle.fill").labelStyle(.tintedIcon(.green))
                    if let report {
                        DeviceReportView(report: report)
                    }
                    if session.reportMonitorActive {
                        Label("Auto-refreshing until every device reports in…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh Status") { Task { await session.recheckDeployment() } }.disabled(session.isBusy)
                default:
                    Text("Deploying pushes the Blueprint to every device in the target groups. On each device the classic profile is replaced in place by the DDM-managed one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !session.unresolvedDeployGroupIDs.isEmpty {
                        WarningLabel("The Blueprint targets \(session.unresolvedDeployGroupIDs.count == 1 ? "a group" : "groups") the group list doesn’t have (\(session.unresolvedDeployGroupIDs.joined(separator: ", "))). Click Verify Again before deploying.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Deploy…", systemImage: "paperplane") { showingDeploySheet = true }
                        .disabled(!session.canDeploy)
                        .help(session.fidelity?.passed == false ? "Verification must pass first" : "Review targets and confirm")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

extension MigrateTab {
    var cleanupSection: some View {
        GroupBox("4 · Classic profile cleanup (optional)") {
            VStack(alignment: .leading, spacing: 10) {
                if !session.canChangeClassicScope {
                    Label("Classic scope changes are off for this tenant, so the classic profile stays as it is. To use this, turn on “Allow classic scope changes” in Settings › Connections.",
                          systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle(isOn: $session.unscopeAfterDeploy) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Unscope the classic profile automatically after a clean deployment")
                            Text("Only runs when the Blueprint is deployed, the report shows 0 failed and 0 pending devices, and the Blueprint’s groups cover every target of the classic scope. Runs once: never again after a Restore. The scope is backed up first. Payloads are never changed.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // Can be turned off at any time, turned on only before deploying
                    // (the deploy confirmation names it), and only once.
                    .disabled(session.scopeChangedBefore || session.scopeBackup != nil
                              || (!session.unscopeAfterDeploy && (isDeployingOrDeployed || !session.uncoveredClassicTargets.isEmpty)))

                    if !session.uncoveredClassicTargets.isEmpty {
                        WarningLabel("Automatic cleanup isn’t available: the classic profile also targets \(session.uncoveredClassicTargets.formatted(.list(type: .and))), which the Blueprint’s groups don’t cover.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    WarningLabel("When Jamf Pro unscopes a profile it removes it from devices. On devices where the in-place transform didn’t happen (no DDM, or not installed by MDM), the settings are lost. Try it with one profile and one device first.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("After the transform, Jamf Pro logs a failed “Remove Configuration Profile” command for each device: the device refuses to let MDM remove a profile the Blueprint now owns. That failure is expected.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    unscopeStatusView

                    HStack {
                        Button("Unscope Classic Profile…", systemImage: "scissors") { confirmingUnscope = true }
                            .disabled(!session.canUnscopeNow)
                            .help(ClassicScopeService.deploymentAllowsUnscope(session.outcome)
                                  ? "Remove every scope target from the classic profile"
                                  : "Available after a clean deployment (0 failed, 0 pending)")
                        Button("Restore Scope…", systemImage: "arrow.uturn.backward") { confirmingRestore = true }
                            .disabled(!session.canRestoreScope)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .confirmationDialog("Unscope “\(session.profile.name)”?", isPresented: $confirmingUnscope) {
            Button("Unscope Classic Profile", role: .destructive) { Task { await session.unscopeClassic() } }
        } message: {
            if session.uncoveredClassicTargets.isEmpty {
                Text("Removes every scope target from classic profile #\(session.profile.id) in \(workspace.environment.displayName). Jamf Pro will then remove the classic profile from devices. The current scope is backed up first.")
            } else {
                Text("Removes every scope target from classic profile #\(session.profile.id) in \(workspace.environment.displayName). The classic profile also targets \(session.uncoveredClassicTargets.formatted(.list(type: .and))), which the Blueprint’s groups (\(session.selectedGroups.map(\.name).formatted(.list(type: .and)))) don’t cover: Jamf Pro will remove the profile from those devices too, and they won’t get the Blueprint. The current scope is backed up first.")
            }
        }
        .confirmationDialog("Restore the scope of “\(session.profile.name)”?", isPresented: $confirmingRestore) {
            Button("Restore Scope") { Task { await session.restoreClassicScope() } }
        } message: {
            Text("Puts back the scope saved \(session.scopeBackup?.createdAt.formatted() ?? "earlier"). Jamf Pro will redistribute the classic profile to those devices.")
        }
    }

    private var isDeployingOrDeployed: Bool {
        switch session.state {
        case .deploying, .deployed: true
        default: false
        }
    }

    @ViewBuilder
    private var unscopeStatusView: some View {
        switch session.unscopeStatus {
        case .notRequested:
            EmptyView()
        case let .waiting(message):
            Label(message, systemImage: "hourglass").foregroundStyle(.secondary)
        case let .heldBack(message):
            WarningLabel(message)
                .fixedSize(horizontal: false, vertical: true)
        case let .unscoped(date):
            Label("Classic profile unscoped \(date.formatted()). Scope backup saved.", systemImage: "checkmark.circle.fill").labelStyle(.tintedIcon(.green))
        case let .uncertain(date):
            Label("A scope change started \(date.formatted()) may not have finished. Check the profile in Jamf Pro, or restore the saved scope.",
                  systemImage: "questionmark.circle").labelStyle(.tintedIcon(.orange))
                .fixedSize(horizontal: false, vertical: true)
        case let .restored(date):
            Label("Scope restored \(date.formatted()).", systemImage: "arrow.uturn.backward.circle.fill").labelStyle(.tintedIcon(.green))
        case let .failed(report):
            APIErrorView(report: report)
        }
    }
}

struct DeviceReportView: View {
    let report: JamfPlatform.BlueprintReport

    var body: some View {
        HStack(spacing: 18) {
            stat("Succeeded", report.succeeded, .green)
            stat("Failed", report.failed, .red)
            stat("Pending", report.pending, .blue)
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading) {
            Text("\(value)").font(.title2.monospacedDigit().weight(.semibold))
            Label(label, systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
                .labelStyle(.tintedIcon(color))
        }
    }
}

/// Field / classic / blueprint / ✓✗.
struct FidelityTable: View {
    let rows: [FidelityRow]

    var body: some View {
        Table(rows) {
            TableColumn("Status") { row in statusIcon(row.status) }
                .width(52)
            TableColumn("Field") { row in
                Text(row.field).help(row.note.map { Text($0) } ?? Text(verbatim: ""))
            }
            .width(min: 140, ideal: 200)
            TableColumn("Classic") { row in
                Text(row.classic).font(.callout.monospaced()).textSelection(.enabled).help(row.classic)
            }
            TableColumn("Blueprint") { row in
                Text(row.blueprint).font(.callout.monospaced()).textSelection(.enabled).help(row.blueprint)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: FidelityStatus) -> some View {
        switch status {
        case .match: Image(systemName: "checkmark").foregroundStyle(.green).accessibilityLabel("Match")
        case .mismatch: Image(systemName: "xmark").foregroundStyle(.red).accessibilityLabel("Mismatch")
        case .caseChanged: Image(systemName: "textformat").foregroundStyle(.orange).accessibilityLabel("Key casing changed")
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityLabel("Informational")
        }
    }
}

private struct StepIndicator: View {
    let state: MigrationState
    let hasBlueprint: Bool
    let fidelity: FidelityReport?
    /// Classic cleanup ran (a scope backup exists), so the last step is complete.
    let cleanupDone: Bool

    private var current: Int {
        switch state {
        case .deployed: cleanupDone ? 5 : 4
        case .deploying: 3
        default: hasBlueprint ? (fidelity != nil ? 3 : 2) : 1
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(["Review & create", "Verify", "Deploy", "Cleanup"].enumerated()), id: \.offset) { index, title in
                let step = index + 1
                HStack(spacing: 4) {
                    Image(systemName: step < current ? "checkmark.circle.fill" : (step == current ? "circle.inset.filled" : "circle"))
                        .foregroundStyle(step <= current ? Color.accentColor : Color.secondary)
                    Text(title).foregroundStyle(step <= current ? .primary : .secondary)
                }
                if index < 3 { Rectangle().fill(.quaternary).frame(width: 24, height: 1) }
            }
            if case let .failed(stage, _) = state {
                Spacer()
                Label("\(stage.capitalized) failed", systemImage: "exclamationmark.octagon").labelStyle(.tintedIcon(.red))
            }
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// What VoiceOver reads: where the migration stands, not just the step names.
    private var accessibilityText: String {
        let titles = ["Review & create", "Verify", "Deploy", "Cleanup"]
        var text = current > titles.count
            ? "All 4 steps done"
            : "Step \(current) of 4, \(titles[current - 1])"
        if case let .failed(stage, _) = state { text += ". \(stage.capitalized) failed" }
        return text
    }
}

#if DEBUG
#Preview("Migrate – needs attention") {
    let workspace = Workspace.previewDemo()
    MigrateTab(workspace: workspace, session: workspace.session(for: ProfileKey(platform: .macOS, id: 105))!)
        .frame(width: 800, height: 800)
}
#endif
