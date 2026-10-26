import Foundation
import JTKit

/// The few things Profile2Blueprint needs from JSON that JTKit's `LosslessJSON`
/// doesn't offer: numbers from plist values, case-insensitive lookups, number
/// values for comparing with plists, and the one-line summaries in tables.
nonisolated extension LosslessJSON {
    /// A plist integer as a JSON number.
    static func integer(_ value: Int64) -> LosslessJSON {
        .number(Number(literal: String(value)))
    }

    /// A plist real as a JSON number, written as the app always wrote it: whole
    /// numbers with one decimal (`1.0`), others in Swift's shortest form. JSON has
    /// no infinity or NaN, so those become `null`.
    static func real(_ value: Double) -> LosslessJSON {
        guard value.isFinite else { return .null }
        if value == value.rounded(), abs(value) < 1e15 {
            return .number(Number(literal: String(format: "%.1f", value)))
        }
        return .number(Number(literal: "\(value)"))
    }

    /// The value of a number, for comparing with a plist integer or real.
    var doubleValue: Double? {
        numberValue.flatMap { Double($0.literal) }
    }

    /// Short single-line rendering for tables. Numbers show as sent.
    var displaySummary: String {
        switch self {
        case .null: "null"
        case let .bool(value): value ? "true" : "false"
        case let .number(number): number.literal
        case let .string(value): value
        case let .array(values): "\(values.count) item\(values.count == 1 ? "" : "s")"
        case let .object(object): "\(object.count) key\(object.count == 1 ? "" : "s")"
        }
    }

    /// Pretty JSON text for the preview and diff tabs: two-space indentation,
    /// key order as built or as the server sent it.
    var prettyText: String {
        serializedString(pretty: true)
    }
}

nonisolated extension LosslessJSON.Object {
    /// Case-insensitive lookup, used when comparing against server output that
    /// may re-case keys. Order-independent: finds the key wherever it is.
    func value(forKeyIgnoringCase key: String) -> (key: String, value: LosslessJSON)? {
        members.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map { ($0.key, $0.value) }
    }
}
