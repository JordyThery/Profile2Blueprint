import Foundation

/// A JSON value with insertion-ordered objects, so request previews and the
/// POSTed body list keys exactly as built (and in the source plist's order).
nonisolated indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: JSONObject? {
        if case let .object(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case let .integer(value): Double(value)
        case let .number(value): value
        default: nil
        }
    }

    /// Short single-line rendering for tables.
    var displaySummary: String {
        switch self {
        case .null: "null"
        case let .bool(value): value ? "true" : "false"
        case let .integer(value): String(value)
        case let .number(value): String(value)
        case let .string(value): value
        case let .array(values): "\(values.count) item\(values.count == 1 ? "" : "s")"
        case let .object(object): "\(object.count) key\(object.count == 1 ? "" : "s")"
        }
    }
}

nonisolated struct JSONObject: Hashable, Sendable {
    nonisolated struct Entry: Hashable, Sendable {
        var key: String
        var value: JSONValue
    }

    var entries: [Entry]

    init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    init(_ pairs: KeyValuePairs<String, JSONValue>) {
        entries = pairs.map { Entry(key: $0.key, value: $0.value) }
    }

    var count: Int { entries.count }
    var keys: [String] { entries.map(\.key) }

    subscript(key: String) -> JSONValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    entries[index].value = newValue
                } else {
                    entries.remove(at: index)
                }
            } else if let newValue {
                entries.append(Entry(key: key, value: newValue))
            }
        }
    }

    /// Case-insensitive lookup, used when comparing against server output that
    /// may re-case keys.
    func value(forKeyIgnoringCase key: String) -> (key: String, value: JSONValue)? {
        entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map { ($0.key, $0.value) }
    }
}

// MARK: - Serialisation

extension JSONValue {
    /// Deterministic JSON text that preserves object key order.
    nonisolated func serialized(pretty: Bool = true) -> String {
        var output = ""
        write(to: &output, pretty: pretty, indent: 0)
        return output
    }

    nonisolated func serializedData() -> Data {
        Data(serialized(pretty: false).utf8)
    }

    private nonisolated func write(to output: inout String, pretty: Bool, indent: Int) {
        let newline = pretty ? "\n" : ""
        let pad = { (level: Int) in pretty ? String(repeating: "  ", count: level) : "" }

        switch self {
        case .null:
            output += "null"
        case let .bool(value):
            output += value ? "true" : "false"
        case let .integer(value):
            output += String(value)
        case let .number(value):
            output += value.isFinite ? Self.format(value) : "null"
        case let .string(value):
            Self.writeString(value, to: &output)
        case let .array(values):
            guard !values.isEmpty else { output += "[]"; return }
            output += "[" + newline
            for (index, value) in values.enumerated() {
                output += pad(indent + 1)
                value.write(to: &output, pretty: pretty, indent: indent + 1)
                output += (index < values.count - 1 ? "," : "") + newline
            }
            output += pad(indent) + "]"
        case let .object(object):
            guard !object.entries.isEmpty else { output += "{}"; return }
            output += "{" + newline
            for (index, entry) in object.entries.enumerated() {
                output += pad(indent + 1)
                Self.writeString(entry.key, to: &output)
                output += pretty ? ": " : ":"
                entry.value.write(to: &output, pretty: pretty, indent: indent + 1)
                output += (index < object.entries.count - 1 ? "," : "") + newline
            }
            output += pad(indent) + "}"
        }
    }

    private nonisolated static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        return "\(value)"
    }

    private nonisolated static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: - Decoding server responses

extension JSONValue: Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            // Server key order is not meaningful; sort for stable display.
            self = .object(JSONObject(value.keys.sorted().map { JSONObject.Entry(key: $0, value: value[$0]!) }))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}
