import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case source = "Source"
    case scope = "Scope"
    case preview = "Blueprint Preview"
    case diff = "Diff"
    case migrate = "Migrate"

    var id: String { rawValue }
}

struct ProfileDetailView: View {
    let workspace: Workspace
    let profileKey: ProfileKey
    @State private var tab: DetailTab = .source

    var body: some View {
        if let profile = workspace.profiles[profileKey], let report = workspace.reports[profileKey],
           let session = workspace.session(for: profileKey) {
            VStack(spacing: 0) {
                header(profile: profile, report: session.effectiveReport, blueprintID: session.blueprintID)
                Divider()
                Group {
                    switch tab {
                    case .source: SourceTab(profile: profile, report: report)
                    case .scope: ScopeMappingView(workspace: workspace, session: session)
                    case .preview: BlueprintPreviewTab(session: session)
                    case .diff: DiffTab(session: session)
                    case .migrate: MigrateTab(workspace: workspace, session: session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else if let error = workspace.profileErrors[profileKey] {
            VStack(alignment: .leading, spacing: 12) {
                APIErrorView(report: error)
                Button("Retry") { Task { await workspace.reloadProfile(key: profileKey) } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ProgressView("Loading profile…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(profile: ClassicProfile, report: EligibilityReport, blueprintID: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text("\(profile.platform.displayName) · Classic profile #\(profile.id) · ^[\(profile.document.payloadTypes.count) payload](inflect: true) · \(profile.level.displayName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                EligibilityBadge(status: report.status)
                if let links = workspace.environment.jamfProLinks {
                    OpenInJamfProMenu(links: links, profileKey: profileKey, blueprintID: blueprintID)
                }
                Button("Reload Profile", systemImage: "arrow.clockwise") {
                    Task { await workspace.reloadProfile(key: profileKey) }
                }
                .labelStyle(.iconOnly)
                .help("Re-read this profile from Jamf Pro (read-only)")
            }
            Picker("View", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding()
    }
}

/// Opens the configuration profile, and once created its blueprint, in Jamf Pro.
private struct OpenInJamfProMenu: View {
    let links: JamfProLinks
    let profileKey: ProfileKey
    let blueprintID: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu("Open in Jamf Pro", systemImage: "arrow.up.forward.app") {
            Button("Configuration Profile") { openURL(links.classicProfile(platform: profileKey.platform, id: profileKey.id)) }
            Button("Blueprint") {
                if let blueprintID { openURL(links.blueprint(id: blueprintID)) }
            }
            .disabled(blueprintID == nil)
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open in Jamf Pro")
    }
}

// MARK: - Source

struct SourceTab: View {
    let profile: ClassicProfile
    let report: EligibilityReport

    var body: some View {
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Eligibility") {
                        FindingsList(findings: report.findings)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }

                    GroupBox("Classic profile") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            MetadataRow(label: "Name", value: profile.name)
                            MetadataRow(label: "Description", value: profile.description)
                            MetadataRow(label: "Level", value: profile.level.displayName)
                            MetadataRow(label: "Distribution", value: profile.distributionMethod)
                            MetadataRow(label: "Redeploy on update", value: profile.redeployOnUpdate)
                            MetadataRow(label: "User removable", value: profile.userRemovable ? "Yes" : "No")
                            MetadataRow(label: "Site", value: profile.site?.name ?? "")
                            MetadataRow(label: "Category", value: profile.category?.name ?? "")
                            MetadataRow(label: "Jamf record UUID", value: profile.uuid, monospaced: true)
                            if case let .success(document) = profile.document {
                                MetadataRow(label: "PayloadIdentifier", value: document.payloadIdentifier ?? "", monospaced: true)
                                MetadataRow(label: "PayloadUUID", value: document.payloadUUID ?? "", monospaced: true)
                                MetadataRow(label: "PayloadDisplayName", value: document.payloadDisplayName ?? "")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }

                    GroupBox("Scope") {
                        ClassicScopeSummary(platform: profile.platform, scope: profile.scope)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }

                    if case let .success(document) = profile.document {
                        GroupBox("Payloads (in order)") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(document.payloads) { payload in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("\(payload.index + 1).").monospacedDigit().foregroundStyle(.secondary)
                                        VStack(alignment: .leading) {
                                            Text(payload.type ?? "Missing PayloadType").fontWeight(.medium)
                                            Text("Identifier \(payload.identifier ?? "—") · UUID \(payload.uuid ?? "—")")
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                    }
                }
                .padding()
            }
            .frame(minHeight: 200)

            Group {
                switch profile.document {
                case let .success(document):
                    PlistOutline(nodes: PlistNode.nodes(for: document.root))
                case let .failure(error):
                    Label(error.message, systemImage: "xmark.octagon").foregroundStyle(.red).padding()
                }
            }
            .frame(minHeight: 160)
        }
    }
}

struct ClassicScopeSummary: View {
    let platform: ProfilePlatform
    let scope: ClassicScope

    private var deviceNoun: String { platform.deviceNoun.prefix(1).uppercased() + platform.deviceNoun.dropFirst() }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            MetadataRow(label: "All \(platform.deviceNoun)s", value: scope.allDevices ? "Yes" : "No")
            MetadataRow(label: "\(deviceNoun) groups", value: scope.deviceGroups.map(\.name).joined(separator: ", "))
            if !scope.devices.isEmpty {
                MetadataRow(label: "\(deviceNoun)s", value: scope.devices.map(\.name).joined(separator: ", "))
            }
            if !scope.buildings.isEmpty {
                MetadataRow(label: "Buildings", value: scope.buildings.map(\.name).joined(separator: ", "))
            }
            if !scope.departments.isEmpty {
                MetadataRow(label: "Departments", value: scope.departments.map(\.name).joined(separator: ", "))
            }
            ForEach(scope.otherTargets) { bucket in
                MetadataRow(label: bucket.displayName, value: bucket.items.map(\.name).joined(separator: ", "))
            }
            ForEach(scope.limitations) { bucket in
                MetadataRow(label: "Limited to \(bucket.displayName.lowercased())", value: bucket.items.map(\.name).joined(separator: ", "))
            }
            ForEach(scope.exclusions) { bucket in
                MetadataRow(label: "Excluded \(bucket.displayName.lowercased())", value: bucket.items.map(\.name).joined(separator: ", "))
            }
        }
    }
}

#if DEBUG
#Preview("Detail – Source") {
    ProfileDetailView(workspace: .previewDemo(), profileKey: ProfileKey(platform: .macOS, id: 101))
        .frame(width: 800, height: 760)
}

#Preview("Detail – mobile source") {
    ProfileDetailView(workspace: .previewDemo(), profileKey: ProfileKey(platform: .mobile, id: 201))
        .frame(width: 800, height: 760)
}
#endif
