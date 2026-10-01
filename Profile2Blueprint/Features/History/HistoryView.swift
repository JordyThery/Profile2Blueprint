import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The local action log, exportable as Markdown and JSON.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection: MigrationRecord.ID?
    @State private var exportDocument: HistoryDocument?
    @State private var exportError: String?
    @State private var sortOrder = [KeyPathComparator(\MigrationRecord.timestamp, order: .reverse)]

    private var records: [MigrationRecord] {
        model.history.records
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
            if model.history.records.isEmpty {
                ContentUnavailableView("No Actions Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Dry runs, creates, verifications and deployments are recorded here."))
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
                    if let record = selection.flatMap({ id in model.history.records.first { $0.id == id } }) {
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
                .disabled(model.history.records.isEmpty)
            }
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: exportDocument?.format == .json ? .json : .markdownText,
            defaultFilename: "Profile2Blueprint-history"
        ) { result in
            if case let .failure(error) = result { exportError = error.localizedDescription }
        }
        .alert("Export Failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func export(_ format: HistoryDocument.Format) {
        do {
            exportDocument = try HistoryDocument(records: model.history.records, format: format)
        } catch {
            exportError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func resultLabel(_ result: MigrationResult) -> some View {
        switch result {
        case .success: Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Label("Warn", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failure: Label("Fail", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
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
                    field("Source profile", "\(record.sourceProfileName) (#\(record.sourceProfileID))")
                    field("Result", record.result.rawValue.capitalized)
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
            "Source profile: \(record.sourceProfileName) (#\(record.sourceProfileID))",
            "Result: \(record.result.rawValue)",
        ]
        if let name = record.blueprintName { lines.append("Blueprint: \(name)") }
        if let id = record.blueprintID { lines.append("Blueprint ID: \(id)") }
        lines.append("Message: \(record.message)")
        return lines.joined(separator: "\n")
    }
}

extension UTType {
    nonisolated static let markdownText = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
}

struct HistoryDocument: FileDocument {
    enum Format { case markdown, json }

    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.markdownText, .json] }

    let format: Format
    let data: Data

    init(records: [MigrationRecord], format: Format) throws {
        self.format = format
        switch format {
        case .markdown: data = Data(HistoryExport.markdown(records).utf8)
        case .json: data = try HistoryExport.json(records)
        }
    }

    init(data: Data, format: Format) {
        self.format = format
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview("Detail pane") {
    HistoryDetailPane(record: MigrationRecord(
        timestamp: Date(),
        tenantName: "Jamf Pro",
        environmentID: "50c1c4f3-1a2e-42e4-b3c0-e24854250b67",
        action: .unscopeClassic,
        sourceProfileID: 475,
        sourceProfileName: "P2B Test – notifications profile",
        blueprintID: "2f93c32f-6837-40bf-90b9-10d3ea32f752",
        blueprintName: "P2B Test – notifications profile (migrated)",
        result: .success,
        message: "Removed all scope targets from the classic profile (payloads untouched). Scope backup saved; restore is available."
    ))
    .frame(width: 900)
}
