import Foundation
import OSLog

nonisolated struct AccessToken: Sendable, Hashable {
    let value: String
    let expiresAt: Date
}

/// OAuth 2.0 client-credentials token source for the Jamf Platform API Gateway.
///
/// - Caches the token and reuses it until `refreshMargin` before expiry.
/// - Coalesces concurrent refreshes into a single token request.
/// - Never logs the token or the client secret.
actor TokenProvider {
    private let tokenURL: URL
    private let clientID: String
    private let secret: @Sendable () throws -> String
    private let session: URLSession
    private let refreshMargin: TimeInterval
    private let now: @Sendable () -> Date
    private let activity: any ActivityRecorder
    private let environmentName: String

    private var cached: AccessToken?
    private var inFlight: Task<AccessToken, any Error>?

    /// Number of token requests sent; useful for diagnostics and tests.
    private(set) var requestCount = 0

    init(
        tokenURL: URL,
        clientID: String,
        secret: @escaping @Sendable () throws -> String,
        session: URLSession = .shared,
        refreshMargin: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() },
        environmentName: String = "",
        activity: any ActivityRecorder = NullActivityRecorder()
    ) {
        self.activity = activity
        self.environmentName = environmentName.isEmpty ? (tokenURL.host() ?? "") : environmentName
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.secret = secret
        self.session = session
        self.refreshMargin = refreshMargin
        self.now = now
    }

    /// Returns a token that is valid for at least `refreshMargin` seconds.
    func validToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(now()) > refreshMargin {
            return cached.value
        }
        return try await refresh().value
    }

    /// Drops the cached token, e.g. after the server answered 401.
    func invalidate() {
        cached = nil
    }

    private func refresh() async throws -> AccessToken {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await self.requestToken() }
        inFlight = task
        defer { inFlight = nil }
        let token = try await task.value
        cached = token
        return token
    }

    private func requestToken() async throws -> AccessToken {
        requestCount += 1
        let clientSecret = try secret()

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(FormEncoding.encode([
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
        ]).utf8)

        let issuedAt = now()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            Log.auth.error("Token request failed: \(error.localizedDescription, privacy: .public)")
            activity.record(ActivityEvent(environment: environmentName, category: .auth, level: .error,
                                          message: "Token request failed: \(error.localizedDescription)", method: "POST", path: tokenURL.path()))
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("No HTTP response from token endpoint.")
        }
        Log.auth.info("Token request to \(self.tokenURL.host() ?? "?", privacy: .public) returned \(http.statusCode)")

        guard (200..<300).contains(http.statusCode) else {
            let body = APIErrorBody.parse(data)
            activity.record(ActivityEvent(environment: environmentName, category: .auth, level: .error,
                                          message: "Token request rejected" + (body?.errors.first.map { ": \($0.code) \($0.description)" } ?? "."),
                                          method: "POST", path: tokenURL.path(), status: http.statusCode, traceId: body?.traceId))
            throw APIError.http(
                status: http.statusCode,
                method: "POST",
                path: tokenURL.path(),
                body: APIErrorBody.parse(data),
                rawBody: Redactor.redactedBody(data)
            )
        }

        do {
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            let lifetime = TimeInterval(decoded.expiresIn ?? 900)
            activity.record(ActivityEvent(environment: environmentName, category: .auth,
                                          message: "Access token issued (valid \(Int(lifetime)) s). Token value is never logged.",
                                          method: "POST", path: tokenURL.path(), status: http.statusCode))
            return AccessToken(value: decoded.accessToken, expiresAt: issuedAt.addingTimeInterval(lifetime))
        } catch {
            throw APIError.decoding("Token response: \(error.localizedDescription)")
        }
    }
}

nonisolated private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}
