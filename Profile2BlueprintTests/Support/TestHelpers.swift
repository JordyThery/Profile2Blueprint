import Foundation

// The fake network is JTKit's (`MockURLProtocol` in JTKitTestSupport). Its
// handler is global, so suites that use it must be `.serialized`.

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Thread-safe counter for use inside `@Sendable` mock handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    /// Increments and returns the new value (first call returns 1).
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// Records requested sleeps instead of sleeping.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []

    var recorded: [Duration] { lock.withLock { durations } }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { durations.append(duration) }
    }
}
