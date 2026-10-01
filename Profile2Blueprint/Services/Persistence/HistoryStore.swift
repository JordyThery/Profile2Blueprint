import Foundation
import OSLog

/// Append-only local log of migration actions, stored as JSON in Application Support.
actor HistoryStore {
    let fileURL: URL
    private var records: [MigrationRecord]

    init(fileURL: URL) {
        self.fileURL = fileURL
        records = Self.load(from: fileURL)
    }

    static func appDefault() -> HistoryStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return HistoryStore(fileURL: base.appending(path: "Profile2Blueprint/history.json"))
    }

    var all: [MigrationRecord] { records }

    @discardableResult
    func append(_ record: MigrationRecord) -> [MigrationRecord] {
        var safe = record
        safe.message = Redactor.redact(record.message)
        records.append(safe)
        persist()
        return records
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HistoryExport.json(records).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Could not write history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [MigrationRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MigrationRecord].self, from: data)) ?? []
    }
}

/// Markdown and JSON renderings of the history log.
nonisolated enum HistoryExport {
    static func json(_ records: [MigrationRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(records)
    }

    static func markdown(_ records: [MigrationRecord]) -> String {
        var lines = [
            "# Profile2Blueprint migration history",
            "",
            "Exported \(Date().formatted(.iso8601)). \(records.count) action\(records.count == 1 ? "" : "s").",
            "",
            "| Timestamp | Tenant | Action | Source profile | Blueprint | Result | Details |",
            "|---|---|---|---|---|---|---|",
        ]
        for record in records {
            let blueprint = [record.blueprintName, record.blueprintID.map { "`\($0)`" }].compactMap { $0 }.joined(separator: " ")
            lines.append("| " + [
                record.timestamp.formatted(.iso8601),
                cell(record.tenantName),
                record.action.title,
                cell("\(record.sourceProfileName) (#\(record.sourceProfileID))"),
                cell(blueprint.isEmpty ? "—" : blueprint),
                record.result.rawValue,
                cell(record.message),
            ].joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes pipes and newlines so a value stays in one table cell.
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
