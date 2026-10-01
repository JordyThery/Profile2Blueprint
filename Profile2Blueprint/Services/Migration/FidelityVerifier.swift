import Foundation

nonisolated enum FidelityStatus: Hashable, Sendable {
    /// Required to match and does.
    case match
    /// Required to match and doesn't: the in-place transform would not be seamless.
    case mismatch
    /// Same value but a key's casing changed. The device reads keys case-sensitively,
    /// so this needs a human look.
    case caseChanged
    /// Expected server canonicalisation, or a difference that doesn't affect the transform.
    case info
}

nonisolated struct FidelityRow: Hashable, Sendable, Identifiable {
    var field: String
    var classic: String
    var blueprint: String
    var status: FidelityStatus
    var note: String?

    var id: String { "\(field)|\(status)" }
}

nonisolated struct FidelityReport: Hashable, Sendable {
    var rows: [FidelityRow]

    var mismatches: [FidelityRow] { rows.filter { $0.status == .mismatch } }
    var caseChanges: [FidelityRow] { rows.filter { $0.status == .caseChanged } }
    var passed: Bool { mismatches.isEmpty }
}

/// Compares the classic source with the blueprint read back from the server, judging
/// fidelity by identifiers, order, count, setting values and scope (not exact text).
nonisolated enum FidelityVerifier {
    /// Wrapper keys that are metadata rather than settings.
    static let wrapperKeys: Set<String> = [
        "PayloadType", "PayloadUUID", "PayloadIdentifier", "PayloadVersion",
        "PayloadDisplayName", "PayloadOrganization", "PayloadDescription", "PayloadEnabled",
        "PayloadRemovalDisallowed", "PayloadScope",
    ]

    /// Payload metadata the server rewrites, injects or drops by design. Reported for
    /// visibility but never as a mismatch, except `PayloadEnabled` — see `verify`.
    static let serverManagedKeys = [
        "PayloadVersion", "PayloadOrganization", "PayloadDisplayName", "PayloadDescription",
        "PayloadRemovalDisallowed", "PayloadScope", "PayloadEnabled",
    ]

    static func verify(
        document: ProfileDocument,
        expectedGroupIDs: [String],
        detail: BlueprintDetail
    ) -> FidelityReport {
        var rows: [FidelityRow] = []
        func row(_ field: String, _ classic: String?, _ blueprint: String?, required: Bool = true, note: String? = nil) {
            let c = classic ?? "—"
            let b = blueprint ?? "—"
            rows.append(FidelityRow(field: field, classic: c, blueprint: b, status: c == b ? .match : (required ? .mismatch : .info), note: note))
        }

        // Locate the configuration-profile component.
        let components = detail.steps.flatMap(\.components).filter { $0.identifier == BlueprintBuilder.componentIdentifier }
        guard components.count == 1, let configuration = components[0].configuration?.objectValue else {
            rows.append(FidelityRow(
                field: "Component \(BlueprintBuilder.componentIdentifier)",
                classic: "1", blueprint: String(components.count), status: .mismatch,
                note: components.count == 1 ? "Component has no configuration object." : "Expected exactly one configuration-profile component."
            ))
            rows.append(scopeRow(expectedGroupIDs, detail))
            return FidelityReport(rows: rows)
        }

        // Rule 3: top-level identifiers.
        row("payloadIdentifier (top level)", document.payloadIdentifier, configuration.value(forKeyIgnoringCase: "payloadIdentifier")?.value.stringValue)
        row("payloadUUID (top level)", document.payloadUUID, configuration.value(forKeyIgnoringCase: "payloadUUID")?.value.stringValue)
        row("payloadDisplayName (top level)", document.payloadDisplayName, configuration.value(forKeyIgnoringCase: "payloadDisplayName")?.value.stringValue,
            required: false, note: "Display name may be normalised by the server.")

        // Rule 4: payload count.
        let returned = configuration.value(forKeyIgnoringCase: "payloadContent")?.value.arrayValue?.compactMap(\.objectValue) ?? []
        row("Payload count", String(document.payloads.count), String(returned.count))

        // Rule 5: per-payload identity, in order, plus settings values.
        for (index, payload) in document.payloads.enumerated() {
            let label = "Payload \(index + 1)"
            guard index < returned.count else {
                rows.append(FidelityRow(field: "\(label) (\(payload.type ?? "?"))", classic: "present", blueprint: "missing", status: .mismatch))
                continue
            }
            let object = returned[index]
            func value(_ key: String) -> String? { object.value(forKeyIgnoringCase: key)?.value.stringValue }
            row("\(label) payloadType", payload.type, value("payloadType"))
            row("\(label) payloadIdentifier", payload.identifier, value("payloadIdentifier"))
            row("\(label) payloadUUID", payload.uuid, value("payloadUUID"))

            for key in serverManagedKeys {
                let source = payload.content[key]?.displaySummary
                let server = object.value(forKeyIgnoringCase: key)?.value.displaySummary
                guard source != server else { continue }
                let field = "\(label) \(key.prefix(1).lowercased() + key.dropFirst())"
                // Observed live: the server drops PayloadEnabled. Dropping `false` would
                // silently enable a disabled payload, so that one is a real mismatch.
                if key == "PayloadEnabled", payload.content[key] == .bool(false), server != "false" {
                    rows.append(FidelityRow(field: field, classic: "false", blueprint: server ?? "(dropped)", status: .mismatch,
                                            note: "The payload was disabled in the classic profile but isn't in the blueprint."))
                } else {
                    rows.append(FidelityRow(field: field, classic: source ?? "—", blueprint: server ?? "(dropped)", status: .info,
                                            note: "Server-managed metadata; the server re-adds, normalises or drops these."))
                }
            }

            rows += settingsRows(label: label, source: payload.content, returned: object)
        }

        if returned.count > document.payloads.count {
            rows.append(FidelityRow(field: "Extra payloads", classic: "0", blueprint: String(returned.count - document.payloads.count), status: .mismatch))
        }

        rows.append(scopeRow(expectedGroupIDs, detail))
        return FidelityReport(rows: rows)
    }

    private static func scopeRow(_ expected: [String], _ detail: BlueprintDetail) -> FidelityRow {
        let actual = detail.scope?.deviceGroups ?? []
        let normalizedExpected = Set(expected.map { $0.lowercased() })
        let normalizedActual = Set(actual.map { $0.lowercased() })
        return FidelityRow(
            field: "Scope device groups",
            classic: expected.joined(separator: ", "),
            blueprint: actual.joined(separator: ", "),
            status: normalizedExpected == normalizedActual ? .match : .mismatch,
            note: "Classic side shows the platform groups you selected."
        )
    }

    /// Compares the non-wrapper keys of one payload.
    private static func settingsRows(label: String, source: PlistDictionary, returned: JSONObject) -> [FidelityRow] {
        let sourceSettings = PlistDictionary(source.entries.filter { !wrapperKeys.contains($0.key) })
        let returnedSettings = JSONObject(returned.entries.filter { entry in
            !wrapperKeys.contains { $0.caseInsensitiveCompare(entry.key) == .orderedSame }
        })

        var options = PlistJSONComparator.Options()
        options.caseInsensitiveKeys = true
        options.tolerateServerRewrites = true
        let differences = PlistJSONComparator.differences(plist: .dict(sourceSettings), json: .object(returnedSettings), options: options)
        // A documented server rewrite is shown but does not block the deployment; only
        // an unexplained difference means the blueprint wouldn't match the source.
        var rows = differences.map { difference in
            FidelityRow(
                field: "\(label) \(difference.path)", classic: difference.expected, blueprint: difference.actual,
                status: difference.serverRewrite == nil ? .mismatch : .info, note: difference.serverRewrite
            )
        }

        for change in keyCaseChanges(.dict(sourceSettings), .object(returnedSettings), path: "") {
            rows.append(FidelityRow(field: "\(label) \(change.path)", classic: change.expected, blueprint: change.actual, status: .caseChanged,
                                    note: "Key casing changed. Expected for Rules/RuleType/RuleValue; otherwise confirm the device still reads it."))
        }

        if !rows.contains(where: { $0.status == .mismatch }) {
            let tolerated = differences.count { $0.serverRewrite != nil }
            rows.insert(FidelityRow(
                field: "\(label) settings", classic: "\(sourceSettings.count) keys", blueprint: "\(returnedSettings.count) keys",
                status: .match,
                note: tolerated == 0
                    ? "All setting values equal."
                    : "All setting values equal; \(tolerated) known server rewrite\(tolerated == 1 ? "" : "s") listed below."
            ), at: 0)
        }
        return rows
    }

    // MARK: - Five-rule checklist

    nonisolated enum RuleStatus: Hashable, Sendable {
        case pass
        case fail
        /// Can't be checked through the API; a person must confirm it.
        case confirmOnDevice
    }

    nonisolated struct RuleCheck: Hashable, Sendable, Identifiable {
        var number: Int
        var title: String
        var status: RuleStatus
        var detail: String

        var id: Int { number }
    }

    /// Apple's five conditions for a seamless in-place transform, evaluated against a
    /// `com.jamf.ddm-configuration-profile` configuration (built locally or read back).
    static func ruleChecklist(document: ProfileDocument, configuration: JSONObject) -> [RuleCheck] {
        func string(_ object: JSONObject, _ key: String) -> String? {
            object.value(forKeyIgnoringCase: key)?.value.stringValue
        }
        let payloads = configuration.value(forKeyIgnoringCase: "payloadContent")?.value.arrayValue?.compactMap(\.objectValue) ?? []

        let topIdentifier = string(configuration, "payloadIdentifier")
        let topUUID = string(configuration, "payloadUUID")
        let rule3 = topIdentifier == document.payloadIdentifier && topUUID == document.payloadUUID && topIdentifier != nil && topUUID != nil

        let rule4 = payloads.count == document.payloads.count

        var mismatched: [String] = []
        for (index, payload) in document.payloads.enumerated() {
            guard index < payloads.count else { mismatched.append("payload \(index + 1) missing"); continue }
            let other = payloads[index]
            for (key, value) in [("payloadType", payload.type), ("payloadIdentifier", payload.identifier), ("payloadUUID", payload.uuid)]
            where string(other, key) != value || value == nil {
                mismatched.append("payload \(index + 1) \(key)")
            }
        }

        return [
            RuleCheck(number: 1, title: "Classic profile was installed by MDM", status: .confirmOnDevice,
                      detail: "Not visible through the API. Profiles installed manually or by another tool won't transform."),
            RuleCheck(number: 2, title: "DDM is enabled", status: .confirmOnDevice,
                      detail: "Requires Declarative Device Management on each target device."),
            RuleCheck(number: 3, title: "Top-level PayloadIdentifier and PayloadUUID match", status: rule3 ? .pass : .fail,
                      detail: "Classic \(document.payloadIdentifier ?? "—") / \(document.payloadUUID ?? "—") · Blueprint \(topIdentifier ?? "—") / \(topUUID ?? "—")"),
            RuleCheck(number: 4, title: "Same number of payloads", status: rule4 ? .pass : .fail,
                      detail: "Classic \(document.payloads.count) · Blueprint \(payloads.count)"),
            RuleCheck(number: 5, title: "Each payload's type, identifier and UUID match, in order", status: mismatched.isEmpty ? .pass : .fail,
                      detail: mismatched.isEmpty ? "All \(document.payloads.count) payload(s) match in order." : "Differs: " + mismatched.joined(separator: ", ")),
        ]
    }

    /// Keys whose value matched case-insensitively but whose spelling changed.
    static func keyCaseChanges(_ plist: PlistValue, _ json: JSONValue, path: String) -> [ValueDifference] {
        switch (plist, json) {
        case let (.dict(dict), .object(object)):
            return dict.entries.flatMap { entry -> [ValueDifference] in
                guard let match = object.value(forKeyIgnoringCase: entry.key) else { return [] }
                let childPath = path.isEmpty ? entry.key : "\(path).\(entry.key)"
                var result: [ValueDifference] = []
                if match.key != entry.key {
                    result.append(ValueDifference(path: childPath, expected: entry.key, actual: match.key))
                }
                return result + keyCaseChanges(entry.value, match.value, path: childPath)
            }
        case let (.array(a), .array(b)):
            return zip(a, b).enumerated().flatMap { index, pair in keyCaseChanges(pair.0, pair.1, path: "\(path)[\(index)]") }
        default:
            return []
        }
    }
}
