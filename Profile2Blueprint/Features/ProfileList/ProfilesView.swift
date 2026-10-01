import SwiftUI

/// Entry point for the Profiles sidebar item: resolves the active workspace.
struct ProfilesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch Result(catching: { try model.activeWorkspace() }) {
            case let .success(workspace):
                ProfilesContent(workspace: workspace)
            case let .failure(error):
                ContentUnavailableView {
                    Label("No Environment", systemImage: "network.slash")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Use Offline Demo") { model.isDemoMode = true }
                }
            }
        }
        .id(model.workspaceGeneration)
    }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case ready = "Ready"
    case attention = "Needs attention"
    case blocked = "Blocked"

    var id: String { rawValue }

    func includes(_ status: EligibilityStatus?) -> Bool {
        switch self {
        case .all: true
        case .ready: status == .ready
        case .attention: status == .needsAttention
        case .blocked: status == .blocked
        }
    }
}

private struct ProfilesContent: View {
    let workspace: Workspace
    @State private var selection = Set<Int>()
    @State private var search = ""
    @State private var filter: StatusFilter = .all
    @State private var showingBatch = false

    private var filtered: [ClassicProfileSummary] {
        workspace.summaries.filter { summary in
            filter.includes(workspace.status(for: summary.id))
                && (search.isEmpty
                    || summary.name.localizedCaseInsensitiveContains(search)
                    || String(summary.id) == search
                    || (workspace.profiles[summary.id]?.document.payloadTypes.contains { $0.localizedCaseInsensitiveContains(search) } ?? false))
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                list
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)

            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search profiles, IDs or payload types")
        .navigationTitle("Profiles")
        .navigationSubtitle(workspace.environment.displayName)
        .toolbar {
            ToolbarItemGroup {
                Button("Reload", systemImage: "arrow.clockwise") { workspace.reload() }
                    .help("Reload profiles and device groups (read-only)")
                Button("Migrate Selected…", systemImage: "square.stack.3d.up") { showingBatch = true }
                    .disabled(selection.count < 2)
                    .help("Batch migration with a per-item summary")
            }
        }
        .sheet(isPresented: $showingBatch) {
            BatchMigrationView(workspace: workspace, profileIDs: selection.sorted())
        }
        .onAppear { workspace.loadIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show", selection: $filter) {
                ForEach(StatusFilter.allCases) { option in
                    Text(label(for: option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch workspace.listPhase {
            case .loading:
                ProgressView("Loading profiles…").controlSize(.small)
            case let .failed(report):
                APIErrorView(report: report)
            case .loaded where workspace.isLoadingDetails:
                ProgressView(value: Double(workspace.detailsLoaded), total: Double(max(workspace.summaries.count, 1))) {
                    Text("Checking \(workspace.detailsLoaded) of \(workspace.summaries.count) profiles…").font(.caption)
                }
            default:
                Text("\(workspace.summaries.count) profiles · \(workspace.groups.count) computer groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let groupsError = workspace.groupsError {
                DisclosureGroup("Device groups couldn't be loaded") {
                    APIErrorView(report: groupsError)
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(10)
    }

    private func label(for option: StatusFilter) -> String {
        switch option {
        case .all: "All"
        case .ready: "✅ \(workspace.count(of: .ready))"
        case .attention: "⚠️ \(workspace.count(of: .needsAttention))"
        case .blocked: "⛔ \(workspace.count(of: .blocked))"
        }
    }

    private var list: some View {
        List(filtered, selection: $selection) { summary in
            ProfileRow(
                summary: summary,
                profile: workspace.profiles[summary.id],
                report: workspace.reports[summary.id],
                error: workspace.profileErrors[summary.id]
            )
            .tag(summary.id)
        }
        .overlay {
            if workspace.listPhase == .loaded && filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selection.count == 1, let id = selection.first {
            ProfileDetailView(workspace: workspace, profileID: id)
                .id(id)
        } else if selection.count > 1 {
            ContentUnavailableView {
                Label("\(selection.count) Profiles Selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Review them together. Each one gets its own summary and target group, and deploying needs one confirmation that lists every target.")
            } actions: {
                Button("Review Batch Migration…") { showingBatch = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "Select a Profile",
                systemImage: "doc.badge.gearshape",
                description: Text("Choose a classic macOS configuration profile to inspect and migrate. Jamf Pro is only read, never changed.")
            )
        }
    }
}

private struct ProfileRow: View {
    let summary: ClassicProfileSummary
    let profile: ClassicProfile?
    let report: EligibilityReport?
    let error: ErrorReport?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if error != nil {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Failed to load")
            } else {
                EligibilityBadge(status: report?.status, compact: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let reason = report?.reasons.first {
                    Text(reason.title + (report!.reasons.count > 1 ? " +\(report!.reasons.count - 1) more" : ""))
                        .font(.caption)
                        .foregroundStyle(reason.severity.color)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = ["#\(summary.id)"]
        if let profile {
            let types = profile.document.payloadTypes
            parts.append("\(types.count) payload\(types.count == 1 ? "" : "s")")
            if let first = types.first {
                parts.append(types.count > 1 ? "\(first) +\(types.count - 1)" : first)
            }
        }
        return parts.joined(separator: " · ")
    }
}

extension Result<ProfileDocument, PlistParseError> {
    nonisolated var payloadTypes: [String] {
        (try? get())?.payloads.map { $0.type ?? "?" } ?? []
    }
}

#Preview("Profiles – demo") {
    ProfilesContent(workspace: .previewDemo())
        .frame(width: 1100, height: 700)
}
