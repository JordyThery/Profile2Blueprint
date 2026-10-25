import JTKit
import SwiftUI

/// Sidebar destinations.
enum SidebarItem: Hashable {
    case profiles
    case history
    case activity
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateChecker.self) private var updates
    @State private var selection: SidebarItem? = .profiles

    var body: some View {
        @Bindable var model = model
        @Bindable var updates = updates

        NavigationSplitView {
            List(selection: $selection) {
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
            case .profiles:
                ProfilesView()
            case .history:
                HistoryView()
            case .activity:
                ActivityView()
            case nil:
                ContentUnavailableView(
                    "Choose a Section",
                    systemImage: "sidebar.left",
                    description: Text("Select Profiles, History or Activity in the sidebar.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                TenantPicker()
            }
        }
        .sheet(isPresented: $updates.isPresented) {
            UpdateView()
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
    }
}

#if DEBUG
#Preview {
    let model = AppModel(
        store: TenantStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-tenants.json")),
        secrets: KeychainSecretStore(service: "be.jordythery.profile2blueprint.preview")
    )
    ContentView()
        .environment(model)
        .environment(model.updates)
}
#endif
