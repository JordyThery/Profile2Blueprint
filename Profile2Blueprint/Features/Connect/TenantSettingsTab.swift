import JTKit
import SwiftUI

/// Settings › Connections: JTKit's shared list and editor for the tenants,
/// with Profile2Blueprint's blueprint naming and classic cleanup below the
/// shared fields. "Use This Connection" sets the current tenant, as the
/// toolbar picker does.
struct TenantSettingsTab: View {
    let model: AppModel

    var body: some View {
        ConnectionsSettingsTab(
            store: model.connections,
            services: [.jamfPlatform],
            optionalFields: [.hostOverride, .jamfProWebURL],
            allowsChangingService: false,
            roles: [.active(selection: Binding(get: { model.currentTenantID }, set: { model.makeCurrent($0) }))],
            height: 560,
            footer: "Scope the Jamf Account integration to the platform environment. Grant device-groups:read, configuration-profiles:read and blueprints:create, read and deploy. The secret is stored only in your Keychain.",
            newRecord: { _ in Tenant(name: "New tenant") },
            test: { tenant, secrets in
                try await model.testConnection(tenant, secretOverride: secrets[.main])
            },
            environments: { tenant, secrets in
                try await model.environments(for: tenant, secretOverride: secrets[.main])
            }
        ) { $tenant in
            TenantAppSections(tenant: $tenant)
        }
    }
}

/// The tenant settings only Profile2Blueprint has.
private struct TenantAppSections: View {
    /// Stand-in profile for the naming examples, so the effect is visible before saving.
    private static let exampleProfileName = "Restrictions"
    private static let exampleProfileID = 451

    @Binding var tenant: Tenant
    @State private var confirmingClassicWrites = false

    var body: some View {
        if !tenant.jamfProURL.trimmingCharacters(in: .whitespaces).isEmpty, tenant.jamfProLinks == nil {
            Section {
                Label("The Jamf Pro web address is not a valid web address, so Open in Jamf Pro is unavailable.",
                      systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
        }

        Section {
            TextField("Prefix", text: $tenant.naming.prefix, prompt: Text("None"))
            TextField("Suffix", text: $tenant.naming.suffix, prompt: Text("None"))
            TextField("Description", text: $tenant.descriptionTemplate, prompt: Text("None"), axis: .vertical)
                .lineLimit(2...5)
            LabeledContent("Example name") {
                Text(tenant.naming.name(for: Self.exampleProfileName)).textSelection(.enabled)
            }
            LabeledContent("Example description") {
                Text(BlueprintBuilder.description(tenant.descriptionTemplate,
                                                  profileName: Self.exampleProfileName,
                                                  profileID: Self.exampleProfileID,
                                                  platform: .macOS))
                    .textSelection(.enabled)
            }
        } header: {
            Text("Blueprint name and description")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("All three are optional: leave one empty to drop it. Spacing in the prefix and suffix is used exactly as typed, and you can still edit the name and description of any Blueprint before creating it.")
                Text("Description tokens: " + BlueprintBuilder.descriptionTokens
                    .map { "\($0.token) is \($0.meaning)" }
                    .joined(separator: ", ") + ".")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Section {
            Toggle(isOn: Binding(
                get: { tenant.allowClassicScopeChanges },
                set: { enable in
                    if enable { confirmingClassicWrites = true } else { tenant.allowClassicScopeChanges = false }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow classic scope changes")
                    Text("Lets the app unscope a classic profile after its Blueprint is deployed, and restore it from a backup. Payloads are never changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if tenant.allowClassicScopeChanges {
                Label("On. Requires the configuration-profiles:update permission. Each unscope still needs a per-profile opt-in and confirmation.",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Label("Classic scope changes are off for this tenant: the app refuses every write to the Classic API.", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Classic profile cleanup")
        }
        .confirmationDialog(
            "Allow classic scope changes for \(tenant.displayName)?",
            isPresented: $confirmingClassicWrites
        ) {
            Button("Allow Scope Changes", role: .destructive) {
                tenant.allowClassicScopeChanges = true
            }
        } message: {
            Text("""
            This is the only way the app changes anything in Jamf Pro. Once you save, it can replace the scope of a classic \
            profile (after you opt in per profile and confirm). When Jamf Pro unscopes a profile it removes it from devices, \
            and on devices where the in-place DDM transform didn’t happen, the settings are lost. Test with one profile and one device first. \
            A backup of every scope is kept so it can be restored.
            """)
        }
    }
}
