import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything the app has done: token requests, every API call, retries, refusals,
/// classic writes, migration steps and settings changes. Selecting a row shows the
/// full details below the table.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var category: ActivityCategory?
    @State private var problemsOnly = false
    @State private var selection: ActivityEvent.ID?
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

    private var selectedEvent: ActivityEvent? {
        selection.flatMap { id in model.activity.events.first { $0.id == id } }
    }

    var body: some View {
        Group {
            if model.activity.events.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Token requests, API calls, retries, refused writes and migration steps appear here."))
            } else {
                table
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let event = selectedEvent {
                            ActivityDetailPane(event: event)
                        }
                    }
            }
        }
        .searchable(text: $search, prompt: "Filter by message, path or trace ID")
        .navigationTitle("Activity")
        .navigationSubtitle("\(events.count) of \(model.activity.events.count) events")
        .toolbar { toolbarContent }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: exportDocument?.format == .json ? .json : .markdownText,
            defaultFilename: "Profile2Blueprint-activity"
        ) { _ in }
        .confirmationDialog("Clear the activity log?", isPresented: $confirmingClear) {
            Button("Clear Activity Log", role: .destructive) {
                selection = nil
                model.activity.clear()
                model.activity.app("Activity log cleared.")
            }
        } message: {
            Text("Deletes the local activity log on this Mac. Migration history and scope backups are kept.")
        }
    }

    private var table: some View {
        Table(events, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Time", value: \.timestamp) { event in
                Text(event.timestamp, format: .dateTime.day().month(.abbreviated).hour().minute().second())
                    .monospacedDigit()
            }
            .width(min: 130, ideal: 140)
            TableColumn("Category") { event in
                Label {
                    Text(event.category.title)
                } icon: {
                    levelIcon(event.level)
                }
            }
            .width(min: 100, ideal: 120)
            TableColumn("Request") { event in
                if let path = event.path {
                    Text("\(event.method ?? "GET") \(path)")
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 150, ideal: 280)
            TableColumn("Status") { event in
                Text(event.status.map(String.init) ?? "")
                    .monospacedDigit()
                    .foregroundStyle((event.status ?? 200) >= 400 ? .red : .secondary)
            }
            .width(44)
            TableColumn("ms") { event in
                Text(event.durationMs.map(String.init) ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(44)
            TableColumn("Message") { event in
                Text(event.message)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Category", selection: $category) {
                Text("All categories").tag(ActivityCategory?.none)
                Divider()
                ForEach(ActivityCategory.allCases) { Text($0.title).tag(ActivityCategory?.some($0)) }
            }
            .frame(width: 160)
            .help("Show one category of events")
            Toggle("Problems only", systemImage: "exclamationmark.triangle", isOn: $problemsOnly)
                .help("Show only warnings and errors")
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("Markdown…") { exportDocument = HistoryDocument(data: Data(ActivityExport.markdown(events).utf8), format: .markdown) }
                Button("JSON…") {
                    if let data = try? ActivityExport.json(events) { exportDocument = HistoryDocument(data: data, format: .json) }
                }
            }
            .disabled(events.isEmpty)
            .help("Export the events currently shown")
            Button("Clear", systemImage: "trash") { confirmingClear = true }
                .disabled(model.activity.events.isEmpty)
                .help("Delete the activity log from this Mac")
        }
    }

    @ViewBuilder
    private func levelIcon(_ level: ActivityLevel) -> some View {
        switch level {
        case .info:
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary).accessibilityLabel("Info")
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Warning")
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Error")
        }
    }
}

/// Full details of the selected event, with everything selectable and copyable.
private struct ActivityDetailPane: View {
    let event: ActivityEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.category.title).font(.headline)
                Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Details", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(clipboardText, forType: .string)
                }
                .help("Copy every field of this event")
            }

            Text(event.message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    field("Environment", event.environment)
                    if let path = event.path {
                        field("Request", "\(event.method ?? "GET") \(path)", monospaced: true)
                    }
                }
                GridRow {
                    if let status = event.status {
                        field("Status", String(status))
                    }
                    if let duration = event.durationMs {
                        field("Duration", "\(duration) ms")
                    }
                    if let traceId = event.traceId {
                        field("Trace ID", traceId, monospaced: true)
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
            "Time: \(event.timestamp.formatted(.iso8601))",
            "Category: \(event.category.title)",
            "Level: \(event.level.rawValue)",
            "Environment: \(event.environment)",
        ]
        if let path = event.path { lines.append("Request: \(event.method ?? "GET") \(path)") }
        if let status = event.status { lines.append("Status: \(status)") }
        if let duration = event.durationMs { lines.append("Duration: \(duration) ms") }
        if let traceId = event.traceId { lines.append("Trace ID: \(traceId)") }
        lines.append("Message: \(event.message)")
        return lines.joined(separator: "\n")
    }
}

#if DEBUG
#Preview {
    let temp = FileManager.default.temporaryDirectory
    let model = AppModel(
        store: TenantStore(fileURL: temp.appending(path: "preview-tenants-\(UUID().uuidString).json")),
        secrets: InMemorySecretStore(),
        history: HistoryStore(fileURL: temp.appending(path: "preview-history-\(UUID().uuidString).json")),
        activity: ActivityStore(fileURL: temp.appending(path: "preview-activity-\(UUID().uuidString).json")),
        demoMode: true
    )
    model.activity.append(ActivityEvent(environment: "Jamf Pro", category: .auth,
                                        message: "Access token issued, valid 900 s.", method: "POST", path: "/auth/token", status: 200))
    model.activity.append(ActivityEvent(environment: "Jamf Pro", category: .request, message: "OK",
                                        method: "GET", path: "device-groups/v1/device-groups", status: 200, durationMs: 1547))
    model.activity.append(ActivityEvent(environment: "Jamf Pro", category: .request, level: .warning,
                                        message: "INVALID_FIELD: scope.deviceGroups must not be empty",
                                        method: "POST", path: "blueprints/v1/blueprints", status: 400, durationMs: 230,
                                        traceId: "bdacd3d34c6d8c7f"))
    model.activity.append(ActivityEvent(environment: "Jamf Pro", category: .migration,
                                        message: "Create (not deployed) — P2B Test – notifications profile (#475) → blueprint 2f93c32f: Created, not deployed. Scope: P2B Test – one Mac."))
    model.activity.append(ActivityEvent(environment: "App", category: .blocked, level: .warning,
                                        message: "Refused before sending: not on the allow-list.", method: "DELETE", path: "blueprints/v1/blueprints/x"))
    return ActivityView()
        .environment(model)
        .frame(width: 1150, height: 600)
}
#endif
