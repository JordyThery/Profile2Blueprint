import JTKit
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
                    Label("No Tenant", systemImage: "network.slash")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    SettingsTabLink(SettingsTabName.connections) { Text(ConnectionMenuText.editTitle) }
                    Button("Try \(DemoMode.title)") { model.isDemoMode = true }
                }
            }
        }
        .id(model.workspaceGeneration)
    }
}

enum PlatformFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case macOS = "macOS"
    case mobile = "Mobile"

    var id: String { rawValue }

    func includes(_ platform: ProfilePlatform) -> Bool {
        switch self {
        case .all: true
        case .macOS: platform == .macOS
        case .mobile: platform == .mobile
        }
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
    @State private var selection = Set<ProfileKey>()
    @State private var search = ""
    @State private var filter: StatusFilter = .all
    @State private var platformFilter: PlatformFilter = .all
    @State private var showingBatch = false

    private var filtered: [ClassicProfileSummary] {
        workspace.summaries.filter { summary in
            platformFilter.includes(summary.platform)
                && filter.includes(workspace.status(for: summary.key))
                && (search.isEmpty
                    || summary.name.localizedCaseInsensitiveContains(search)
                    || String(summary.profileID) == search
                    || (workspace.profiles[summary.key]?.document.payloadTypes.contains { $0.localizedCaseInsensitiveContains(search) } ?? false))
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
                    .keyboardShortcut("r")
                    .help("Reload profiles and device groups (read-only)")
                Button("Migrate Selected…", systemImage: "square.stack.3d.up") { showingBatch = true }
                    .disabled(selection.count < 2)
                    .help("Migrate the selected profiles together, with a summary per profile")
            }
        }
        .sheet(isPresented: $showingBatch) {
            BatchMigrationView(workspace: workspace, profileKeys: selection.sorted())
        }
        .onAppear { workspace.loadIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show", selection: $filter) {
                ForEach(StatusFilter.allCases) { option in
                    label(for: option).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Platform", selection: $platformFilter) {
                ForEach(PlatformFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Show macOS profiles, mobile device profiles, or both")

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
                Text("^[\(workspace.summaries.count) profile](inflect: true) · ^[\(workspace.groups.count) device group](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let groupsError = workspace.groupsError {
                DisclosureGroup("Device groups couldn’t be loaded") {
                    APIErrorView(report: groupsError)
                }
                .foregroundStyle(.orange)
            }
            ForEach(ProfilePlatform.allCases.filter { workspace.listErrors[$0] != nil }) { platform in
                if let error = workspace.listErrors[platform] {
                    DisclosureGroup("\(platform.displayName) profiles couldn’t be loaded") {
                        APIErrorView(report: error)
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
    }

    /// The status's SF Symbol and count, as the badges draw it, with the status read out.
    private func label(for option: StatusFilter) -> Text {
        let status: EligibilityStatus
        switch option {
        case .all: return Text("All")
        case .ready: status = .ready
        case .attention: status = .needsAttention
        case .blocked: status = .blocked
        }
        let count = workspace.count(of: status)
        return Text("\(Image(systemName: status.symbol)) \(count)")
            .accessibilityLabel("\(status.title), \(count)")
    }

    private var list: some View {
        List(filtered, selection: $selection) { summary in
            ProfileRow(
                summary: summary,
                profile: workspace.profiles[summary.key],
                report: workspace.reports[summary.key],
                error: workspace.profileErrors[summary.key],
                isChecked: Binding(
                    get: { selection.contains(summary.key) },
                    set: { checked in
                        if checked { selection.insert(summary.key) } else { selection.remove(summary.key) }
                    }
                )
            )
            .tag(summary.key)
        }
        .overlay {
            if workspace.listPhase == .loaded && filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selection.count == 1, let key = selection.first {
            ProfileDetailView(workspace: workspace, profileKey: key)
                .id(key)
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
                description: Text("Choose a classic configuration profile to inspect and migrate. The app reads Jamf Pro; it never changes it unless classic scope cleanup is explicitly enabled.")
            )
        }
    }
}

private struct ProfileRow: View {
    let summary: ClassicProfileSummary
    let profile: ClassicProfile?
    let report: EligibilityReport?
    let error: ErrorReport?
    /// Adds the row to the selection without ⌘-click, for building a batch.
    @Binding var isChecked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("Include in selection", isOn: $isChecked)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Add to the selection for batch migration")
            if error != nil {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Failed to load")
            } else {
                EligibilityBadge(status: report?.status, compact: true)
            }
            Image(systemName: summary.platform.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help(summary.platform.displayName)
                .accessibilityLabel(summary.platform.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let reasons = report?.reasons, let reason = reasons.first {
                    Text(reason.title + (reasons.count > 1 ? " +\(reasons.count - 1) more" : ""))
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
        var parts = ["#\(summary.profileID)"]
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

#if DEBUG
#Preview("Profiles – demo") {
    ProfilesContent(workspace: .previewDemo())
        .frame(width: 1100, height: 700)
}
#endif
