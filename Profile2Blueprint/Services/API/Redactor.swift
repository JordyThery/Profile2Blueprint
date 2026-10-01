import Foundation
import OSLog

nonisolated enum Log {
    static let subsystem = "be.jordythery.profile2blueprint"
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let app = Logger(subsystem: subsystem, category: "app")
}

/// Strips credentials out of any text before it's logged, shown or persisted.
nonisolated enum Redactor {
    static let placeholder = "‹redacted›"

    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // JSON fields: "access_token": "…", "client_secret": "…", "refresh_token": "…"
            (#"("(?:access_token|client_secret|refresh_token|id_token)"\s*:\s*")[^"]*(")"#, "$1\(placeholder)$2"),
            // Form fields: client_secret=…
            (#"((?:client_secret|access_token)=)[^&\s]*"#, "$1\(placeholder)"),
            // Authorization headers: Bearer …
            (#"(Bearer\s+)[A-Za-z0-9\-._~+/]+=*"#, "$1\(placeholder)"),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, template) }
        }
    }()

    static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// Redacts and truncates a response body for display or error reporting.
    static func redactedBody(_ data: Data, limit: Int = 4_000) -> String? {
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        let suffix = data.count > limit ? "\n… (\(data.count - limit) more bytes)" : ""
        return redact(text) + suffix
    }
}

/// `application/x-www-form-urlencoded` / strict query encoding: only RFC 3986
/// unreserved characters pass through, so `+`, `&`, `=` and quotes in values
/// (secrets, RSQL filters) can't change the meaning of the request.
nonisolated enum FormEncoding {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func encode(_ items: [URLQueryItem]) -> String {
        items.map { "\(encode($0.name))=\(encode($0.value ?? ""))" }.joined(separator: "&")
    }
}
