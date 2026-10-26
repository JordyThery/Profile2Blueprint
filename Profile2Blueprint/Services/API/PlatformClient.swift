import Foundation
import JTKit

/// Whether Classic API writes are allowed. Off unless the user explicitly enables
/// "classic scope changes" for the tenant; even then only scope-only PUTs pass.
nonisolated enum ClassicWritePolicy: Sendable, Hashable {
    case denied
    case scopeOnly
}

/// Profile2Blueprint's side of JTKit's HTTP client for the Jamf Platform API
/// gateway: which requests may be sent at all, and failures as the app shows
/// them (`APIError`). Tokens, retries and the activity log are JTKit's.
nonisolated struct PlatformClient: Sendable {
    let http: HTTPClient
    let classicWritePolicy: ClassicWritePolicy

    /// A client for one tenant's gateway, with the app's list of allowed requests.
    static func live(
        baseURL: URL,
        environmentID: String,
        tokens: any BearerTokenSource,
        recorder: RequestRecorder,
        classicWritePolicy: ClassicWritePolicy = .denied,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) -> PlatformClient {
        let http = HTTPClient(
            baseURL: baseURL,
            tokens: tokens,
            recorder: recorder,
            headers: ["X-Environment-Id": environmentID],
            permits: { isPermitted($0, classicWrites: classicWritePolicy) },
            sleep: sleep,
            random: random
        )
        return PlatformClient(http: http, classicWritePolicy: classicWritePolicy)
    }

    /// Safety net, checked before anything reaches the network. Allowed:
    /// - any GET;
    /// - POST to create a blueprint or deploy one;
    /// - only with `.scopeOnly`: PUT to a classic profile (either platform's resource)
    ///   whose XML body contains nothing but `<scope>`.
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
                  request.path.wholeMatch(of: /proclassic\/(?:osxconfigurationprofiles|mobiledeviceconfigurationprofiles)\/id\/\d+/) != nil,
                  let body = request.body else { return false }
            return isScopeOnlyProfileXML(body)
        default:
            return false
        }
    }

    /// A classic profile root (either platform) with exactly one child element, `<scope>`.
    static func isScopeOnlyProfileXML(_ data: Data) -> Bool {
        guard let document = try? XMLDocument(data: data, options: []),
              let root = document.rootElement(), let name = root.name,
              ProfilePlatform.allCases.contains(where: { $0.profileRootElement == name }) else { return false }
        let children = (root.children ?? []).compactMap { $0 as? XMLElement }
        return children.count == 1 && children[0].name == "scope"
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await http.send(request)
        } catch let error as HTTPError {
            throw APIError(error)
        }
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
}

nonisolated extension APIError {
    /// JTKit's failure as the app has always shown it: the gateway's error body
    /// decoded, the raw body redacted and cut short.
    init(_ error: HTTPError) {
        switch error {
        case let .refused(method, path):
            self = .invalidConfiguration("Blocked \(method) \(path): this app only reads, creates and deploys blueprints"
                + (method == "PUT" ? ", and changes classic scope only when that is explicitly enabled." : "."))
        case let .invalidURL(message):
            self = .invalidConfiguration(message)
        case let .transport(_, _, _, message):
            self = .transport(message)
        case let .status(response, method, path, _):
            self = .http(status: response.status, method: method, path: path,
                         body: APIErrorBody.parse(response.data), rawBody: Self.rawBody(response))
        case let .decoding(message):
            self = .decoding(message)
        }
    }

    private static func rawBody(_ response: HTTPResponse, limit: Int = 4_000) -> String? {
        guard let text = Redaction.body(response.data, contentType: response.header("Content-Type")) else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters)" : text
    }
}
