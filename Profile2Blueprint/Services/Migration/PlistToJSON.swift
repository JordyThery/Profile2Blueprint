import Foundation

/// Converts Apple plist values to JSON per Jamf's documented mapping:
///
/// | plist | JSON |
/// |---|---|
/// | string / integer / real / boolean | string / number / number / boolean |
/// | data | Base64 string |
/// | date | ISO 8601 string |
/// | array / dict | array / object |
///
/// Key casing and order, and array order, are preserved exactly.
nonisolated enum PlistToJSON {
    /// Payload wrapper keys the Blueprints API expects in camelCase, verified against a
    /// live tenant. Only applied at the top level of each payload; type-specific keys
    /// (e.g. `Rules`) keep their Apple casing. The verify step checks the read-back.
    static let wrapperKeyMap: [String: String] = [
        "PayloadType": "payloadType",
        "PayloadUUID": "payloadUUID",
        "PayloadIdentifier": "payloadIdentifier",
        "PayloadVersion": "payloadVersion",
        "PayloadDisplayName": "payloadDisplayName",
        "PayloadOrganization": "payloadOrganization",
    ]

    static func convert(_ value: PlistValue) -> JSONValue {
        switch value {
        case let .string(string): .string(string)
        case let .integer(integer): .integer(integer)
        case let .real(real): .number(real)
        case let .bool(bool): .bool(bool)
        case let .date(date): .string(iso8601(date))
        case let .data(data): .string(data.base64EncodedString())
        case let .array(values): .array(values.map(convert))
        case let .dict(dict): .object(convert(dict))
        }
    }

    static func convert(_ dict: PlistDictionary) -> JSONObject {
        JSONObject(dict.entries.map { .init(key: $0.key, value: convert($0.value)) })
    }

    /// A `PayloadContent` entry with wrapper keys renamed to the API's camelCase.
    static func payloadObject(_ payload: PlistDictionary) -> JSONObject {
        JSONObject(payload.entries.map { entry in
            .init(key: wrapperKeyMap[entry.key] ?? entry.key, value: convert(entry.value))
        })
    }

    static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

/// A single difference found when comparing a plist value with JSON.
nonisolated struct ValueDifference: Hashable, Sendable {
    var path: String
    var expected: String
    var actual: String
    /// Set when the difference is a documented server behaviour rather than data loss.
    /// Carries the explanation to show instead of reporting a mismatch.
    var serverRewrite: String?
}

/// Ways Jamf Pro is known to alter a string between what was sent and what reads back.
/// Probed by Jamf against Jamf Pro 11.30.x (`jamf-cli`, `internal/profileconvert/classic_verify.go`).
nonisolated enum ServerStringRewrite {
    /// Folds CRLF and lone CR to LF, and trims the value edges. Jamf Pro keeps a line
    /// break only when it is written as `&#13;` and never returns it as CR, and it trims
    /// leading and trailing whitespace on ingest. Without this, profiles authored in
    /// Jamf Pro's own UI look corrupted.
    ///
    /// U+2028/U+2029/U+0085 are deliberately left alone: they round-trip exactly, so
    /// comparing them strictly keeps real corruption detectable.
    /// Works on Unicode scalars because Swift treats CRLF as a single `Character`,
    /// so `contains("\r")` is false for CRLF text.
    static func normalize(_ value: String) -> String {
        guard value.unicodeScalars.contains("\r") else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var folded = String.UnicodeScalarView()
        var afterCR = false
        for scalar in value.unicodeScalars {
            if scalar == "\r" {
                folded.append("\n")
                afterCR = true
            } else {
                if !(afterCR && scalar == "\n") { folded.append(scalar) }
                afterCR = false
            }
        }
        return String(folded).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reason a normalised string still differs, when it is a known server behaviour.
    /// `nil` means the difference is real and should be reported as a mismatch.
    static func reason(expected: String, actual: String) -> String? {
        if expected.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: "") == actual {
            return "Jamf Pro deletes literal line feeds and tabs in this payload type. Write a line break as “&#13;” (what Jamf Pro's own UI writes), or move the value into an Application & Custom Settings payload, which keeps them."
        }
        if expected.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") == actual {
            return "The server added an extra layer of & and < escaping (Jamf PI-827). No wire format stores this payload type faithfully."
        }
        if actual.contains("\u{FFFD}"), expected.unicodeScalars.contains(where: { $0.value > 0xFFFF }) {
            return "The server replaced characters outside the Basic Multilingual Plane (emoji and similar). A Jamf-side limit; macOS itself handles them."
        }
        return nil
    }
}

