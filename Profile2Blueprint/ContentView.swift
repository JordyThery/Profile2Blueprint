import SwiftUI

/// Sidebar destinations.
enum SidebarItem: Hashable {
    case tenant(UUID)
    case profiles
    case history
    case activity
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $selection) {
                Section("Tenants") {
                    ForEach(model.tenants) { tenant in
                        TenantRow(tenant: tenant, isCurrent: tenant.id == model.currentTenantID)
                            .tag(SidebarItem.tenant(tenant.id))
                            .contextMenu {
                                Button("Make Current Tenant") { model.makeCurrent(tenant.id) }
                                    .disabled(tenant.id == model.currentTenantID)
                            }
                    }
                    Button {
                        selection = .tenant(model.addTenant().id)
                    } label: {
                        Label("Add Tenant", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }

                Section("Migration") {
                    Label("Profiles", systemImage: "doc.badge.gearshape")
                        .tag(SidebarItem.profiles)
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.history)
                    Label("Activity", systemImage: "list.bullet.rectangle")
                        .tag(SidebarItem.activity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Toggle(isOn: $model.isDemoMode) {
                    Label("Offline demo mode", systemImage: "testtube.2")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(10)
                .help("Run the full flow against bundled fixtures. No tenant is contacted.")
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            switch selection {
            case let .tenant(id):
                if let tenant = model.tenant(id: id) {
                    ConnectView(tenant: tenant)
                        .id(id)
                } else {
                    ContentUnavailableView("Tenant Removed", systemImage: "building.2")
                }
            case .profiles:
                ProfilesView()
            case .history:
                HistoryView()
            case .activity:
                ActivityView()
            case nil:
                ContentUnavailableView(
                    "Connect a Tenant",
                    systemImage: "network",
                    description: Text("Add a tenant in the sidebar, enter its OAuth client, and test the connection.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                CurrentTenantBadge(tenant: model.currentTenant, isDemoMode: model.isDemoMode)
            }
        }
        .alert(
            "Couldn't Save",
            isPresented: Binding(
                get: { model.persistenceError != nil },
                set: { if !$0 { model.persistenceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.persistenceError ?? "")
        }
        .onAppear {
            if selection == nil, let first = model.currentTenant ?? model.tenants.first {
                selection = .tenant(first.id)
            }
        }
    }
}

private struct TenantRow: View {
    let tenant: Tenant
    let isCurrent: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(tenant.displayName)
                Text(tenant.usesHostOverride ? tenant.host : tenant.region.rawValue.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "building.2")
                .foregroundStyle(isCurrent ? Color.green : Color.secondary)
        }
        .accessibilityLabel(isCurrent ? "\(tenant.displayName), current tenant" : tenant.displayName)
    }
}

/// Always-visible indicator of which tenant actions will run against.
struct CurrentTenantBadge: View {
    let tenant: Tenant?
    var isDemoMode = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isDemoMode ? Color.blue : (tenant == nil ? Color.orange : Color.green))
                .frame(width: 8, height: 8)
            if isDemoMode {
                Text("Offline demo").fontWeight(.semibold)
                Text("· fixtures only").foregroundStyle(.secondary)
            } else if let tenant {
                Text(tenant.displayName).fontWeight(.semibold)
                Text("·").foregroundStyle(.secondary)
                Text(tenant.usesHostOverride ? tenant.host : tenant.region.rawValue.uppercased())
                    .foregroundStyle(tenant.usesHostOverride ? Color.orange : Color.secondary)
            } else {
                Text("No current tenant").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isDemoMode ? "Offline demo mode" : (tenant.map { "Current tenant: \($0.displayName), \($0.host)" } ?? "No current tenant"))
    }
}

#Preview {
    ContentView()
        .environment(AppModel(
            store: TenantStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-tenants.json")),
            secrets: InMemorySecretStore()
        ))
}
