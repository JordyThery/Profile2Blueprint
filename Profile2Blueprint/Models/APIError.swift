import Foundation
import JTKit

/// One entry of the gateway's `errors` field.
nonisolated struct APIErrorDetail: Codable, Hashable, Sendable {
    var id: String?
    var code: String
    var field: String?
    var description: String

    init(id: String? = nil, code: String, field: String? = nil, description: String) {
        self.id = id
        self.code = code
        self.field = field
        self.description = description
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? "UNKNOWN"
        field = try container.decodeIfPresent(String.self, forKey: .field)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

/// The gateway `ApiError` body: `{httpStatus, traceId, errors}`.
///
/// The spec declares `errors` as a single object, but this also accepts an array,
/// and OAuth-style `{error, error_description}` bodies from the token endpoint.
nonisolated struct APIErrorBody: Decodable, Hashable, Sendable {
    var httpStatus: Int?
    var traceId: String?
    var errors: [APIErrorDetail]

    init(httpStatus: Int? = nil, traceId: String? = nil, errors: [APIErrorDetail] = []) {
        self.httpStatus = httpStatus
        self.traceId = traceId
        self.errors = errors
    }

    private enum CodingKeys: String, CodingKey {
        case httpStatus, traceId, errors
        case error
        case errorDescription = "error_description"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        httpStatus = try? container.decodeIfPresent(Int.self, forKey: .httpStatus)
        traceId = try? container.decodeIfPresent(String.self, forKey: .traceId)
        if let many = try? container.decode([APIErrorDetail].self, forKey: .errors) {
            errors = many
        } else if let one = try? container.decode(APIErrorDetail.self, forKey: .errors) {
            errors = [one]
        } else if let code = try? container.decode(String.self, forKey: .error) {
            let description = (try? container.decodeIfPresent(String.self, forKey: .errorDescription)) ?? ""
            errors = [APIErrorDetail(code: code, description: description)]
        } else {
            errors = []
        }
    }

    /// Parses an error body, returning `nil` if it isn't a recognisable error document.
    static func parse(_ data: Data) -> APIErrorBody? {
        guard !data.isEmpty, let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) else { return nil }
        if body.errors.isEmpty && body.traceId == nil && body.httpStatus == nil { return nil }
        return body
    }
}

/// Errors surfaced by the networking layer. Bodies are redacted before being stored.
nonisolated enum APIError: Error, LocalizedError, Sendable {
    case http(status: Int, method: String, path: String, body: APIErrorBody?, rawBody: String?)
    case transport(String)
    case decoding(String)
    case invalidConfiguration(String)
    case missingSecret
    case paginationLimitExceeded

    var errorDescription: String? {
        switch self {
        case let .http(status, method, path, body, _):
            let summary = body?.errors.first.map { "\($0.code): \($0.description)" }
                ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
            return "\(method) \(path) failed with HTTP \(status). \(summary)"
        case let .transport(message):
            return "Network error: \(message)"
        case let .decoding(message):
            return "Unexpected response format: \(message)"
        case let .invalidConfiguration(message):
            return message
        case .missingSecret:
            return "No client secret is stored for this tenant. Enter it and save."
        case .paginationLimitExceeded:
            return "The server kept returning more pages than expected; stopped to avoid an infinite loop."
        }
    }
}

/// A flattened, display-ready view of any error, used by `APIErrorView`.
nonisolated struct ErrorReport: Hashable, Sendable {
    var title: String
    var httpStatus: Int?
    var traceId: String?
    var details: [APIErrorDetail]
    var rawBody: String?

    init(_ error: any Error) {
        let error = (error as? HTTPError).map(APIError.init) ?? error
        title = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        details = []
        if case let APIError.http(status, _, _, body, raw) = error {
            httpStatus = body?.httpStatus ?? status
            traceId = body?.traceId
            details = body?.errors ?? []
            rawBody = body == nil ? raw : nil
        }
    }
}

nonisolated extension ErrorReport {
    /// What `APIErrorView` shows below the title, as plain text for copying:
    /// the HTTP status, each error's code, field and description, the trace ID
    /// and a response body that couldn't be read as an error. Nil when there
    /// is nothing beyond the title.
    var detailText: String? {
        var lines = [String]()
        if let httpStatus { lines.append("httpStatus: \(httpStatus)") }
        for detail in details {
            lines.append("errors.code: \(detail.code)")
            if let field = detail.field { lines.append("errors.field: \(field)") }
            if !detail.description.isEmpty { lines.append("errors.description: \(detail.description)") }
        }
        if let traceId { lines.append("traceId: \(traceId)") }
        if let rawBody { lines.append("Response body (redacted):\n\(rawBody)") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// A failed Test Connection in Settings › Connections. JTKit's editor shows the
/// title and then the details in full, selectable for copying.
nonisolated struct ConnectionTestError: LocalizedError, Sendable {
    let report: ErrorReport

    var errorDescription: String? { report.title }
    var failureReason: String? { report.detailText }
}
