import Foundation
import JTKit
import OSLog

/// One of the app's JSON lists in Application Support (`history.json`,
/// `scope-backups.json`, `sessions.json`), written with JTKit's `JSONFile`.
///
/// The same rule as `TenantStore`: a file that can't be read is copied once to
/// `<file>.unreadable-<date and time>` and is never written over, so a damaged
/// or newer-format file can't be replaced by a shorter list.
nonisolated struct StoredList<Element: Codable & Sendable>: Sendable {
    let fileURL: URL
    /// Why nothing is written, when the file couldn't be read.
    let problem: String?

    /// Reads the list. A missing file is an empty list.
    static func open(_ fileURL: URL) -> (records: [Element], list: StoredList) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ([], StoredList(fileURL: fileURL, problem: nil))
        }
        do {
            return (try JSONFile.load([Element].self, from: fileURL), StoredList(fileURL: fileURL, problem: nil))
        } catch {
            let name = fileURL.lastPathComponent
            Log.app.error("Could not read \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let copy = FileCopies.keepUnreadableCopy(of: fileURL)
            let problem = "“\(name)” couldn’t be read, so the app doesn’t save to it until it’s fixed."
                + (copy.map { " A copy is at \($0)." } ?? "")
            return ([], StoredList(fileURL: fileURL, problem: problem))
        }
    }

    /// Writes the whole list, or throws without writing while the file is unreadable.
    func write(_ records: [Element]) throws {
        if let problem { throw StoredListError(message: problem) }
        try JSONFile.save(records, to: fileURL)
    }

    /// `Profile2Blueprint/<name>` in Application Support (see `AppFiles`).
    static func appSupportFile(_ name: String) -> URL {
        AppFiles.file(name)
    }
}

/// Where the app keeps its own files: `Profile2Blueprint/` in Application
/// Support. Under the live-check switch (`LiveLaunch`) they go to the run's
/// folder for them instead, so a live check never reads or writes the real
/// tenants, history, scope backups or sessions.
nonisolated enum AppFiles {
    /// Worked out once: a refused switch gives a new temporary folder per call.
    private static let liveFolder = LiveLaunch.appFilesFolder("Profile2Blueprint")

    static func file(_ name: String) -> URL {
        if let liveFolder { return liveFolder.appending(path: name) }
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Profile2Blueprint/\(name)")
    }
}

nonisolated struct StoredListError: Error, LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}
