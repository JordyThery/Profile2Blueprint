import SwiftUI

/// Sidebar destinations.
enum SidebarItem: Hashable {
    case tenant(UUID)
    case profiles
    case history
    case activity
    case about
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateChecker.self) private var updates
    @State private var selection: SidebarItem?
    @State private var tenantPendingDeletion: Tenant?

    var body: some View {
        @Bindable var model = model
        @Bindable var updates = updates

        NavigationSplitView {
            List(selection: $selection) {
                Section("Tenants") {
                    ForEach(model.tenants) { tenant in
                        TenantRow(tenant: tenant, isCurrent: tenant.id == model.currentTenantID)
                            .tag(SidebarItem.tenant(tenant.id))
                            .contextMenu {
                                Button("Make Current Tenant") { model.makeCurrent(tenant.id) }
                                    .disabled(tenant.id == model.currentTenantID)
                                Divider()
                                Button("Delete Tenant…", role: .destructive) { tenantPendingDeletion = tenant }
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

                Section {
                    Label("About", systemImage: "info.circle")
                        .tag(SidebarItem.about)
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
            case .about:
                AboutView()
            case nil:
                ContentUnavailableView(
                    "Connect a Tenant",
                    systemImage: "network",
                    description: Text("Add a tenant in the sidebar, enter its OAuth client, and test the connection.")
                )
            }
        }
        .sheet(isPresented: $updates.isPresented) {
            UpdateView()
        }
        .confirmationDialog(
            "Delete \u{201c}\(tenantPendingDeletion?.displayName ?? "")\u{201d}?",
            isPresented: Binding(
                get: { tenantPendingDeletion != nil },
                set: { if !$0 { tenantPendingDeletion = nil } }
            ),
            presenting: tenantPendingDeletion
        ) { tenant in
            Button("Delete Tenant and Keychain Secret", role: .destructive) {
                if selection == .tenant(tenant.id) { selection = nil }
                model.delete(tenant.id)
            }
        } message: { tenant in
            Text("Removes \u{201c}\(tenant.displayName)\u{201d} and its client secret from this Mac only. Nothing changes in Jamf.")
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
                if tenant.usesHostOverride {
                    Label(tenant.host, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Non-production host override")
                } else {
                    Text(tenant.region.rawValue.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "building.2")
                .foregroundStyle(isCurrent ? Color.green : Color.secondary)
        }
        .accessibilityLabel(isCurrent ? "\(tenant.displayName), current tenant" : tenant.displayName)
    }
}

/// Always-visible indicator of which tenant actions will run against.


#if DEBUG
#Preview {
    let model = AppModel(
        store: TenantStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-tenants.json")),
        secrets: InMemorySecretStore()
    )
    ContentView()
        .environment(model)
        .environment(model.updates)
}
#endif
