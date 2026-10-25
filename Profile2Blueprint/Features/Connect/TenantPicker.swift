import JTKit
import SwiftUI

/// The toolbar's choice of what migrations run against: a saved tenant or the
/// offline demo. Always visible, so it's clear where actions go. Tenants are
/// edited in Settings › Connections.
struct TenantPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            TenantMenuItems(model: model)
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
        }
        .help(help)
        .accessibilityLabel(accessibilityTitle)
    }

    private var title: String {
        if model.isDemoMode { return "Offline Demo" }
        return model.currentTenant?.displayName ?? "No Tenant"
    }

    private var accessibilityTitle: String {
        if !model.isDemoMode, let tenant = model.currentTenant, tenant.usesHostOverride {
            return "Current tenant: \(title), non-production host"
        }
        return "Current tenant: \(title)"
    }

    private var symbol: String {
        if model.isDemoMode { return "testtube.2" }
        guard let tenant = model.currentTenant else { return "network.slash" }
        return tenant.usesHostOverride ? "exclamationmark.triangle.fill" : "building.2"
    }

    private var help: String {
        if model.isDemoMode { return "Running against bundled fixtures. No tenant is contacted." }
        guard let tenant = model.currentTenant else { return "Choose a tenant, or add one in Settings › Connections." }
        return tenant.usesHostOverride
            ? "Migrations run against \(tenant.displayName) on a non-production host (\(tenant.host))."
            : "Migrations run against \(tenant.displayName) (\(tenant.region.rawValue.uppercased()))."
    }
}

/// The same choice in the menu bar's Tenant menu, as every toolbar item needs a
/// menu bar command too.
struct TenantCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Tenant") {
            TenantMenuItems(model: model)
        }
    }
}

/// The tenants (one checked), Offline Demo Mode and Edit Tenants…, shared by
/// the toolbar picker and the Tenant menu.
private struct TenantMenuItems: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model

        if model.tenants.isEmpty {
            Text("No tenants yet")
        } else {
            Picker("Tenant", selection: tenantSelection) {
                ForEach(model.tenants) { tenant in
                    Text(tenant.displayName).tag(Optional(tenant.id))
                }
            }
            .pickerStyle(.inline)
        }
        Divider()
        Toggle("Offline Demo Mode", isOn: $model.isDemoMode)
        Divider()
        SettingsTabLink(SettingsTabName.connections) {
            Text("Edit Tenants…")
        }
    }

    /// No tenant is checked in demo mode. Choosing one leaves demo mode; the
    /// current tenant itself stays as it was while demo mode is on.
    private var tenantSelection: Binding<UUID?> {
        Binding(
            get: { model.isDemoMode ? nil : model.currentTenantID },
            set: { id in
                guard let id else { return }
                if model.isDemoMode { model.isDemoMode = false }
                model.makeCurrent(id)
            })
    }
}
