import Foundation

/// Parses Classic API XML (`/osxconfigurationprofiles…`) into models.
///
/// The payload plist arrives XML-escaped inside `general/payloads`; reading the
/// element's string value unescapes it before `PlistParser` sees it.
nonisolated enum ClassicXMLParser {
    static func parseProfileList(_ data: Data) throws -> [ClassicProfileSummary] {
        let root = try rootElement(data, expected: "os_x_configuration_profiles")
        return root.elements(forName: "os_x_configuration_profile").compactMap { element in
            guard let id = element.intValue(of: "id") else { return nil }
            return ClassicProfileSummary(id: id, name: element.textValue(of: "name") ?? "")
        }
    }

    static func parseProfile(_ data: Data) throws -> ClassicProfile {
        let root = try rootElement(data, expected: "os_x_configuration_profile")
        guard let general = root.child("general") else {
            throw APIError.decoding("Profile XML has no <general> element.")
        }
        guard let id = general.intValue(of: "id") else {
            throw APIError.decoding("Profile XML has no general/id.")
        }

        let payloads = general.textValue(of: "payloads") ?? ""
        let document: Result<ProfileDocument, PlistParseError>
        if payloads.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document = .failure(PlistParseError(message: "The profile has no payload plist."))
        } else {
            do {
                let value = try PlistParser.parse(payloads)
                if let dict = value.dictValue {
                    document = .success(ProfileDocument(root: dict))
                } else {
                    document = .failure(PlistParseError(message: "Payload plist root is a \(value.typeName), not a dict."))
                }
            } catch {
                document = .failure(error)
            }
        }

        return ClassicProfile(
            id: id,
            name: general.textValue(of: "name") ?? "",
            description: general.textValue(of: "description") ?? "",
            site: general.child("site").flatMap(reference(from:)).flatMap { $0.id == -1 ? nil : $0 },
            category: general.child("category").flatMap(reference(from:)).flatMap { $0.id == -1 ? nil : $0 },
            level: ProfileLevel(general.textValue(of: "level") ?? ""),
            distributionMethod: general.textValue(of: "distribution_method") ?? "",
            userRemovable: general.textValue(of: "user_removable") == "true",
            redeployOnUpdate: general.textValue(of: "redeploy_on_update") ?? "",
            uuid: general.textValue(of: "uuid") ?? "",
            payloadsPlist: payloads,
            scope: root.child("scope").map(parseScope) ?? ClassicScope(),
            rawScopeXML: root.child("scope")?.xmlString ?? "<scope/>",
            document: document
        )
    }

    // MARK: - Scope

    /// Parses a standalone `<scope>` element (e.g. a saved backup).
    static func parseScopeXML(_ xml: String) throws -> ClassicScope {
        let document = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        guard let root = document.rootElement(), root.name == "scope" else {
            throw APIError.decoding("Not a <scope> element.")
        }
        return parseScope(root)
    }

    private static let primaryScopeKinds: Set<String> = [
        "all_computers", "all_jss_users", "computers", "computer_groups", "buildings",
        "departments", "limitations", "exclusions",
    ]

    private static func parseScope(_ element: XMLElement) -> ClassicScope {
        var scope = ClassicScope()
        scope.allComputers = element.textValue(of: "all_computers") == "true"
        scope.allJSSUsers = element.textValue(of: "all_jss_users") == "true"
        scope.computerGroups = references(in: element.child("computer_groups"))
        scope.computers = references(in: element.child("computers"))
        scope.buildings = references(in: element.child("buildings"))
        scope.departments = references(in: element.child("departments"))
        scope.otherTargets = buckets(in: element) { !primaryScopeKinds.contains($0) }
        scope.limitations = element.child("limitations").map { buckets(in: $0) { _ in true } } ?? []
        scope.exclusions = element.child("exclusions").map { buckets(in: $0) { _ in true } } ?? []
        return scope
    }

    /// Non-empty child lists of `element` as buckets, in document order.
    private static func buckets(in element: XMLElement, include: (String) -> Bool) -> [ScopeBucket] {
        element.childElements.compactMap { child in
            guard let kind = child.name, include(kind) else { return nil }
            let items = references(in: child)
            return items.isEmpty ? nil : ScopeBucket(kind: kind, items: items)
        }
    }

    private static func references(in list: XMLElement?) -> [ClassicReference] {
        list?.childElements.compactMap(reference(from:)) ?? []
    }

    private static func reference(from element: XMLElement) -> ClassicReference? {
        let id = element.intValue(of: "id")
        let name = element.textValue(of: "name") ?? element.textValue(of: "username")
        guard id != nil || name != nil else { return nil }
        return ClassicReference(id: id, name: name ?? "")
    }

    // MARK: - Helpers

    private static func rootElement(_ data: Data, expected: String) throws -> XMLElement {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw APIError.decoding("Classic API returned invalid XML: \(error.localizedDescription)")
        }
        guard let root = document.rootElement(), root.name == expected else {
            throw APIError.decoding("Expected <\(expected)> from the Classic API, got <\(document.rootElement()?.name ?? "nothing")>.")
        }
        return root
    }
}

private extension XMLElement {
    nonisolated var childElements: [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }
    }

    nonisolated func child(_ name: String) -> XMLElement? {
        elements(forName: name).first
    }

    nonisolated func textValue(of name: String) -> String? {
        child(name)?.stringValue
    }

    nonisolated func intValue(of name: String) -> Int? {
        textValue(of: name).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
