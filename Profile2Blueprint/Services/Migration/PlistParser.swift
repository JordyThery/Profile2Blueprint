import Foundation

nonisolated struct PlistParseError: Error, LocalizedError, Hashable, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// Parses an XML property list into an order-preserving `PlistValue` tree.
nonisolated enum PlistParser {
    static func parse(_ xml: String) throws(PlistParseError) -> PlistValue {
        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        } catch {
            throw PlistParseError(message: "Payload plist is not well-formed XML: \(error.localizedDescription)")
        }
        guard let root = document.rootElement(), root.name == "plist" else {
            throw PlistParseError(message: "Payload is not a property list (missing <plist> root).")
        }
        guard let first = elements(of: root).first else {
            throw PlistParseError(message: "Property list is empty.")
        }
        return try value(from: first, path: "")
    }

    private static func elements(of node: XMLNode) -> [XMLElement] {
        (node.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func value(from element: XMLElement, path: String) throws(PlistParseError) -> PlistValue {
        let text = element.stringValue ?? ""
        switch element.name {
        case "string":
            return .string(text)
        case "integer":
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int64(trimmed) { return .integer(value) }
            // Values above Int64.max (rare, unsigned) are kept as reals rather than failing.
            if let value = Double(trimmed), value.isFinite { return .real(value) }
            throw PlistParseError(message: "Invalid <integer> “\(trimmed)” at \(path.isEmpty ? "root" : path).")
        case "real":
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(trimmed) else {
                throw PlistParseError(message: "Invalid <real> “\(trimmed)” at \(path.isEmpty ? "root" : path).")
            }
            return .real(value)
        case "true":
            return .bool(true)
        case "false":
            return .bool(false)
        case "date":
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let date = try? Date(trimmed, strategy: .iso8601) else {
                throw PlistParseError(message: "Invalid <date> “\(trimmed)” at \(path.isEmpty ? "root" : path).")
            }
            return .date(date)
        case "data":
            let compact = text.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: compact) else {
                throw PlistParseError(message: "Invalid base64 <data> at \(path.isEmpty ? "root" : path).")
            }
            return .data(data)
        case "array":
            var values: [PlistValue] = []
            for (index, child) in elements(of: element).enumerated() {
                values.append(try value(from: child, path: "\(path)[\(index)]"))
            }
            return .array(values)
        case "dict":
            let children = elements(of: element)
            var entries: [PlistDictionary.Entry] = []
            var index = 0
            while index < children.count {
                let keyElement = children[index]
                guard keyElement.name == "key" else {
                    throw PlistParseError(message: "Expected <key> in <dict> at \(path.isEmpty ? "root" : path), found <\(keyElement.name ?? "?")>.")
                }
                let key = keyElement.stringValue ?? ""
                guard index + 1 < children.count else {
                    throw PlistParseError(message: "Key “\(key)” has no value at \(path.isEmpty ? "root" : path).")
                }
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                entries.append(.init(key: key, value: try value(from: children[index + 1], path: childPath)))
                index += 2
            }
            return .dict(PlistDictionary(entries))
        default:
            throw PlistParseError(message: "Unknown plist element <\(element.name ?? "?")> at \(path.isEmpty ? "root" : path).")
        }
    }
}
