import Foundation

/// Decides whether a classic profile can be transformed in place into a DDM
/// legacy-profile blueprint. Pure: no I/O, so the whole table is unit-tested.
nonisolated enum EligibilityChecker {
    /// Payload types the Blueprints API refuses to create.
    static let blockedPayloadTypes: Set<String> = ["com.apple.font", "com.apple.webClip.managed"]

    /// Server-side validation rules seen live: `(payload type, key)` that must not be an empty array.
    static let knownServerRules: [(payloadType: String, key: String)] = [
        ("com.apple.wifi.managed", "SetupModes"),
    ]

    /// Top-level keys that are carried into the blueprint configuration (or implied by it).
    static let carriedTopLevelKeys: Set<String> = [
        "PayloadUUID", "PayloadIdentifier", "PayloadDisplayName", "PayloadContent", "PayloadType", "PayloadVersion",
    ]

    static func check(_ profile: ClassicProfile, platformGroups: [PlatformGroup]) -> EligibilityReport {
        var findings: [EligibilityFinding] = []
        func add(_ kind: FindingKind, _ severity: FindingSeverity, _ title: String, _ detail: String) {
            findings.append(EligibilityFinding(kind: kind, severity: severity, title: title, detail: detail))
        }

        // Level
        switch profile.level {
        case .system:
            break
        case .user:
            add(.userLevel, .blocker, "User-level profile",
                "v1 only migrates computer-level (System) profiles. User-channel profiles are out of scope.")
        case let .other(raw):
            add(.userLevel, .blocker, "Unknown profile level “\(raw)”",
                "Only computer-level (System) profiles can be migrated.")
        }

        // Payload document and rules 3–5 prerequisites
        switch profile.document {
        case let .failure(error):
            add(.unparseablePayload, .blocker, "Payload plist can't be read", error.message)
        case let .success(document):
            checkDocument(document, profile: profile, add: add)
        }

        // Scope
        let mapping = ScopeMapper.propose(for: profile.scope, platformGroups: platformGroups)
        checkScope(profile.scope, mapping: mapping, add: add)

        // Distribution
        if profile.distributionMethod.localizedCaseInsensitiveContains("self service") {
            add(.selfService, .warning, "Self Service profile",
                "In Jamf Pro this profile is only installed when a user chooses it in Self Service. A blueprint installs on every device in its target group, which may reach devices that never had the classic profile.")
        }

        if let site = profile.site {
            add(.site, .info, "Site “\(site.name)”",
                "Blueprints have no sites. Access control and scoping are only by the selected device group.")
        }

        add(.cannotVerifyDevicePreconditions, .info, "Confirm on devices: installed by MDM and DDM enabled",
            "The in-place transform also requires that the classic profile was installed by MDM and that Declarative Device Management is enabled on each device. The API can't verify either, so confirm them before deploying.")

        return EligibilityReport(findings: findings, scopeMapping: mapping)
    }

    // MARK: - Document

    private static func checkDocument(
        _ document: ProfileDocument,
        profile: ClassicProfile,
        add: (FindingKind, FindingSeverity, String, String) -> Void
    ) {
        if document.payloads.isEmpty {
            add(.noPayloads, .blocker, "No payloads",
                "PayloadContent is empty or missing, so there is nothing to migrate and the payload-count rule can't be met.")
        }

        var missing: [String] = []
        if (document.payloadIdentifier ?? "").isEmpty { missing.append("top-level PayloadIdentifier") }
        if (document.payloadUUID ?? "").isEmpty { missing.append("top-level PayloadUUID") }
        if document.hasMalformedPayloadContent { missing.append("PayloadContent has entries that aren't dictionaries") }
        for payload in document.payloads {
            let label = "payload \(payload.index + 1) (\(payload.type ?? "unknown type"))"
            if (payload.type ?? "").isEmpty { missing.append("\(label): PayloadType") }
            if (payload.identifier ?? "").isEmpty { missing.append("\(label): PayloadIdentifier") }
            if (payload.uuid ?? "").isEmpty { missing.append("\(label): PayloadUUID") }
        }
        if !missing.isEmpty {
            add(.missingIdentifiers, .blocker, "Missing identifiers",
                "The transform matches identifiers exactly, so these are required: " + missing.joined(separator: "; ") + ".")
        }

        let blocked = document.payloads.compactMap(\.type).filter(blockedPayloadTypes.contains)
        if !blocked.isEmpty {
            add(.blockedPayloadType, .blocker, "Unsupported payload type",
                "Blueprints containing \(Set(blocked).sorted().joined(separator: ", ")) payloads cannot be created.")
        }

        let uuids = document.payloads.compactMap(\.uuid)
        if Set(uuids).count != uuids.count {
            add(.duplicatePayloadUUIDs, .warning, "Duplicate payload UUIDs",
                "Two or more payloads share a PayloadUUID. The device may reject the profile.")
        }

        if let uuid = document.payloadUUID, !profile.uuid.isEmpty, profile.uuid != uuid {
            add(.recordUUIDMismatch, .warning, "Jamf Pro record UUID differs from the plist PayloadUUID",
                "Jamf Pro records “\(profile.uuid)” but the payload plist says PayloadUUID “\(uuid)”. This is typical of uploaded or signed profiles. The transform only works if the blueprint matches the UUID actually installed. Check it on a device (`sudo profiles show -type configuration`) before deploying.")
        }

        if (document.payloadIdentifier ?? "").hasPrefix("com.jamf.protect.") || profile.uuid.hasPrefix("com.jamf.protect.") {
            add(.jamfProtectManaged, .warning, "Managed by the Jamf Protect integration",
                "Jamf Protect creates and updates this profile. Migrating it means Protect may keep re-pushing the classic profile, which would conflict with the blueprint.")
        }

        let dropped = document.root.keys.filter { !carriedTopLevelKeys.contains($0) }
        if !dropped.isEmpty {
            add(.droppedTopLevelKeys, .info, "Top-level keys not carried over",
                "The blueprint body has no fields for: \(dropped.joined(separator: ", ")). The server sets its own values.")
        }

        // Known server-side schema rules, observed against the live Blueprints API.
        var rejected: [String] = []
        for payload in document.payloads {
            for rule in knownServerRules where rule.payloadType == payload.type {
                if case let .array(values)? = payload.content[rule.key], values.isEmpty {
                    rejected.append("payload \(payload.index + 1) (\(rule.payloadType)) has an empty \(rule.key)")
                }
            }
        }
        if !rejected.isEmpty {
            add(.serverValidation, .blocker, "The Blueprints API will reject this payload",
                "The server validates known payload types against Apple's schema: " + rejected.joined(separator: "; ")
                    + ". Fix it in the classic profile (choose a setup mode, or remove the key) and reload, otherwise create fails with HTTP 400.")
        }

        let disabled = document.payloads.filter { $0.content["PayloadEnabled"] == .bool(false) }
        if !disabled.isEmpty {
            add(.disabledPayload, .warning, "Disabled payloads",
                "Payload \(disabled.map { String($0.index + 1) }.joined(separator: ", ")) has PayloadEnabled = false. The Blueprints API drops PayloadEnabled, so the payload would become active.")
        }

        if containsSensitiveContent(document) {
            add(.sensitiveContent, .info, "Contains credentials",
                "This profile includes passwords or private keys (for example PKCS#12 identities). They will be sent to the Blueprints API and appear in the JSON preview.")
        }
    }

    private static func containsSensitiveContent(_ document: ProfileDocument) -> Bool {
        if document.payloads.contains(where: { $0.type == "com.apple.security.pkcs12" }) { return true }
        func walk(_ value: PlistValue) -> Bool {
            switch value {
            case let .dict(dict):
                return dict.entries.contains { entry in
                    let isSecretKey = entry.key.localizedCaseInsensitiveContains("password")
                        || entry.key.localizedCaseInsensitiveContains("secret")
                    if isSecretKey, case let .string(text) = entry.value, !text.isEmpty { return true }
                    return walk(entry.value)
                }
            case let .array(values):
                return values.contains(where: walk)
            default:
                return false
            }
        }
        return walk(.dict(document.root))
    }

    // MARK: - Scope

    private static func checkScope(
        _ scope: ClassicScope,
        mapping: [ScopeMappingEntry],
        add: (FindingKind, FindingSeverity, String, String) -> Void
    ) {
        if mapping.allSatisfy({ $0.autoMatch == nil }) {
            add(.noMappedGroup, .warning, "No scope group maps to a platform group",
                scope.computerGroups.isEmpty
                    ? "The profile isn't scoped to any computer group. Pick a platform device group for the blueprint."
                    : "None of the profile's computer groups has an exact name match in the platform. Pick a platform device group.")
        }

        let unmatched = mapping.filter(\.isUnmatched)
        if !unmatched.isEmpty, unmatched.count < mapping.count {
            add(.unmatchedGroups, .warning, "Some groups have no platform match",
                "No exact platform group for: \(unmatched.map(\.classicGroup.name).joined(separator: ", ")). Pick one or leave it out.")
        }

        let ambiguous = mapping.filter(\.isAmbiguous)
        if !ambiguous.isEmpty {
            add(.ambiguousGroups, .warning, "Ambiguous group names",
                "Several platform groups are named \(ambiguous.map { "“\($0.classicGroup.name)”" }.joined(separator: ", ")). Choose the right one.")
        }

        if scope.allComputers {
            add(.allComputers, .warning, "Scoped to All Computers",
                "Blueprints can only target device groups. Pick a platform group that covers the same computers (for example an “All Managed Clients” smart group).")
        }

        var other: [String] = []
        if !scope.computers.isEmpty { other.append("\(scope.computers.count) individual computer\(scope.computers.count == 1 ? "" : "s")") }
        if !scope.buildings.isEmpty { other.append("buildings (\(scope.buildings.map(\.name).joined(separator: ", ")))") }
        if !scope.departments.isEmpty { other.append("departments (\(scope.departments.map(\.name).joined(separator: ", ")))") }
        for bucket in scope.otherTargets { other.append(bucket.displayName.lowercased()) }
        if scope.allJSSUsers { other.append("all JSS users") }
        if !other.isEmpty {
            add(.nonGroupTargets, .warning, "Targets without a blueprint equivalent",
                "Scope also includes \(other.joined(separator: ", ")). These can't be carried over. Pick a platform group that contains those devices.")
        }

        if scope.hasLimitations {
            add(.limitations, .warning, "Limitations are not carried over",
                "The classic scope is limited by \(scope.limitations.map { $0.displayName.lowercased() }.joined(separator: ", ")). The blueprint has no limitations and will apply to every member of the chosen group.")
        }

        if scope.hasExclusions {
            let list = scope.exclusions.map { "\($0.displayName.lowercased()) (\($0.items.map(\.name).joined(separator: ", ")))" }
            add(.exclusions, .warning, "Exclusions are NOT carried over",
                "Excluded: \(list.joined(separator: "; ")). The blueprint will reach these devices if they are in the target group. Use a platform group that already leaves them out.")
        }
    }
}
