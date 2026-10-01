import SwiftUI

/// One blueprint awaiting deploy confirmation.
struct DeployItem: Identifiable, Hashable {
    let blueprintID: String
    let blueprintName: String
    let sourceName: String
    let groups: [PlatformGroup]
    /// Fidelity case-change warnings to surface next to the item.
    let warnings: Int
    /// When set, the classic profile (this label) is unscoped after a clean deploy.
    var unscopeClassicProfile: String? = nil

    var id: String { blueprintID }
    var deviceCount: Int { groups.reduce(0) { $0 + $1.memberCount } }
}

/// The single explicit confirmation before deploying. Lists every blueprint, its
/// target groups and device counts; nothing deploys until the box is ticked and
/// Deploy is pressed.
struct DeployConfirmationSheet: View {
    let items: [DeployItem]
    let environmentName: String
    let isDemo: Bool
    let onConfirm: ([DeployConfirmation]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false

    private var totalDevices: Int { items.reduce(0) { $0 + $1.deviceCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(items.count == 1 ? "Deploy blueprint?" : "Deploy \(items.count) blueprints?", systemImage: "paperplane.fill")
                .font(.title2.weight(.semibold))

            Text(isDemo
                 ? "Offline demo. This simulates a deployment."
                 : "Environment: \(environmentName). Devices in these groups will receive the DDM profile. Where the classic profile is installed, it is replaced in place.")
                .foregroundStyle(isDemo ? Color.secondary : Color.orange)
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
                                    Image(systemName: "person.3")
                                    Text(group.name)
                                    Spacer()
                                    Text("^[\(group.memberCount) device](inflect: true)").monospacedDigit()
                                }
                                .font(.callout)
                            }
                            if let classic = item.unscopeClassicProfile {
                                Label("Afterwards, classic profile \(classic) will be unscoped, but only if every device succeeds. Its scope is backed up first and can be restored.",
                                      systemImage: "scissors")
                                    .font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if item.warnings > 0 {
                                Label("\(item.warnings) key casing change(s) found during verification", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
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
                Text("\(items.contains { $0.groups.count > 1 } || items.count > 1 ? "up to " : "")^[\(totalDevices) device](inflect: true)")
                    .monospacedDigit().fontWeight(.semibold)
            }

            Toggle(isOn: $confirmed) {
                Text(items.count == 1
                     ? "I confirm deploying “\(items[0].blueprintName)” to ^[\(totalDevices) device](inflect: true)"
                        + (items[0].unscopeClassicProfile != nil ? " and unscoping the classic profile afterwards." : ".")
                     : "I confirm deploying all \(items.count) blueprints listed above.")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(items.count == 1 ? "Deploy" : "Deploy All \(items.count)", role: .destructive) {
                    let now = Date()
                    onConfirm(items.map {
                        DeployConfirmation(blueprintID: $0.blueprintID, blueprintName: $0.blueprintName,
                                           groupNames: $0.groups.map(\.name), deviceCount: $0.deviceCount, confirmedAt: now)
                    })
                    dismiss()
                }
                .disabled(!confirmed || items.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

#Preview("Deploy confirmation") {
    DeployConfirmationSheet(
        items: [DeployItem(blueprintID: "5b1f7c2e-0000-4000-8000-000000000001", blueprintName: "Classic – Managed Login Items (migrated)",
                           sourceName: "Classic – Managed Login Items", groups: [DemoFixtures.platformGroups[0]], warnings: 0)],
        environmentName: "Production", isDemo: false
    ) { _ in }
}
