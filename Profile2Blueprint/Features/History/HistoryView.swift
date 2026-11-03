import AppKit
import SwiftUI
import JTKit
import UniformTypeIdentifiers

/// The local action log, exportable as Markdown and JSON.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection: MigrationRecord.ID?
    @State private var exportDocument: TextExportDocument?
    @State private var exportFormat = HistoryExport.Format.markdown
    @State private var exportError: String?
    @State private var sortOrder = [KeyPathComparator(\MigrationRecord.timestamp, order: .reverse)]

    private var records: [MigrationRecord] {
        model.currentHistory.records
            .filter { record in
                search.isEmpty
                    || record.sourceProfileName.localizedCaseInsensitiveContains(search)
                    || record.tenantName.localizedCaseInsensitiveContains(search)
                    || (record.blueprintName ?? "").localizedCaseInsensitiveContains(search)
                    || (record.blueprintID ?? "").localizedCaseInsensitiveContains(search)
                    || record.message.localizedCaseInsensitiveContains(search)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if model.currentHistory.records.isEmpty {
                ContentUnavailableView("No Actions Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Dry runs, creates, verifications, deployments and classic cleanup are recorded here."))
            } else {
                Table(records, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Time", value: \.timestamp) { record in
                        Text(record.timestamp.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
                    }
                    .width(min: 150, ideal: 170)
                    TableColumn("Tenant", value: \.tenantName)
                        .width(min: 90, ideal: 120)
                    TableColumn("Action") { record in Text(record.action.title) }
                        .width(min: 110, ideal: 140)
                    TableColumn("Source profile") { record in
                        Text("\(record.sourceProfileName) (#\(record.sourceProfileID))")
                    }
                    TableColumn("Blueprint") { record in
                        Text(record.blueprintName ?? "—").lineLimit(1)
                    }
                    TableColumn("Result") { record in
                        resultLabel(record.result)
                    }
                    .width(70)
                    TableColumn("Details") { record in
                        Text(record.message).lineLimit(1).truncationMode(.tail)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let record = selection.flatMap({ id in model.currentHistory.records.first { $0.id == id } }) {
                        HistoryDetailPane(record: record)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Filter history")
        .navigationTitle("History")
        .toolbar {
            ToolbarItemGroup {
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Markdown…") { export(.markdown) }
                    Button("JSON…") { export(.json) }
                }
                .disabled(model.currentHistory.records.isEmpty)
            }
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            // Markdown is plain text; the name keeps its .md.
            contentType: exportFormat == .json ? .json : .plainText,
            defaultFilename: exportFormat == .json ? "Profile2Blueprint-history" : "Profile2Blueprint-history.md"
        ) { result in
            if case let .failure(error) = result { exportError = error.localizedDescription }
        }
        .alert("Export Failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func export(_ format: HistoryExport.Format) {
        do {
            let records = model.currentHistory.records
            let text = switch format {
            case .markdown: HistoryExport.markdown(records)
            case .json: String(decoding: try HistoryExport.json(records), as: UTF8.self)
            }
            exportFormat = format
            exportDocument = TextExportDocument(text: text)
        } catch {
            exportError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func resultLabel(_ result: MigrationResult) -> some View {
        switch result {
        case .success: Label(result.title, systemImage: "checkmark.circle.fill").labelStyle(.tintedIcon(.green))
        case .warning: WarningLabel(result.title)
        case .failure: Label(result.title, systemImage: "xmark.octagon.fill").labelStyle(.tintedIcon(.red))
        }
    }
}

/// Full details of the selected record, with everything selectable and copyable.
private struct HistoryDetailPane: View {
    let record: MigrationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.action.title).font(.headline)
                Text(record.timestamp.formatted(date: .abbreviated, time: .standard))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Details", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(clipboardText, forType: .string)
                }
                .help("Copy every field of this record")
            }

            Text(record.message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    field("Tenant", record.tenantName)
                    field("Source profile", "\(record.sourceProfileName) (\(record.platform.displayName) #\(record.sourceProfileID))")
                    field("Result", record.result.title)
                }
                if record.blueprintName != nil || record.blueprintID != nil {
                    GridRow {
                        if let name = record.blueprintName {
                            field("Blueprint", name)
                        }
                        if let id = record.blueprintID {
                            field("Blueprint ID", id, monospaced: true)
                        }
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func field(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
        }
    }

    private var clipboardText: String {
        var lines = [
            "Time: \(record.timestamp.formatted(.iso8601))",
            "Tenant: \(record.tenantName)",
            "Action: \(record.action.title)",
            "Platform: \(record.platform.displayName)",
            "Source profile: \(record.sourceProfileName) (#\(record.sourceProfileID))",
            "Result: \(record.result.title)",
        ]
        if let name = record.blueprintName { lines.append("Blueprint: \(name)") }
        if let id = record.blueprintID { lines.append("Blueprint ID: \(id)") }
        lines.append("Message: \(record.message)")
        return lines.joined(separator: "\n")
    }
}

#if DEBUG
#Preview("Detail pane") {
    HistoryDetailPane(record: MigrationRecord(
        timestamp: Date(),
        tenantName: "Jamf Pro",
        environmentID: "A1B2C3D4-0000-4000-8000-00000000000E",
        action: .unscopeClassic,
        sourceProfileID: 101,
        sourceProfileName: "Contoso – Managed Login Items",
        blueprintID: "5b1f7c2e-0000-4000-8000-000000000001",
        blueprintName: "Contoso – Managed Login Items (migrated)",
        result: .success,
        message: "Removed all scope targets from the classic profile (payloads untouched). Scope backup saved; restore is available."
    ))
    .frame(width: 900)
}
#endif
