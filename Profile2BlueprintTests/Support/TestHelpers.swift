import Foundation
import JTKit
@testable import Profile2Blueprint

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

/// A Blueprint as the server sends it, read through JTKit, with one
/// configuration-profile component (none when `configuration` is nil).
func blueprintDetail(
    id: String = "bp",
    name: String = "n",
    deviceGroups: [String],
    configuration: LosslessJSON.Object?,
    state: String = "NOT_DEPLOYED",
    lastDeployment: (started: String, state: String)? = nil
) throws -> JamfPlatform.BlueprintDetail {
    var deploymentState = LosslessJSON.Object(["state": .string(state)])
    if let lastDeployment {
        deploymentState["lastDeployment"] = .object(LosslessJSON.Object([
            "started": .string(lastDeployment.started), "state": .string(lastDeployment.state),
        ]))
    }
    let steps: [LosslessJSON] = configuration.map { configuration in
        [.object(LosslessJSON.Object([
            "name": .string("s"),
            "components": .array([.object(LosslessJSON.Object([
                "identifier": .string(BlueprintBuilder.componentIdentifier),
                "configuration": .object(configuration),
            ]))]),
        ]))]
    } ?? []
    let json = LosslessJSON.object(LosslessJSON.Object([
        "id": .string(id),
        "name": .string(name),
        "scope": .object(LosslessJSON.Object(["deviceGroups": .array(deviceGroups.map(LosslessJSON.string))])),
        "deploymentState": .object(deploymentState),
        "steps": .array(steps),
    ]))
    return try JamfPlatform.BlueprintDetail(data: json.serialized())
}

// MARK: - Demo mode

extension DemoJamfPlatformServer {
    /// JTKit's client for this server as demo mode builds it: the app's
    /// groups and Classic profiles added, its allow-list, a demo network.
    func client(log: ActivityLog?, classic: DemoClassicServer = DemoClassicServer()) -> JamfPlatform.Client {
        MigrationEnvironment.demoClient(log: log, server: self, classicServer: classic)
    }
}

/// The app's real Classic reader, answered by `classic` behind JTKit's demo server.
func demoClassicAPI(_ classic: DemoClassicServer = DemoClassicServer()) -> LiveClassicAPI {
    LiveClassicAPI(client: DemoJamfPlatformServer().client(log: nil, classic: classic))
}

/// The app's real scope writer, answered by `classic` behind JTKit's demo server.
func demoScopeWriter(_ classic: DemoClassicServer) -> LiveClassicScopeWriter {
    LiveClassicScopeWriter(client: DemoJamfPlatformServer().client(log: nil, classic: classic))
}
