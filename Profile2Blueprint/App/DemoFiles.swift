import Foundation

/// Where offline demo mode keeps its history, scope backups and migration
/// sessions: a folder of its own in the app's temporary directory, new for each
/// launch. Demo runs never write into the real `history.json`,
/// `scope-backups.json` or `sessions.json`, and are gone after a restart.
nonisolated struct DemoFiles: Sendable {
    let folder: URL

    init(folder: URL = FileManager.default.temporaryDirectory
        .appending(path: "Profile2Blueprint-demo-\(UUID().uuidString)", directoryHint: .isDirectory)) {
        self.folder = folder
    }

    var history: HistoryStore { HistoryStore(fileURL: folder.appending(path: "history.json")) }
    var scopeBackups: ScopeBackupStore { ScopeBackupStore(fileURL: folder.appending(path: "scope-backups.json")) }
    var sessionStates: SessionStateStore { SessionStateStore(fileURL: folder.appending(path: "sessions.json")) }
}
