import Foundation

/// Where demo mode keeps its history, scope backups and migration sessions:
/// a folder of its own in the app's temporary directory, new for each launch
/// (the app uses JTKit's `DemoMode.scratchDirectory`). Demo runs never write into the real `history.json`,
/// `scope-backups.json` or `sessions.json`, and are gone after a restart.
nonisolated struct DemoFiles: Sendable {
    let folder: URL
    /// One store per file, opened once, so no two copies overwrite each other.
    let history: HistoryStore
    let scopeBackups: ScopeBackupStore
    let sessionStates: SessionStateStore

    init(folder: URL) {
        self.folder = folder
        history = HistoryStore(fileURL: folder.appending(path: "history.json"))
        scopeBackups = ScopeBackupStore(fileURL: folder.appending(path: "scope-backups.json"))
        sessionStates = SessionStateStore(fileURL: folder.appending(path: "sessions.json"))
    }
}
