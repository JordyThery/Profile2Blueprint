import SwiftUI
import JTKit

/// One Blueprint awaiting deploy confirmation.
struct DeployItem: Identifiable, Hashable {
    let blueprintID: String
    let blueprintName: String
    let sourceName: String
    /// The verified Blueprint's groups, names from the group list.
    let groups: [JamfPlatform.DeviceGroup]
    /// Group IDs in the verified scope the group list doesn't have: Deploy is
    /// refused until Verify Again finds them.
    var unresolvedGroupIDs: [String] = []
    /// Fidelity case-change warnings to surface next to the item.
    let warnings: Int
    /// When set, the classic profile (this label) is unscoped after a clean deploy.
    var unscopeClassicProfile: String? = nil

    var id: String { blueprintID }
    /// Known member counts only; see `hasUnknownDeviceCount`.
    var deviceCount: Int { groups.knownDeviceCount }
    var hasUnknownDeviceCount: Bool { groups.hasUnknownDeviceCount }
    var canBeConfirmed: Bool { !groups.isEmpty && unresolvedGroupIDs.isEmpty }
}

/// The deploy confirmation as a sheet of its own (one profile's Migrate tab).
struct DeployConfirmationSheet: View {
    let items: [DeployItem]
    let environmentName: String
    let isDemo: Bool
    let onConfirm: ([DeployConfirmation]) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DeployConfirmationView(items: items, environmentName: environmentName, isDemo: isDemo,
                               onCancel: { dismiss() },
                               onConfirm: { onConfirm($0); dismiss() })
            .padding(24)
            .frame(width: 520)
    }
}

/// The single explicit confirmation before deploying. Lists every Blueprint, its
/// target groups and device counts; nothing deploys until the box is ticked and
/// Deploy is pressed. A view, so batch migration shows it in its own sheet
/// instead of a second sheet on top.
struct DeployConfirmationView: View {
    let items: [DeployItem]
    let environmentName: String
    let isDemo: Bool
    let onCancel: () -> Void
    let onConfirm: ([DeployConfirmation]) -> Void

    @State private var confirmed = false

    private var totalDevices: Int { items.reduce(0) { $0 + $1.deviceCount } }
    /// A group came without a member count: the total is a lower bound.
    private var countIsPartial: Bool { items.contains(where: \.hasUnknownDeviceCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(items.count == 1 ? "Deploy Blueprint?" : "Deploy \(items.count) Blueprints?", systemImage: "paperplane.fill")
                .font(.title2.weight(.semibold))

            Text(isDemo
                 ? "\(DemoMode.title). This simulates a deployment."
                 : "Tenant: \(environmentName). Devices in these groups will receive the DDM profile. Where the classic profile is installed, it is replaced in place.")
                .foregroundStyle(isDemo ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.blueprintName).font(.headline)
                            Text("From classic profile “\(item.sourceName)”").font(.caption).foregroundStyle(.secondary)
                            Text(item.blueprintID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            ForEach(item.groups) { group in
                                HStack {
                                    Image(systemName: "person.3").accessibilityHidden(true)
                                    Text(group.name)
                                    Spacer()
                                    Text(group.memberCountText).monospacedDigit()
                                        .foregroundStyle(group.memberCount == nil ? Color.secondary : Color.primary)
                                }
                                .font(.callout)
                            }
                            ForEach(item.unresolvedGroupIDs, id: \.self) { id in
                                WarningLabel("Group \(id) isn’t in the group list. Click Verify Again before deploying.")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let classic = item.unscopeClassicProfile {
                                Label("Afterwards, classic profile \(classic) will be unscoped, but only if every device succeeds. Devices with the in-place transform then refuse Jamf Pro’s Remove command, and Jamf Pro keeps retrying, which can overload Jamf Pro on a large fleet. Its scope is backed up first and can be restored.",
                                      systemImage: "scissors")
                                    .font(.callout).labelStyle(.tintedIcon(.orange))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if item.warnings > 0 {
                                WarningLabel(Text("^[\(item.warnings) key casing change](inflect: true) found during verification"))
                                    .font(.callout)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 340)

            HStack {
                Text("Total")
                Spacer()
                if countIsPartial {
                    Text("At least ^[\(totalDevices) device](inflect: true), some counts unknown")
                        .monospacedDigit().fontWeight(.semibold)
                } else {
                    Text("\(items.contains { $0.groups.count > 1 } || items.count > 1 ? "up to " : "")^[\(totalDevices) device](inflect: true)")
                        .monospacedDigit().fontWeight(.semibold)
                }
            }

            Toggle(isOn: $confirmed) {
                // Single literals only: concatenated strings skip grammar inflection.
                if items.count == 1, let item = items.first {
                    if countIsPartial, item.unscopeClassicProfile != nil {
                        Text("I confirm deploying “\(item.blueprintName)” to every device in the groups listed above and unscoping the classic profile afterwards.")
                    } else if countIsPartial {
                        Text("I confirm deploying “\(item.blueprintName)” to every device in the groups listed above.")
                    } else if item.unscopeClassicProfile != nil {
                        Text("I confirm deploying “\(item.blueprintName)” to ^[\(totalDevices) device](inflect: true) and unscoping the classic profile afterwards.")
                    } else {
                        Text("I confirm deploying “\(item.blueprintName)” to ^[\(totalDevices) device](inflect: true).")
                    }
                } else {
                    Text("I confirm deploying all \(items.count) Blueprints listed above.")
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(items.count == 1 ? "Deploy" : "Deploy All \(items.count)", role: .destructive) {
                    let now = Date()
                    onConfirm(items.map {
                        DeployConfirmation(blueprintID: $0.blueprintID, blueprintName: $0.blueprintName,
                                           groupNames: $0.groups.map(\.name), deviceCount: $0.deviceCount, confirmedAt: now)
                    })
                }
                .disabled(!confirmed || items.isEmpty || !items.allSatisfy(\.canBeConfirmed))
            }
        }
    }
}

#if DEBUG
#Preview("Deploy confirmation") {
    DeployConfirmationSheet(
        items: [DeployItem(blueprintID: DemoSamples.uuid(0xb101), blueprintName: "Contoso – Managed Login Items (migrated)",
                           sourceName: "Contoso – Managed Login Items", groups: [DemoFixtures.platformGroups[0]], warnings: 0)],
        environmentName: "Production", isDemo: false
    ) { _ in }
}
#endif
