import AppKit
import SwiftUI

extension EligibilityStatus {
    var color: Color {
        switch self {
        case .ready: .green
        case .needsAttention: .orange
        case .blocked: .red
        }
    }
}

/// ✅ Ready / ⚠️ Needs attention / ⛔ Blocked.
struct EligibilityBadge: View {
    let status: EligibilityStatus?
    var compact = false

    var body: some View {
        if let status {
            Label(status.title, systemImage: status.symbol)
                .labelStyle(BadgeLabelStyle(compact: compact))
                .foregroundStyle(status.color)
                .accessibilityLabel("Eligibility: \(status.title)")
        } else {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Checking eligibility")
        }
    }

    private struct BadgeLabelStyle: LabelStyle {
        let compact: Bool
        func makeBody(configuration: Configuration) -> some View {
            if compact {
                configuration.icon
            } else {
                HStack(spacing: 4) {
                    configuration.icon
                    configuration.title.font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
        }
    }
}

extension FindingSeverity {
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .blocker: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .blocker: .red
        }
    }

    var accessibilityName: String {
        switch self {
        case .info: "Information"
        case .warning: "Warning"
        case .blocker: "Blocker"
        }
    }
}

/// A list of eligibility findings with icons and explanations.
struct FindingsList: View {
    let findings: [EligibilityFinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(findings.sorted { $0.severity > $1.severity }) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: finding.severity.symbol)
                        .foregroundStyle(finding.severity.color)
                        .accessibilityLabel(finding.severity.accessibilityName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.title).fontWeight(.medium)
                        Text(finding.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Plist tree

/// A node of the payload outline.
struct PlistNode: Identifiable, Hashable {
    let id: String
    let key: String
    let value: PlistValue
    let children: [PlistNode]?

    static func nodes(for dict: PlistDictionary, path: String = "") -> [PlistNode] {
        dict.entries.map { entry in node(key: entry.key, value: entry.value, path: path.isEmpty ? entry.key : "\(path).\(entry.key)") }
    }

    static func node(key: String, value: PlistValue, path: String) -> PlistNode {
        let children: [PlistNode]?
        switch value {
        case let .dict(dict):
            children = nodes(for: dict, path: path)
        case let .array(values):
            children = values.enumerated().map { index, element in node(key: "[\(index)]", value: element, path: "\(path)[\(index)]") }
        default:
            children = nil
        }
        return PlistNode(id: path, key: key, value: value, children: children)
    }
}

/// Outline of a plist dictionary showing key, type and value.
struct PlistOutline: View {
    let nodes: [PlistNode]

    var body: some View {
        List(nodes, children: \.children) { node in
            HStack(alignment: .firstTextBaseline) {
                Text(node.key)
                    .font(.callout.monospaced())
                Text(node.value.typeName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                Spacer(minLength: 12)
                Text(node.value.displaySummary)
                    .font(.callout.monospaced())
                    .foregroundStyle(node.children == nil ? .primary : .secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

// MARK: - JSON

/// Monospaced, syntax-highlighted, selectable JSON with a copy button.
struct JSONTextView: View {
    let json: String
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let title { Text(title).font(.headline) }
                Spacer()
                Button("Copy JSON", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                }
                .help("Copy the exact JSON to the clipboard")
            }
            ScrollView([.vertical, .horizontal]) {
                Text(JSONHighlighter.highlight(json))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
    }
}

/// Tiny tokenizer for colouring already-serialised JSON.
enum JSONHighlighter {
    static func highlight(_ text: String) -> AttributedString {
        var result = AttributedString()
        let scalars = Array(text.unicodeScalars)
        var index = 0

        func append(_ string: String, _ color: Color?) {
            var piece = AttributedString(string)
            if let color { piece.foregroundColor = color }
            result += piece
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                var end = index + 1
                while end < scalars.count {
                    if scalars[end] == "\\" { end += 2; continue }
                    if scalars[end] == "\"" { break }
                    end += 1
                }
                end = min(end, scalars.count - 1)
                let token = String(String.UnicodeScalarView(scalars[index...end]))
                // A string followed by ':' is a key.
                var look = end + 1
                while look < scalars.count, scalars[look] == " " { look += 1 }
                let isKey = look < scalars.count && scalars[look] == ":"
                append(token, isKey ? .blue : .red)
                index = end + 1
            } else if CharacterSet(charactersIn: "-0123456789").contains(scalar) {
                var end = index
                while end < scalars.count, CharacterSet(charactersIn: "-+.eE0123456789").contains(scalars[end]) { end += 1 }
                append(String(String.UnicodeScalarView(scalars[index..<end])), .purple)
                index = end
            } else if let word = ["true", "false", "null"].first(where: { matches($0, scalars, at: index) }) {
                append(word, .orange)
                index += word.unicodeScalars.count
            } else {
                var end = index
                while end < scalars.count, !"\"-0123456789tfn".unicodeScalars.contains(scalars[end]) { end += 1 }
                if end == index { end += 1 }
                append(String(String.UnicodeScalarView(scalars[index..<end])), nil)
                index = end
            }
        }
        return result
    }

    private static func matches(_ word: String, _ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let wordScalars = Array(word.unicodeScalars)
        guard index + wordScalars.count <= scalars.count else { return false }
        return Array(scalars[index..<index + wordScalars.count]) == wordScalars
    }
}

/// Labeled value row used in metadata grids.
struct MetadataRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }
}
