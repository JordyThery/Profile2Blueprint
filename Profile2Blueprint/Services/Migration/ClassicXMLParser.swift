import Foundation

/// Parses Classic API XML (both profile families) into models.
///
/// The payload plist arrives XML-escaped inside `general/payloads`; reading the
/// element's string value unescapes it before `PlistParser` sees it.
nonisolated enum ClassicXMLParser {
    static func parseProfileList(_ data: Data, platform: ProfilePlatform) throws -> [ClassicProfileSummary] {
        let root = try rootElement(data, expected: platform.listRootElement)
        return root.elements(forName: platform.profileRootElement).compactMap { element in
            guard let id = element.intValue(of: "id") else { return nil }
            return ClassicProfileSummary(platform: platform, profileID: id, name: element.textValue(of: "name") ?? "")
        }
    }

    static func parseProfile(_ data: Data, platform: ProfilePlatform) throws -> ClassicProfile {
        let root = try rootElement(data, expected: platform.profileRootElement)
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
            platform: platform,
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
            scope: root.child("scope").map { parseScope($0, platform: platform) } ?? ClassicScope(),
            rawScopeXML: root.child("scope")?.xmlString ?? "<scope/>",
            document: document
        )
    }

    // MARK: - Scope

    /// Parses a standalone `<scope>` element (e.g. a saved backup).
    static func parseScopeXML(_ xml: String, platform: ProfilePlatform) throws -> ClassicScope {
        let document = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        guard let root = document.rootElement(), root.name == "scope" else {
            throw APIError.decoding("Not a <scope> element.")
        }
        return parseScope(root, platform: platform)
    }

    /// Scope children with a dedicated field, for either platform: everything else
    /// lands in `otherTargets`.
    private static let primaryScopeKinds: Set<String> = [
        "all_computers", "computers", "computer_groups",
        "all_mobile_devices", "mobile_devices", "mobile_device_groups",
        "all_jss_users", "buildings", "departments", "limitations", "exclusions",
    ]

    private static func parseScope(_ element: XMLElement, platform: ProfilePlatform) -> ClassicScope {
        var scope = ClassicScope()
        scope.allDevices = element.textValue(of: platform.allDevicesElement) == "true"
        scope.allJSSUsers = element.textValue(of: "all_jss_users") == "true"
        scope.deviceGroups = references(in: element.child(platform.deviceGroupsElement))
        scope.devices = references(in: element.child(platform.devicesElement))
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
