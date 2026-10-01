import Foundation
import Observation

/// Main-actor mirror of `HistoryStore` for the UI.
@Observable
final class HistoryLog {
    private(set) var records: [MigrationRecord] = []
    private let store: HistoryStore
    private let activity: ActivityLog?

    init(store: HistoryStore, activity: ActivityLog? = nil) {
        self.store = store
        self.activity = activity
        Task {
            // Merge the stored file with anything recorded while it was being read.
            let loaded = await store.all
            let known = Set(records.map(\.id))
            records = loaded.filter { !known.contains($0.id) } + records
        }
    }

    func record(
        _ action: MigrationAction,
        environment: MigrationEnvironment,
        profile: ClassicProfile,
        blueprintID: String? = nil,
        blueprintName: String? = nil,
        result: MigrationResult,
        message: String
    ) {
        let entry = MigrationRecord(
            timestamp: Date(),
            tenantName: environment.displayName,
            environmentID: environment.environmentID,
            action: action,
            sourceProfileID: profile.id,
            sourceProfileName: profile.name,
            blueprintID: blueprintID,
            blueprintName: blueprintName,
            result: result,
            message: message
        )
        records.append(entry)
        activity?.append(ActivityEvent(
            environment: environment.displayName,
            category: action == .unscopeClassic || action == .restoreClassicScope ? .classicWrite : .migration,
            level: result == .failure ? .error : (result == .warning ? .warning : .info),
            message: "\(action.title) — \(profile.name) (#\(profile.id))\(blueprintID.map { " → blueprint \($0)" } ?? ""): \(message)"
        ))
        Task { _ = await store.append(entry) }
    }
}
