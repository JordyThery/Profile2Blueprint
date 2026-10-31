import Foundation
import JTKit

/// The app's own failures. Every failed request comes back as JTKit's
/// `JamfPlatform.APIError` instead, in the format every app shows.
nonisolated enum APIError: Error, LocalizedError, Sendable {
    case decoding(String)
    case invalidConfiguration(String)
    case missingSecret

    var errorDescription: String? {
        switch self {
        case let .decoding(message):
            return "Unexpected response format: \(message)"
        case let .invalidConfiguration(message):
            return message
        case .missingSecret:
            return "No client secret is stored for this tenant. Enter it and save."
        }
    }
}

/// A flattened, display-ready view of any error, used by `APIErrorView`.
///
/// A failed request shows JTKit's format: the status line as the title, then
/// one `CODE (field): description` line per error, the Trace ID and the hints.
nonisolated struct ErrorReport: Hashable, Sendable {
    var title: String
    /// The lines below the title.
    var details: [String]
    var httpStatus: Int?
    var traceID: String?

    init(_ error: any Error) {
        let platformError = (error as? JamfPlatform.APIError) ?? (error as? HTTPError).map(JamfPlatform.APIError.init)
        if let platformError {
            let lines = platformError.message().components(separatedBy: "\n").filter { !$0.isEmpty }
            title = lines.first ?? "The request failed."
            details = Array(lines.dropFirst())
            httpStatus = platformError.status
            traceID = platformError.traceID
        } else {
            title = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            details = []
        }
    }
}

nonisolated extension ErrorReport {
    /// What `APIErrorView` shows below the title, as plain text for copying.
    /// Nil when there is nothing beyond the title.
    var detailText: String? {
        details.isEmpty ? nil : details.joined(separator: "\n")
    }
}

/// A failed Test Connection in Settings › Connections. JTKit's editor shows the
/// title and then the details in full, selectable for copying.
nonisolated struct ConnectionTestError: LocalizedError, Sendable {
    let report: ErrorReport

    var errorDescription: String? { report.title }
    var failureReason: String? { report.detailText }
}
