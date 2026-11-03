import AppKit
import SwiftUI
import JTKit

extension EligibilityStatus {
    var color: Color {
        switch self {
        case .ready: .green
        case .needsAttention: .orange
        case .blocked: .red
        }
    }
}

/// Ready / Needs attention / Blocked, each with its SF Symbol.
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
                    configuration.title.font(.caption.weight(.semibold)).foregroundStyle(Color.primary)
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
    /// The JSON holds credentials from the profile (Wi-Fi passwords, SCEP
    /// challenges): copied with JTKit's `SecretPasteboard` (concealed, this
    /// Mac only, cleared after a minute).
    var containsSecrets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let title { Text(title).font(.headline) }
                Spacer()
                Button("Copy JSON", systemImage: "doc.on.doc") {
                    Self.copy(json, containsSecrets: containsSecrets)
                }
                .help(containsSecrets
                      ? "Copy the exact JSON; it holds credentials, so the clipboard is cleared after a minute"
                      : "Copy the exact JSON to the clipboard")
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

extension JSONTextView {
    /// Copies the JSON; with secrets through JTKit's `SecretPasteboard`.
    static func copy(_ json: String, containsSecrets: Bool, to pasteboard: NSPasteboard = .general) {
        if containsSecrets {
            SecretPasteboard.copy(json, to: pasteboard)
        } else {
            pasteboard.clearContents()
            pasteboard.setString(json, forType: .string)
        }
    }
}

/// Tiny tokenizer for coloring already-serialized JSON.
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
                append(token, isKey ? JSONColors.key : JSONColors.string)
                index = end + 1
            } else if CharacterSet(charactersIn: "-0123456789").contains(scalar) {
                var end = index
                while end < scalars.count, CharacterSet(charactersIn: "-+.eE0123456789").contains(scalars[end]) { end += 1 }
                append(String(String.UnicodeScalarView(scalars[index..<end])), JSONColors.number)
                index = end
            } else if let word = ["true", "false", "null"].first(where: { matches($0, scalars, at: index) }) {
                append(word, JSONColors.literal)
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

/// A label whose symbol carries the status color while its words stay in the
/// readable text color: system orange, green and red text is below 4.5:1 in
/// Light mode, the symbol keeps the meaning.
struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.foregroundStyle(tint)
        }
    }
}

extension LabelStyle where Self == TintedIconLabelStyle {
    /// The symbol in `tint`, the text as it is.
    static func tintedIcon(_ tint: Color) -> TintedIconLabelStyle { TintedIconLabelStyle(tint: tint) }
}

/// JSON syntax colors at 4.5:1 or more on the text background, in Light and Dark mode.
enum JSONColors {
    static let key = adaptive(light: 0x0F68A0, dark: 0x6BB8EB)
    static let string = adaptive(light: 0xC41A16, dark: 0xFC6A5D)
    static let number = adaptive(light: 0x1C00CF, dark: 0xD0BF69)
    static let literal = adaptive(light: 0x9B2393, dark: 0xFC5FA3)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
