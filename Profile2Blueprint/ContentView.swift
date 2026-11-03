import JTKit
import SwiftUI

/// Sidebar destinations.
enum SidebarItem: Hashable {
    case profiles
    case history
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateChecker.self) private var updates
    /// Set when the window first appears (`chooseFirstPage`).
    @State private var selection: SidebarItem?
    @State private var choseFirstPage = false

    var body: some View {
        @Bindable var updates = updates

        NavigationSplitView {
            List(selection: $selection) {
                Section("Migration") {
                    Label("Profiles", systemImage: "doc.badge.gearshape")
                        .tag(SidebarItem.profiles)
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            switch selection {
            case .profiles:
                ProfilesView()
            case .history:
                HistoryView()
            case nil:
                ContentUnavailableView {
                    Label("Choose a Section", systemImage: "sidebar.left")
                } description: {
                    if let tenant = model.currentTenant, !model.isDemoMode {
                        Text("Profiles loads the classic profiles from “\(tenant.displayName)”. History shows earlier migrations.")
                    } else {
                        Text("Select Profiles or History in the sidebar.")
                    }
                } actions: {
                    Button("Open Profiles") { selection = .profiles }
                }
            }
        }
        .onAppear(perform: chooseFirstPage)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                TenantPicker()
            }
        }
        .sheet(isPresented: $updates.isPresented) {
            UpdateView()
        }
        .alert(
            "Couldn’t Save",
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

    /// The tenant is contacted only once the user opens Profiles: with a
    /// tenant in use the window opens on no page. Demo mode and the No
    /// Tenant page contact nothing, so they open on Profiles.
    private func chooseFirstPage() {
        guard !choseFirstPage else { return }
        choseFirstPage = true
        if model.isDemoMode || model.currentTenant == nil { selection = .profiles }
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
