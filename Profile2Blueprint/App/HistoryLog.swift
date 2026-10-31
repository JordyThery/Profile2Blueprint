import Foundation
import JTKit
import Observation

/// Main-actor mirror of `HistoryStore` for the UI.
@Observable
final class HistoryLog {
    private(set) var records: [MigrationRecord] = []
    private let store: HistoryStore
    private let activity: ActivityLog?
    /// Called on the main actor when a record couldn't be saved to the file;
    /// the app shows it in its "Couldn’t Save" alert.
    @ObservationIgnored var onSaveFailure: ((String) -> Void)?

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
            platform: profile.platform,
            sourceProfileID: profile.id,
            sourceProfileName: profile.name,
            blueprintID: blueprintID,
            blueprintName: blueprintName,
            result: result,
            message: Redaction.text(message)
        )
        records.append(entry)
        activity?.app(
            "\(action.title) — \(profile.name) (#\(profile.id))\(blueprintID.map { " → blueprint \($0)" } ?? ""): \(message)",
            environment: environment.displayName,
            level: result == .failure ? .error : (result == .warning ? .warning : .info),
            category: action == .unscopeClassic || action == .restoreClassicScope ? .classicWrite : .migration
        )
        Task { [store, activity] in
            do {
                try await store.append(entry)
            } catch {
                let message = "The history couldn’t be saved: \(error.localizedDescription)"
                activity?.app(message, environment: environment.displayName, level: .error)
                onSaveFailure?(message)
            }
        }
    }
}
