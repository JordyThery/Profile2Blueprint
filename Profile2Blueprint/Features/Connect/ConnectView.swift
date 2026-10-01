import SwiftUI

/// Edit a tenant's connection settings and test them.
struct ConnectView: View {
    /// Stand-in profile for the naming examples, so the effect is visible before saving.
    private static let exampleProfileName = "Restrictions"
    private static let exampleProfileID = 451

    @Environment(AppModel.self) private var model
    @State private var draft: Tenant
    @State private var secret = ""
    @State private var hasStoredSecret = false
    @State private var confirmingDelete = false
    @State private var confirmingClassicWrites = false

    init(tenant: Tenant) {
        _draft = State(initialValue: tenant)
    }

    private var saved: Tenant? { model.tenant(id: draft.id) }
    private var isDirty: Bool { saved != draft || !secret.isEmpty }
    private var isCurrent: Bool { model.currentTenantID == draft.id }
    private var state: ConnectionState { model.connectionState(for: draft.id) }

    var body: some View {
        Form {
            Section("Tenant") {
                TextField("Name", text: $draft.name)
                Picker("Region", selection: $draft.region) {
                    ForEach(Region.allCases) { region in
                        Text(region.displayName).tag(region)
                    }
                }
                TextField("Environment ID", text: $draft.environmentID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                    .font(.body.monospaced())
            }

            Section {
                TextField("Client ID", text: $draft.clientID)
                    .font(.body.monospaced())
                SecureField(
                    "Client secret",
                    text: $secret,
                    prompt: Text(hasStoredSecret ? "Stored in Keychain — type to replace" : "Required")
                )
            } header: {
                Text("OAuth client (Jamf Account integration)")
            } footer: {
                Text("Scope the integration to the platform environment. Grant device-groups:read, configuration-profiles:read and blueprints:create, read and deploy. The secret is stored only in your Keychain.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(
                    "Host override",
                    text: Binding(get: { draft.hostOverride ?? "" }, set: { draft.hostOverride = $0.isEmpty ? nil : $0 }),
                    prompt: Text("\(draft.region.rawValue).api.jamfcloud.com")
                )
                .font(.body.monospaced())
                LabeledContent("Requests go to", value: draft.baseURL?.absoluteString ?? "Invalid host")
            } header: {
                Text("Advanced")
            } footer: {
                if draft.usesHostOverride {
                    Label("Non-production host. Tokens are region- and host-locked.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                TextField("Prefix", text: $draft.naming.prefix, prompt: Text("None"))
                TextField("Suffix", text: $draft.naming.suffix, prompt: Text("None"))
                TextField("Description", text: $draft.descriptionTemplate, prompt: Text("None"), axis: .vertical)
                    .lineLimit(2...5)
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Example name") {
                        Text(draft.naming.name(for: Self.exampleProfileName)).textSelection(.enabled)
                    }
                    LabeledContent("Example description") {
                        Text(BlueprintBuilder.description(draft.descriptionTemplate,
                                                          profileName: Self.exampleProfileName,
                                                          profileID: Self.exampleProfileID))
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Blueprint name and description")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All three are optional: leave one empty to drop it. Spacing in the prefix and suffix is used exactly as typed, and you can still edit the name and description of any blueprint before creating it.")
                    Text("Description tokens: " + BlueprintBuilder.descriptionTokens
                        .map { "\($0.token) is \($0.meaning)" }
                        .joined(separator: ", ") + ".")
                }
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { draft.allowClassicScopeChanges },
                    set: { enable in
                        if enable { confirmingClassicWrites = true } else { draft.allowClassicScopeChanges = false }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow classic scope changes")
                        Text("Lets the app unscope a classic profile after its blueprint is deployed, and restore it from a backup. Payloads are never changed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if draft.allowClassicScopeChanges {
                    Label("Enabled. Requires the configuration-profiles:update permission. Each unscope still needs a per-profile opt-in and confirmation.",
                          systemImage: "exclamationmark.shield.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Label("Off: the app refuses every write to the Classic API.", systemImage: "lock.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Classic profile cleanup")
            }

            if !draft.validationIssues.isEmpty {
                Section {
                    ForEach(draft.validationIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Connection") {
                HStack(spacing: 10) {
                    Button {
                        testConnection()
                    } label: {
                        Label("Test Connection", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canTest)
                    .help("Requests a token and lists computer device groups. Uses the values above, saved or not.")

                    Button {
                        save()
                    } label: {
                        Label(isDirty ? "Save Changes" : "Saved", systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("s")
                    .disabled(!isDirty)
                    .help("Saves the settings; the client secret goes to your Keychain (\u{2318}S)")

                    if isDirty {
                        Label("Unsaved changes", systemImage: "pencil.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                if let hint = nextStepHint {
                    Label(hint, systemImage: "arrow.turn.down.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ConnectionResultView(state: state)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Delete Tenant", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .help("Delete this tenant and its Keychain secret from this Mac")

                Button("Make Current", systemImage: "checkmark.circle") {
                    model.makeCurrent(draft.id)
                }
                .disabled(isCurrent)
                .help(isCurrent ? "This is the current tenant" : "Run migrations against this tenant")

                Button("Save", systemImage: "square.and.arrow.down") {
                    save()
                }
                .disabled(!isDirty)
                .help("Save the tenant settings and client secret (\u{2318}S)")

                Button("Test Connection", systemImage: "bolt.horizontal") {
                    testConnection()
                }
                .disabled(!canTest)
                .help("Request a token and list device groups to check the credentials")
            }
        }
        .confirmationDialog(
            "Delete \(draft.displayName)?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Tenant and Keychain Secret", role: .destructive) {
                model.delete(draft.id)
            }
        } message: {
            Text("This removes the saved settings and client secret from this Mac only. Nothing changes in Jamf.")
        }
        .confirmationDialog(
            "Allow classic scope changes for \(draft.displayName)?",
            isPresented: $confirmingClassicWrites
        ) {
            Button("Allow Scope Changes", role: .destructive) {
                draft.allowClassicScopeChanges = true
            }
        } message: {
            Text("""
            This is the only way the app can change anything in Jamf Pro classic. Once you save, it can replace the scope of a classic \
            profile (after the user opts in per profile and confirms). When Jamf Pro unscopes a profile it removes it from devices, \
            and on Macs where the in-place DDM transform didn't happen, the settings are lost. Test with one profile and one device first. \
            A backup of every scope is kept so it can be restored.
            """)
        }
        .onAppear {
            hasStoredSecret = model.hasStoredSecret(for: draft.id)
        }
    }

    private var canTest: Bool {
        draft.validationIssues.isEmpty && (!secret.isEmpty || hasStoredSecret) && state != .testing
    }

    /// One-line guidance for whatever the form still needs.
    private var nextStepHint: String? {
        if let issue = draft.validationIssues.first { return issue }
        if secret.isEmpty && !hasStoredSecret {
            return "Enter the client secret, then press Test Connection."
        }
        if case .idle = state, !isDirty {
            return "Press Test Connection to check the credentials."
        }
        if isDirty {
            return "Test Connection uses the values above as entered; press Save Changes to keep them."
        }
        return nil
    }

    private func testConnection() {
        let tenant = draft
        let override = secret
        Task { await model.testConnection(tenant, secretOverride: override) }
    }

    private func save() {
        model.save(draft, secret: secret)
        secret = ""
        hasStoredSecret = model.hasStoredSecret(for: draft.id)
    }
}

private struct ConnectionResultView: View {
    let state: ConnectionState

    var body: some View {
        switch state {
        case .idle:
            Text("Not tested yet. “Test Connection” requests a token and lists computer device groups.")
                .foregroundStyle(.secondary)
        case .testing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Requesting token and listing device groups…")
            }
        case let .succeeded(groups, date):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Connected. Token issued; \(groups.count) computer group\(groups.count == 1 ? "" : "s") found.",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
                Text("Checked \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !groups.isEmpty {
                    DeviceGroupTable(groups: groups)
                        .frame(minHeight: 160, idealHeight: 240)
                }
            }
        case let .failed(report):
            APIErrorView(report: report)
        }
    }
}

struct DeviceGroupTable: View {
    let groups: [PlatformGroup]

    var body: some View {
        Table(groups) {
            TableColumn("Name", value: \.name)
            TableColumn("Type") { Text($0.groupType.displayName) }
                .width(min: 60, ideal: 70)
            TableColumn("Devices") { Text($0.memberCount, format: .number).monospacedDigit() }
                .width(min: 60, ideal: 70)
            TableColumn("ID") { group in
                Text(group.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
