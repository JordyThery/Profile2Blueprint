import SwiftUI
import UniformTypeIdentifiers

/// Everything the app has done: token requests, every API call, retries, refusals,
/// classic writes, migration steps and settings changes.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var category: ActivityCategory?
    @State private var problemsOnly = false
    @State private var exportDocument: HistoryDocument?
    @State private var confirmingClear = false
    @State private var sortOrder = [KeyPathComparator(\ActivityEvent.timestamp, order: .reverse)]

    private var events: [ActivityEvent] {
        model.activity.events
            .filter { event in
                (category == nil || event.category == category)
                    && (!problemsOnly || event.level > .info)
                    && (search.isEmpty
                        || event.message.localizedCaseInsensitiveContains(search)
                        || (event.path ?? "").localizedCaseInsensitiveContains(search)
                        || (event.traceId ?? "").localizedCaseInsensitiveContains(search)
                        || event.environment.localizedCaseInsensitiveContains(search))
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if model.activity.events.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Every token request, API call, retry, refused write and migration step appears here."))
            } else {
                Table(events, sortOrder: $sortOrder) {
                    TableColumn("Time", value: \.timestamp) { event in
                        Text(event.timestamp.formatted(date: .numeric, time: .standard)).monospacedDigit()
                    }
                    .width(min: 140, ideal: 160)
                    TableColumn("") { event in levelIcon(event.level) }
                        .width(18)
                    TableColumn("Category") { event in Text(event.category.title) }
                        .width(min: 80, ideal: 100)
                    TableColumn("Environment", value: \.environment)
                        .width(min: 80, ideal: 110)
                    TableColumn("Request") { event in
                        Text([event.method, event.path].compactMap { $0 }.joined(separator: " "))
                            .font(.caption.monospaced())
                            .help([event.method, event.path].compactMap { $0 }.joined(separator: " "))
                    }
                    .width(min: 160, ideal: 260)
                    TableColumn("Status") { event in
                        Text(event.status.map(String.init) ?? "").monospacedDigit()
                            .foregroundStyle((event.status ?? 200) >= 400 ? .red : .primary)
                    }
                    .width(50)
                    TableColumn("ms") { event in
                        Text(event.durationMs.map(String.init) ?? "").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(50)
                    TableColumn("Message") { event in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.message).lineLimit(2).help(event.message)
                            if let trace = event.traceId {
                                Text("trace \(trace)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Filter by message, path or trace ID")
        .navigationTitle("Activity")
        .navigationSubtitle("\(events.count) of \(model.activity.events.count) events")
        .toolbar {
            ToolbarItemGroup {
                Picker("Category", selection: $category) {
                    Text("All categories").tag(ActivityCategory?.none)
                    Divider()
                    ForEach(ActivityCategory.allCases) { Text($0.title).tag(ActivityCategory?.some($0)) }
                }
                .frame(width: 160)
                Toggle("Problems only", systemImage: "exclamationmark.triangle", isOn: $problemsOnly)
                    .help("Show only warnings and errors")
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Markdown…") { exportDocument = HistoryDocument(data: Data(ActivityExport.markdown(events).utf8), format: .markdown) }
                    Button("JSON…") {
                        if let data = try? ActivityExport.json(events) { exportDocument = HistoryDocument(data: data, format: .json) }
                    }
                }
                .disabled(events.isEmpty)
                .help("Exports the events currently shown")
                Button("Clear", systemImage: "trash") { confirmingClear = true }
                    .disabled(model.activity.events.isEmpty)
            }
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: exportDocument?.format == .json ? .json : .markdownText,
            defaultFilename: "Profile2Blueprint-activity"
        ) { _ in }
        .confirmationDialog("Clear the activity log?", isPresented: $confirmingClear) {
            Button("Clear Activity Log", role: .destructive) {
                model.activity.clear()
                model.activity.app("Activity log cleared.")
            }
        } message: {
            Text("This deletes the local activity log on this Mac. Migration history and scope backups are kept.")
        }
    }

    @ViewBuilder
    private func levelIcon(_ level: ActivityLevel) -> some View {
        switch level {
        case .info: Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary).accessibilityLabel("Info")
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Warning")
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Error")
        }
    }
}
