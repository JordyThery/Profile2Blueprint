import Foundation
import Observation

/// Main-actor activity log for the UI, backed by `ActivityStore`.
@Observable
final class ActivityLog {
    private(set) var events: [ActivityEvent] = []
    private let store: ActivityStore

    init(store: ActivityStore) {
        self.store = store
        Task {
            // Merge the stored file with anything recorded while it was being read.
            let loaded = await store.all
            let known = Set(events.map(\.id))
            events = loaded.filter { !known.contains($0.id) } + events
        }
    }

    func append(_ event: ActivityEvent) {
        var safe = event
        safe.message = Redactor.redact(event.message)
        events.append(safe)
        if events.count > store.limit { events.removeFirst(events.count - store.limit) }
        Task { await store.append(event) }
    }

    func app(_ message: String, environment: String = "App", level: ActivityLevel = .info, category: ActivityCategory = .app) {
        append(ActivityEvent(environment: environment, category: category, level: level, message: message))
    }

    func clear() {
        events = []
        Task {
            await store.clear()
            await store.flush()
        }
    }

    /// A Sendable recorder that forwards to this log on the main actor.
    nonisolated var recorder: any ActivityRecorder { ActivitySink(log: self) }
}

private nonisolated struct ActivitySink: ActivityRecorder {
    let log: ActivityLog

    func record(_ event: ActivityEvent) {
        Task { @MainActor in log.append(event) }
    }
}