/// Compares plist source values with JSON (built locally or read back from the server).
nonisolated enum PlistJSONComparator {
    nonisolated struct Options: Sendable {
        /// Match object keys case-insensitively (the server may re-case keys).
        var caseInsensitiveKeys = false
        /// Require object keys to appear in the same order.
        var requireKeyOrder = false
        /// Treat documented Jamf Pro string rewrites, and omitted empty values, as
        /// expected behaviour rather than data loss. Use when comparing against a
        /// server read-back; leave off when comparing against a locally built body.
        var tolerateServerRewrites = false
    }

    static func differences(
        plist: PlistValue, json: JSONValue, path: String = "", options: Options = Options()
    ) -> [ValueDifference] {
        let here = path.isEmpty ? "(root)" : path
        switch (plist, json) {
        case let (.string(a), .string(b)):
            if a == b { return [] }
            guard options.tolerateServerRewrites else {
                return [ValueDifference(path: here, expected: a, actual: b)]
            }
            let expected = ServerStringRewrite.normalize(a)
            let actual = ServerStringRewrite.normalize(b)
            if expected == actual { return [] }
            return [ValueDifference(path: here, expected: a, actual: b,
                                    serverRewrite: ServerStringRewrite.reason(expected: expected, actual: actual))]
        case let (.bool(a), .bool(b)):
            return a == b ? [] : [ValueDifference(path: here, expected: String(a), actual: String(b))]
        case let (.integer(a), _):
            guard let b = json.doubleValue, Double(a) == b else { return [mismatch(here, plist, json)] }
            return []
        case let (.real(a), _):
            guard let b = json.doubleValue, a == b else { return [mismatch(here, plist, json)] }
            return []
        case let (.date(a), .string(b)):
            guard let parsed = try? Date(b, strategy: .iso8601), abs(parsed.timeIntervalSince(a)) < 1 else {
                return [mismatch(here, plist, json)]
            }
            return []
        case let (.data(a), .string(b)):
            return Data(base64Encoded: b) == a ? [] : [mismatch(here, plist, json)]
        case let (.array(a), .array(b)):
            var result: [ValueDifference] = []
            if a.count != b.count {
                result.append(ValueDifference(path: "\(here).count", expected: String(a.count), actual: String(b.count)))
            }
            for index in 0..<min(a.count, b.count) {
                result += differences(plist: a[index], json: b[index], path: "\(path)[\(index)]", options: options)
            }
            return result
        case let (.dict(a), .object(b)):
            return dictionaryDifferences(a, b, path: path, options: options)
        default:
            return [mismatch(here, plist, json)]
        }
    }

    private static func dictionaryDifferences(
        _ plist: PlistDictionary, _ json: JSONObject, path: String, options: Options
    ) -> [ValueDifference] {
        var result: [ValueDifference] = []
        var matchedKeys: [String] = []

        for entry in plist.entries {
            let key = entry.key
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            let match: (key: String, value: JSONValue)?
            if options.caseInsensitiveKeys {
                match = json.value(forKeyIgnoringCase: key)
            } else {
                match = json[key].map { (key, $0) }
            }
            guard let match else {
                // An empty value the server simply didn't store back is a harmless
                // omission, not data loss: there was nothing in it to lose.
                let omittedEmpty = options.tolerateServerRewrites && entry.value.isEmptyContainer
                result.append(ValueDifference(
                    path: childPath, expected: entry.value.displaySummary, actual: "(missing)",
                    serverRewrite: omittedEmpty ? "The value was empty and the server does not store empty values." : nil
                ))
                continue
            }
            matchedKeys.append(match.key)
            result += differences(plist: entry.value, json: match.value, path: childPath, options: options)
        }

        let extra = json.keys.filter { !matchedKeys.contains($0) }
        for key in extra {
            result.append(ValueDifference(path: path.isEmpty ? key : "\(path).\(key)", expected: "(absent)", actual: json[key]?.displaySummary ?? ""))
        }

        if options.requireKeyOrder {
            let jsonOrder = json.keys.filter { matchedKeys.contains($0) }
            if jsonOrder != matchedKeys {
                result.append(ValueDifference(
                    path: (path.isEmpty ? "(root)" : path) + " key order",
                    expected: matchedKeys.joined(separator: ", "),
                    actual: jsonOrder.joined(separator: ", ")
                ))
            }
        }
        return result
    }

    private static func mismatch(_ path: String, _ plist: PlistValue, _ json: JSONValue) -> ValueDifference {
        ValueDifference(path: path, expected: "\(plist.displaySummary) (\(plist.typeName))", actual: json.displaySummary)
    }
}
