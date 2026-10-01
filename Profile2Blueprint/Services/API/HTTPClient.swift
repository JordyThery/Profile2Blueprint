import Foundation
import OSLog

nonisolated struct HTTPRequest: Sendable {
    var method: String = "GET"
    /// Path relative to the gateway base URL, e.g. `device-groups/v1/device-groups`.
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var accept: String = "application/json"
    var contentType: String?
}

nonisolated struct HTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

nonisolated struct RetryPolicy: Sendable {
    var maxRetries: Int = 3
    var baseDelay: Duration = .seconds(1)
    var maxDelay: Duration = .seconds(30)

    /// Exponential backoff: base, 2×base, 4×base…, capped at `maxDelay`.
    func delay(forAttempt attempt: Int) -> Duration {
        let factor = 1 << min(attempt, 10)
        return min(baseDelay * factor, maxDelay)
    }
}

/// Whether Classic API writes are allowed. Off unless the user explicitly enables
/// "classic scope changes" for the tenant; even then only scope-only PUTs pass.
nonisolated enum ClassicWritePolicy: Sendable, Hashable {
    case denied
    case scopeOnly
}

/// Authenticated client for the Jamf Platform API Gateway.
///
/// Adds the bearer token and `X-Environment-Id` to every request, retries once on 401
/// with a fresh token, and backs off on 429 (and on 502/503/504 for GETs). Every
/// request, retry and refusal is reported to the activity recorder.
nonisolated final class HTTPClient: Sendable {
    let baseURL: URL
    let environmentID: String
    let classicWritePolicy: ClassicWritePolicy
    private let environmentName: String
    private let tokens: TokenProvider
    private let session: URLSession
    private let retryPolicy: RetryPolicy
    private let activity: any ActivityRecorder
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        baseURL: URL,
        environmentID: String,
        tokens: TokenProvider,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = RetryPolicy(),
        classicWritePolicy: ClassicWritePolicy = .denied,
        environmentName: String = "",
        activity: any ActivityRecorder = NullActivityRecorder(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.baseURL = baseURL
        self.environmentID = environmentID
        self.tokens = tokens
        self.session = session
        self.retryPolicy = retryPolicy
        self.classicWritePolicy = classicWritePolicy
        self.environmentName = environmentName.isEmpty ? (baseURL.host() ?? "") : environmentName
        self.activity = activity
        self.sleep = sleep
    }

    func url(for request: HTTPRequest) -> URL {
        let url = baseURL.appending(path: request.path)
        guard !request.query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.percentEncodedQuery = FormEncoding.encode(request.query)
        return components.url ?? url
    }

    /// Safety net, checked before anything reaches the network. Allowed:
    /// - any GET;
    /// - POST to create a blueprint or deploy one;
    /// - only with `.scopeOnly`: PUT to `proclassic/osxconfigurationprofiles/id/{n}` whose
    ///   XML body contains nothing but `<scope>`.
    /// Everything else (PATCH, DELETE, undeploy, device-group writes, payload edits) is refused.
    static func isPermitted(_ request: HTTPRequest, classicWrites: ClassicWritePolicy = .denied) -> Bool {
        switch request.method {
        case "GET":
            return true
        case "POST":
            let path = request.path.split(separator: "/").map(String.init)
            // blueprints/v1/blueprints  or  blueprints/v1/blueprints/{id}/deploy
            guard path.count >= 3, path[0] == "blueprints", path[2] == "blueprints" else { return false }
            return path.count == 3 || (path.count == 5 && path[4] == "deploy")
        case "PUT":
            guard classicWrites == .scopeOnly,
                  request.path.wholeMatch(of: /proclassic\/osxconfigurationprofiles\/id\/\d+/) != nil,
                  let body = request.body else { return false }
            return isScopeOnlyProfileXML(body)
        default:
            return false
        }
    }

    /// `<os_x_configuration_profile>` with exactly one child element, `<scope>`.
    static func isScopeOnlyProfileXML(_ data: Data) -> Bool {
        guard let document = try? XMLDocument(data: data, options: []),
              let root = document.rootElement(), root.name == "os_x_configuration_profile" else { return false }
        let children = (root.children ?? []).compactMap { $0 as? XMLElement }
        return children.count == 1 && children[0].name == "scope"
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard Self.isPermitted(request, classicWrites: classicWritePolicy) else {
            activity.record(ActivityEvent(environment: environmentName, category: .blocked, level: .warning,
                                          message: "Refused before sending: not on the allow-list.",
                                          method: request.method, path: request.path))
            throw APIError.invalidConfiguration("Blocked \(request.method) \(request.path): this app only reads, creates and deploys blueprints"
                + (request.method == "PUT" ? ", and changes classic scope only when that is explicitly enabled." : "."))
        }
        var retries = 0
        var refreshedAuth = false
        let category: ActivityCategory = request.method == "PUT" ? .classicWrite : .request

        while true {
            try Task.checkCancellation()
            let token = try await tokens.validToken()
            let started = ContinuousClock.now
            let response: HTTPResponse
            do {
                response = try await perform(request, token: token)
            } catch {
                activity.record(ActivityEvent(environment: environmentName, category: category, level: .error,
                                              message: error.localizedDescription, method: request.method, path: request.path,
                                              durationMs: Self.milliseconds(since: started)))
                throw error
            }
            let body = (200..<300).contains(response.status) ? nil : APIErrorBody.parse(response.data)
            activity.record(ActivityEvent(
                environment: environmentName, category: category,
                level: (200..<300).contains(response.status) ? .info : (response.status >= 500 || response.status == 403 ? .error : .warning),
                message: body?.errors.first.map { "\($0.code): \($0.description)" } ?? Self.statusPhrase(response.status),
                method: request.method, path: request.path, status: response.status,
                durationMs: Self.milliseconds(since: started), traceId: body?.traceId
            ))

            switch response.status {
            case 200..<300:
                return response
            case 401 where !refreshedAuth:
                Log.network.info("401 from \(request.path, privacy: .public); refreshing token and retrying once")
                activity.record(ActivityEvent(environment: environmentName, category: .retry, level: .warning,
                                              message: "401: refreshing the token and retrying once.", method: request.method, path: request.path))
                await tokens.invalidate()
                refreshedAuth = true
                continue
            default:
                break
            }

            let retryable = response.status == 429
                || (request.method == "GET" && [502, 503, 504].contains(response.status))
            if retryable && retries < retryPolicy.maxRetries {
                let delay = retryAfter(response) ?? retryPolicy.delay(forAttempt: retries)
                retries += 1
                Log.network.info("HTTP \(response.status) from \(request.path, privacy: .public); retry \(retries) after \(delay)")
                activity.record(ActivityEvent(environment: environmentName, category: .retry, level: .warning,
                                              message: "HTTP \(response.status): retry \(retries) of \(retryPolicy.maxRetries) after \(delay).",
                                              method: request.method, path: request.path, status: response.status))
                try await sleep(delay)
                continue
            }

            throw APIError.http(
                status: response.status,
                method: request.method,
                path: request.path,
                body: body,
                rawBody: Redactor.redactedBody(response.data)
            )
        }
    }

    /// Short HTTP status phrases for the activity log.
    static func statusPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No content"
        default: "HTTP \(status)"
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        let response = try await send(HTTPRequest(path: path, query: query))
        return try decode(type, from: response)
    }

    func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.data)
        } catch {
            throw APIError.decoding("\(T.self): \(error)")
        }
    }

    private func perform(_ request: HTTPRequest, token: String) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: url(for: request))
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(environmentID, forHTTPHeaderField: "X-Environment-Id")
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        if let contentType = request.contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            Log.network.error("\(request.method, privacy: .public) \(request.path, privacy: .public) transport error: \(error.localizedDescription, privacy: .public)")
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("No HTTP response.")
        }
        Log.network.debug("\(request.method, privacy: .public) \(request.path, privacy: .public) → \(http.statusCode)")

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, data: data)
    }

    /// Honours an integer `Retry-After` header, capped by the policy's max delay.
    private func retryAfter(_ response: HTTPResponse) -> Duration? {
        guard let value = response.header("Retry-After"), let seconds = Int(value.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return min(.seconds(max(seconds, 0)), retryPolicy.maxDelay)
    }
}
