import Foundation
import OSLog

/// Persists the activity log as JSON in Application Support, keeping the newest `limit` events.
actor ActivityStore {
    let fileURL: URL
    let limit: Int
    private var events: [ActivityEvent]
    private var pendingWrite: Task<Void, Never>?

    init(fileURL: URL, limit: Int = 10_000) {
        self.fileURL = fileURL
        self.limit = limit
        events = Self.load(from: fileURL)
    }

    static func appDefault() -> ActivityStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return ActivityStore(fileURL: base.appending(path: "Profile2Blueprint/activity.json"))
    }

    var all: [ActivityEvent] { events }

    func append(_ event: ActivityEvent) {
        var safe = event
        safe.message = Redactor.redact(event.message)
        events.append(safe)
        if events.count > limit { events.removeFirst(events.count - limit) }
        scheduleWrite()
    }

    func clear() {
        events = []
        scheduleWrite()
    }

    /// Writes immediately; used by tests and on clear.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        write()
    }

    /// Coalesces bursts (e.g. paginated loads) into one write.
    private func scheduleWrite() {
        guard pendingWrite == nil else { return }
        pendingWrite = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.pendingWrite = nil
            self.write()
        }
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ActivityExport.json(events).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Could not write activity log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ActivityEvent].self, from: data)) ?? []
    }
}

nonisolated enum ActivityExport {
    static func json(_ events: [ActivityEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(events)
    }

    static func markdown(_ events: [ActivityEvent]) -> String {
        var lines = [
            "# Profile2Blueprint activity log",
            "",
            "Exported \(Date().formatted(.iso8601)). \(events.count) event\(events.count == 1 ? "" : "s").",
            "",
            "| Timestamp | Environment | Category | Level | Request | Status | ms | Trace ID | Message |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        for event in events {
            let request = [event.method, event.path].compactMap { $0 }.joined(separator: " ")
            lines.append("| " + [
                event.timestamp.formatted(.iso8601),
                cell(event.environment),
                event.category.title,
                event.level.rawValue,
                cell(request.isEmpty ? "—" : "`\(request)`"),
                event.status.map(String.init) ?? "—",
                event.durationMs.map(String.init) ?? "—",
                event.traceId.map { "`\($0)`" } ?? "—",
                cell(event.message),
            ].joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
