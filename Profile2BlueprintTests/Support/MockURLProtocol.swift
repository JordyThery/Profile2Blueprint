import Foundation
@testable import Profile2Blueprint

/// A captured request, with the body read out of `httpBodyStream`.
struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data

    var path: String { url.path() }

    func queryValue(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var bodyString: String { String(decoding: body, as: UTF8.self) }
}

struct MockResponse: Sendable {
    var status: Int
    var headers: [String: String] = ["Content-Type": "application/json"]
    var body: Data

    static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> MockResponse {
        MockResponse(
            status: status,
            headers: ["Content-Type": "application/json"].merging(headers) { $1 },
            body: Data(text.utf8)
        )
    }
}

/// Routes every request on a session to a test-provided handler.
///
/// The handler is global, so suites that use it must be `.serialized`.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (RecordedRequest) throws -> MockResponse

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [RecordedRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static var requests: [RecordedRequest] {
        lock.withLock { recorded }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recordedRequest = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.readStream(request.httpBodyStream)
        )
        let handler = Self.lock.withLock { () -> Handler? in
            Self.recorded.append(recordedRequest)
            return Self.handler
        }

        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let mock = try handler(recordedRequest)
            let response = HTTPURLResponse(
                url: recordedRequest.url, statusCode: mock.status, httpVersion: "HTTP/1.1", headerFields: mock.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: mock.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A manually advanced clock for token-expiry tests.
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
