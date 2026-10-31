import Foundation
import JTKit
import OSLog

/// Append-only local log of migration actions, stored as JSON in Application Support.
/// A file that can't be read is kept as it is and not written (`StoredList`).
actor HistoryStore {
    let fileURL: URL
    private var records: [MigrationRecord]
    private let list: StoredList<MigrationRecord>

    init(fileURL: URL) {
        self.fileURL = fileURL
        (records, list) = StoredList.open(fileURL)
    }

    static func appDefault() -> HistoryStore {
        HistoryStore(fileURL: StoredList<MigrationRecord>.appSupportFile("history.json"))
    }

    var all: [MigrationRecord] { records }

    /// Why the history isn't saved, when its file couldn't be read.
    var problem: String? { list.problem }

    /// Adds a record and writes the file; throws when it couldn't be written
    /// (the record stays in memory for this launch).
    func append(_ record: MigrationRecord) throws {
        var safe = record
        safe.message = Redaction.text(record.message)
        records.append(safe)
        do {
            try list.write(records)
        } catch {
            Log.app.error("Could not write history: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// Markdown and JSON renderings of the history log.
nonisolated enum HistoryExport {
    static func json(_ records: [MigrationRecord]) throws -> Data {
        try JSONFile.encode(records)
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
                cell("\(record.sourceProfileName) (\(record.platform.displayName) #\(record.sourceProfileID))"),
                cell(blueprint.isEmpty ? "—" : blueprint),
                record.result.title,
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
