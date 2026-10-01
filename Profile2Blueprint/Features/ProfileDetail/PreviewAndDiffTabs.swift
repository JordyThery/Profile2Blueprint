import SwiftUI

/// The exact JSON that will be POSTed.
struct BlueprintPreviewTab: View {
    @Bindable var session: MigrationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Blueprint name", text: $session.blueprintName)
                TextField("Description", text: $session.blueprintDescription, axis: .vertical)
                    .lineLimit(1...3)
                LabeledContent("Target groups") {
                    Text(session.selectedGroups.isEmpty ? "None selected (see Scope)" : session.selectedGroups.map(\.name).joined(separator: ", "))
                        .foregroundStyle(session.selectedGroups.isEmpty ? .orange : .primary)
                }
            }
            .formStyle(.grouped)
            .disabled(session.blueprintID != nil)
            .frame(maxHeight: 190)

            switch session.preview {
            case let .success(request):
                JSONTextView(json: request.body.serialized(), title: "POST /blueprints/v1/blueprints")
                if session.report.has(.sensitiveContent) {
                    Label("This body contains credentials from the profile. Treat copies of it as secrets.", systemImage: "key.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            case let .failure(error):
                VStack(alignment: .leading, spacing: 6) {
                    Text("The request can't be built yet:").font(.headline)
                    ForEach(error.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
        }
        .padding()
    }
}

/// Classic payload vs blueprint body, with Apple's five rules as a checklist.
struct DiffTab: View {
    let session: MigrationSession

    var body: some View {
        switch session.profile.document {
        case let .failure(error):
            Label(error.message, systemImage: "xmark.octagon").foregroundStyle(.red).padding()
        case let .success(document):
            let configuration = BlueprintBuilder.configuration(for: document, fallbackName: session.profile.name)
            VSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        RuleChecklistView(checks: FidelityVerifier.ruleChecklist(document: document, configuration: configuration),
                                          title: "Five-rule check (classic vs. built body)")
                        if let readBack = readBackConfiguration {
                            RuleChecklistView(checks: FidelityVerifier.ruleChecklist(document: document, configuration: readBack),
                                              title: "Five-rule check (classic vs. server read-back)")
                        }
                        GroupBox("Payload mapping") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Wrapper keys renamed at the top level of each payload:")
                                ForEach(PlistToJSON.wrapperKeyMap.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                    Text("\(key) → \(value)").font(.callout.monospaced())
                                }
                                Text("All other keys, including nested ones like Rules / RuleType / RuleValue, keep their Apple casing. <data> becomes Base64 and <date> becomes ISO 8601.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                    }
                    .padding()
                }
                .frame(minHeight: 220)

                HSplitView {
                    JSONTextView(json: JSONValue.object(PlistToJSON.convert(document.root)).serialized(), title: "Classic payload (plist as JSON)")
                        .padding(8)
                    JSONTextView(json: JSONValue.object(configuration).serialized(), title: "Blueprint configuration")
                        .padding(8)
                }
                .frame(minHeight: 240)
            }
        }
    }

    private var readBackConfiguration: JSONObject? {
        session.readBack?.steps.flatMap(\.components)
            .first { $0.identifier == BlueprintBuilder.componentIdentifier }?
            .configuration?.objectValue
    }
}

struct RuleChecklistView: View {
    let checks: [FidelityVerifier.RuleCheck]
    let title: String

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(checks) { check in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        icon(check.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(check.number). \(check.title)").fontWeight(.medium)
                            Text(check.detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private func icon(_ status: FidelityVerifier.RuleStatus) -> some View {
        switch status {
        case .pass:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Pass")
        case .fail:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Fail")
        case .confirmOnDevice:
            Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange).accessibilityLabel("Confirm manually")
        }
    }
}

#if DEBUG
#Preview("Blueprint preview") {
    let workspace = Workspace.previewDemo()
    BlueprintPreviewTab(session: workspace.session(for: 101)!)
        .frame(width: 800, height: 700)
}

#Preview("Diff") {
    let workspace = Workspace.previewDemo()
    DiffTab(session: workspace.session(for: 102)!)
        .frame(width: 900, height: 800)
}
#endif
