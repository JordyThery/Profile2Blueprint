import SwiftUI

/// Classic scope targets → proposed platform device groups.
struct ScopeMappingView: View {
    let workspace: Workspace
    @Bindable var session: MigrationSession
    @State private var groupSearch = ""

    private var report: EligibilityReport { session.report }
    private var locked: Bool { session.blueprintID != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if locked {
                    Label("The blueprint has been created. Scope can no longer be changed here.", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Classic computer groups") {
                    if report.scopeMapping.isEmpty {
                        Text("This profile isn't scoped to any computer group.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow {
                                Text("Classic group").font(.caption).foregroundStyle(.secondary)
                                Text("Platform group").font(.caption).foregroundStyle(.secondary)
                                Text("Devices").font(.caption).foregroundStyle(.secondary)
                                Text("Match").font(.caption).foregroundStyle(.secondary)
                            }
                            Divider().gridCellUnsizedAxes(.horizontal)
                            ForEach(report.scopeMapping) { entry in
                                mappingRow(entry)
                            }
                        }
                        .padding(4)
                    }
                }

                scopeWarnings

                GroupBox("All platform computer groups") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Filter groups", text: $groupSearch)
                            .textFieldStyle(.roundedBorder)
                        let groups = workspace.groups.filter { groupSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(groupSearch) }
                        if groups.isEmpty {
                            Text(workspace.groups.isEmpty ? "No computer groups loaded." : "No groups match “\(groupSearch)”.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(groups.prefix(200)) { group in
                            Toggle(isOn: Binding(
                                get: { session.selectedGroupIDs.contains(group.id) },
                                set: { _ in session.toggleGroup(group.id) }
                            )) {
                                HStack {
                                    Text(group.name)
                                    Text(group.groupType.displayName).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(group.memberCount) devices").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .disabled(locked)
                        }
                        if groups.count > 200 {
                            Text("Showing 200 of \(groups.count). Refine the filter.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }

                selectionSummary
            }
            .padding()
        }
    }

    private func mappingRow(_ entry: ScopeMappingEntry) -> some View {
        let candidates = entry.exactMatches.isEmpty
            ? (entry.suggestions.isEmpty ? workspace.groups : entry.suggestions)
            : entry.exactMatches
        let selected = candidates.first { session.selectedGroupIDs.contains($0.id) }

        return GridRow(alignment: .firstTextBaseline) {
            Text(entry.classicGroup.name)
            Picker("Platform group for \(entry.classicGroup.name)", selection: Binding<String?>(
                get: { selected?.id },
                set: { newID in
                    // Replace whichever candidate was chosen for this classic group.
                    if let selected { session.toggleGroup(selected.id) }
                    if let newID, !session.selectedGroupIDs.contains(newID) { session.toggleGroup(newID) }
                }
            )) {
                Text("None").tag(String?.none)
                ForEach(candidates) { group in
                    Text("\(group.name) (\(group.groupType.displayName), \(group.memberCount))").tag(String?.some(group.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360)
            .disabled(locked)
            Text(selected.map { "\($0.memberCount)" } ?? "—").monospacedDigit()
            matchLabel(entry)
        }
    }

    @ViewBuilder
    private func matchLabel(_ entry: ScopeMappingEntry) -> some View {
        if entry.autoMatch != nil {
            Label("Exact", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if entry.isAmbiguous {
            Label("\(entry.exactMatches.count) groups share this name", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if !entry.suggestions.isEmpty {
            Label("Similar name only", systemImage: "questionmark.circle").foregroundStyle(.orange)
        } else {
            Label("No match", systemImage: "xmark.circle").foregroundStyle(.orange)
        }
    }

    private var scopeWarnings: some View {
        let kinds: Set<FindingKind> = [.noMappedGroup, .unmatchedGroups, .ambiguousGroups, .allComputers, .nonGroupTargets, .limitations, .exclusions]
        let findings = report.findings.filter { kinds.contains($0.kind) }
        return Group {
            if !findings.isEmpty {
                GroupBox("Scope differences") {
                    FindingsList(findings: findings)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
            }
        }
    }

    private var selectionSummary: some View {
        GroupBox("Blueprint scope") {
            VStack(alignment: .leading, spacing: 6) {
                if session.selectedGroups.isEmpty {
                    Label("No platform group selected. A blueprint needs at least one.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    ForEach(session.selectedGroups) { group in
                        HStack {
                            Text(group.name)
                            Spacer()
                            Text("\(group.memberCount) devices").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    HStack {
                        Text(session.selectedGroups.count > 1 ? "Up to (groups may overlap)" : "Total")
                        Spacer()
                        Text("\(session.deviceCount) devices").monospacedDigit().fontWeight(.semibold)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

#Preview("Scope – ambiguous") {
    let workspace = Workspace.previewDemo()
    ScopeMappingView(workspace: workspace, session: workspace.session(for: 102)!)
        .frame(width: 800, height: 700)
}
