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
    /// Payload wrapper keys that the Blueprints API expects in camelCase, as used in
    /// the working JNUC demo body. Only applied at the top level of each payload;
    /// type-specific keys (e.g. `Rules`) keep their Apple casing.
    ///
    /// Provisional: confirmed only against the demo, not the OpenAPI schema, which
    /// documents just `payloadType`. The verify step checks the server's read-back.
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
}

/// Compares plist source values with JSON (built locally or read back from the server).
nonisolated enum PlistJSONComparator {
    nonisolated struct Options: Sendable {
        /// Match object keys case-insensitively (the server may re-case keys).
        var caseInsensitiveKeys = false
        /// Require object keys to appear in the same order.
        var requireKeyOrder = false
        /// Keys present only in the JSON that are not reported.
        var ignoredExtraKeys: Set<String> = []
        /// Keys present only in the plist that are not reported.
        var ignoredMissingKeys: Set<String> = []
        /// Rename map applied to plist keys before lookup (e.g. wrapper keys).
        var keyMap: [String: String] = [:]
    }

    static func differences(
        plist: PlistValue, json: JSONValue, path: String = "", options: Options = Options()
    ) -> [ValueDifference] {
        let here = path.isEmpty ? "(root)" : path
        switch (plist, json) {
        case let (.string(a), .string(b)):
            return a == b ? [] : [ValueDifference(path: here, expected: a, actual: b)]
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
        var nested = options
        nested.keyMap = [:]
        nested.ignoredExtraKeys = []
        nested.ignoredMissingKeys = []

        for entry in plist.entries {
            let key = options.keyMap[entry.key] ?? entry.key
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            let match: (key: String, value: JSONValue)?
            if options.caseInsensitiveKeys {
                match = json.value(forKeyIgnoringCase: key)
            } else {
                match = json[key].map { (key, $0) }
            }
            guard let match else {
                if !options.ignoredMissingKeys.contains(entry.key) {
                    result.append(ValueDifference(path: childPath, expected: entry.value.displaySummary, actual: "(missing)"))
                }
                continue
            }
            matchedKeys.append(match.key)
            result += differences(plist: entry.value, json: match.value, path: childPath, options: nested)
        }

        let extra = json.keys.filter { key in
            !matchedKeys.contains(key) && !options.ignoredExtraKeys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
        }
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
