import JTKit
import SwiftUI

/// The toolbar's choice of what migrations run against: a saved tenant or the
/// offline demo. JTKit's shared picker, with Offline Demo Mode in its slot for
/// the app's own items. Always visible, so it's clear where actions go.
/// Tenants are edited in Settings › Connections.
struct TenantPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ConnectionPicker(store: model.connections,
                         selection: tenantSelection(model),
                         editTitle: "Edit Tenants…",
                         itemTitle: \.displayName,
                         label: label,
                         help: help) {
            Toggle("Offline Demo Mode", isOn: $model.isDemoMode)
        }
    }

    /// Demo mode and a non-production host are shown instead of the plain
    /// tenant, so it's always clear where actions go.
    private var label: ConnectionPickerLabel? {
        if model.isDemoMode {
            return ConnectionPickerLabel("Offline Demo", systemImage: "testtube.2",
                                         accessibilityLabel: "Current tenant: Offline Demo")
        }
        guard let tenant = model.currentTenant, tenant.usesHostOverride else { return nil }
        return ConnectionPickerLabel(tenant.displayName, systemImage: "exclamationmark.triangle.fill",
                                     accessibilityLabel: "Current tenant: \(tenant.displayName), non-production host")
    }

    private var help: String {
        if model.isDemoMode { return "Running against bundled fixtures. No tenant is contacted." }
        guard let tenant = model.currentTenant else { return "Choose a tenant, or add one in Settings › Connections." }
        return tenant.usesHostOverride
            ? "Migrations run against \(tenant.displayName) on a non-production host (\(tenant.host))."
            : "Migrations run against \(tenant.displayName) (\(tenant.region.rawValue.uppercased()))."
    }
}

/// The same choice in the menu bar: JTKit's shared Connection menu, with the
/// same items as the toolbar picker (the tenants, Offline Demo Mode, then
/// Edit Tenants…).
struct TenantCommands: Commands {
    let model: AppModel

    var body: some Commands {
        ConnectionCommands(store: model.connections,
                           selection: tenantSelection(model),
                           editTitle: "Edit Tenants…",
                           itemTitle: \.displayName) {
            Toggle("Offline Demo Mode", isOn: Binding(
                get: { model.isDemoMode },
                set: { model.isDemoMode = $0 }))
        }
    }
}

/// The current tenant, as the toolbar picker and the Connection menu choose
/// it. No tenant is checked in demo mode. Choosing one leaves demo mode; the
/// current tenant itself stays as it was while demo mode is on.
@MainActor
private func tenantSelection(_ model: AppModel) -> Binding<UUID?> {
    Binding(
        get: { model.isDemoMode ? nil : model.currentTenantID },
        set: { id in
            guard let id else { return }
            if model.isDemoMode { model.isDemoMode = false }
            model.makeCurrent(id)
        })
}
