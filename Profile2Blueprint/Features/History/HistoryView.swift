import SwiftUI
import UniformTypeIdentifiers

/// The local action log, exportable as Markdown and JSON.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
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
                Table(records, sortOrder: $sortOrder) {
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
                        VStack(alignment: .leading) {
                            Text(record.blueprintName ?? "—")
                            if let id = record.blueprintID {
                                Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    TableColumn("Result") { record in
                        resultLabel(record.result)
                    }
                    .width(70)
                    TableColumn("Details") { record in
                        Text(record.message).lineLimit(2).help(record.message)
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
