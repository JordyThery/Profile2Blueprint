import Foundation

/// An Apple property-list value that keeps dictionary key order and keeps
/// `<true/>`/`<false/>` distinct from `<integer>` (unlike `PropertyListSerialization`).
nonisolated indirect enum PlistValue: Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dict(PlistDictionary)

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var arrayValue: [PlistValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var dictValue: PlistDictionary? {
        if case let .dict(value) = self { return value }
        return nil
    }

    /// The plist element name, e.g. `string`, `dict`.
    /// An empty string, array or dictionary: a value with nothing in it to lose.
    var isEmptyContainer: Bool {
        switch self {
        case let .string(value): value.isEmpty
        case let .array(values): values.isEmpty
        case let .dict(dict): dict.entries.isEmpty
        default: false
        }
    }

    var typeName: String {
        switch self {
        case .string: "string"
        case .integer: "integer"
        case .real: "real"
        case .bool: "boolean"
        case .date: "date"
        case .data: "data"
        case .array: "array"
        case .dict: "dict"
        }
    }

    /// Short single-line rendering for tables and trees.
    var displaySummary: String {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .real(value): String(value)
        case let .bool(value): value ? "true" : "false"
        case let .date(value): value.formatted(.iso8601)
        case let .data(value): "<\(value.count) bytes>"
        case let .array(values): "\(values.count) item\(values.count == 1 ? "" : "s")"
        case let .dict(dict): "\(dict.count) key\(dict.count == 1 ? "" : "s")"
        }
    }
}

/// An insertion-ordered plist dictionary.
nonisolated struct PlistDictionary: Hashable, Sendable {
    nonisolated struct Entry: Hashable, Sendable {
        var key: String
        var value: PlistValue
    }

    var entries: [Entry]

    init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    var count: Int { entries.count }
    var keys: [String] { entries.map(\.key) }

    subscript(key: String) -> PlistValue? {
        entries.first { $0.key == key }?.value
    }

    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }
}
