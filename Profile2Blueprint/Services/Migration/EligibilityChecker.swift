import Foundation

/// Decides whether a classic profile can be transformed in place into a DDM
/// legacy-profile blueprint. Pure: no I/O, so the whole table is unit-tested.
nonisolated enum EligibilityChecker {
    /// When the payload-type tables below were probed against the Blueprints API.
    /// Both are instance- and version-specific; the API is the final authority.
    static let payloadTableProbeDate = "2026-07-17"

    /// Payload types the Blueprints API refuses outright. A blueprint carrying one is
    /// rejected with `400 Payload disabled: <type>` regardless of its keys.
    ///
    /// Source: Jamf's own `jamf-cli` (`internal/profileconvert`, `DisabledPayloadTypes`),
    /// wire-probed by Jamf against every Apple MDM payload type.
    static let blockedPayloadTypes: Set<String> = [
        "com.apple.ADCertificate.managed",
        "com.apple.DirectoryService.managed",
        "com.apple.MCX.FileVault2",
        "com.apple.airplay",
        "com.apple.airplay.security",
        "com.apple.cellular",
        "com.apple.dnsSettings.managed",
        "com.apple.education",
        "com.apple.ews.account",
        "com.apple.extensiblesso",
        "com.apple.font",
        "com.apple.profileRemovalPassword",
        "com.apple.proxy.http.global",
        "com.apple.security.pem",
        "com.apple.security.pkcs1",
        "com.apple.security.pkcs12",
        "com.apple.security.root",
        "com.apple.security.scep",
        "com.apple.vpn.managed",
        "com.apple.vpn.managed.appmapping",
        "com.apple.webClip.managed",
        "com.apple.webcontent-filter",
    ]

    /// Payload types the `com.jamf.ddm-configuration-profile` component accepts as
    /// standalone payloads. The component matches against a fixed registry rather than
    /// validating arbitrary Apple payloads; a type outside this set fails with the
    /// opaque `Failed to validate configuration.`
    ///
    /// Same source as `blockedPayloadTypes`. Treated as a warning rather than a blocker:
    /// an allow-list goes stale in the dangerous direction, so a type Jamf adds later
    /// must not make this app refuse a migration that now works.
    static let supportedPayloadTypes: Set<String> = [
        "com.apple.AssetCache.managed", "com.apple.Dictionary", "com.apple.DiscRecording",
        "com.apple.MCX.Accounts", "com.apple.MCX.EnergySaver", "com.apple.MCX.MobileAccounts",
        "com.apple.MCX.TimeMachine", "com.apple.MCX.TimeServer", "com.apple.ManagedClient.preferences",
        "com.apple.NSExtension", "com.apple.SetupAssistant.managed", "com.apple.SystemConfiguration",
        "com.apple.TCC.configuration-profile-policy", "com.apple.airprint", "com.apple.app.lock",
        "com.apple.applicationaccess", "com.apple.applicationaccess.new", "com.apple.appstore",
        "com.apple.asam", "com.apple.associated-domains", "com.apple.cellularprivatenetwork.managed",
        "com.apple.conferenceroomdisplay", "com.apple.desktop", "com.apple.dnsProxy.managed",
        "com.apple.dock", "com.apple.domains", "com.apple.familycontrols.contentfilter",
        "com.apple.familycontrols.timelimits.v2", "com.apple.fileproviderd", "com.apple.finder",
        "com.apple.firstactiveethernet.managed", "com.apple.firstethernet.managed", "com.apple.gamed",
        "com.apple.globalethernet.managed", "com.apple.homescreenlayout", "com.apple.loginitems.managed",
        "com.apple.loginwindow", "com.apple.lom", "com.apple.mcxMenuExtras", "com.apple.mcxprinting",
        "com.apple.networkusagerules", "com.apple.notificationsettings", "com.apple.preference.security",
        "com.apple.preference.users", "com.apple.relay.managed", "com.apple.screensaver",
        "com.apple.screensaver.user", "com.apple.secondactiveethernet.managed",
        "com.apple.secondethernet.managed", "com.apple.security.FDERecoveryKeyEscrow",
        "com.apple.security.acme", "com.apple.security.certificatepreference",
        "com.apple.security.certificaterevocation", "com.apple.security.certificatetransparency",
        "com.apple.security.firewall", "com.apple.security.identitypreference",
        "com.apple.security.smartcard", "com.apple.servicemanagement",
        "com.apple.shareddeviceconfiguration", "com.apple.syspolicy.kernel-extension-policy",
        "com.apple.system-extension-policy", "com.apple.systemmigration", "com.apple.systempolicy.control",
        "com.apple.systempolicy.managed", "com.apple.systempolicy.rule",
        "com.apple.thirdactiveethernet.managed", "com.apple.thirdethernet.managed", "com.apple.tvremote",
        "com.apple.universalaccess", "com.apple.vpn.managed.applayer", "com.apple.wifi.managed",
        "com.apple.xsan", "com.apple.xsan.preferences", "loginwindow",
    ]

    /// Payload types Jamf Pro writes that the Blueprints API spells differently. Jamf Pro
    /// uses the filename Apple publishes the schema under; the API only accepts Apple's
    /// declared type. Rewriting the type would break rule 5 against the installed
    /// profile, so these block migration instead.
    static let nonCanonicalPayloadTypes: [String: String] = [
        "com.apple.preferences.users": "com.apple.preference.users",
    ]

    /// Payload types the Jamf Pro blueprints UI can edit directly. Accepted types outside
    /// this set become read-only "Legacy payload" items, editable only through the API.
    ///
    /// Advisory only, so drift costs at worst a slightly wrong note.
    static let uiManageablePayloadTypes: Set<String> = [
        "com.apple.Dictionary", "com.apple.DiscRecording", "com.apple.MCX.Accounts",
        "com.apple.MCX.MobileAccounts", "com.apple.MCX.TimeMachine", "com.apple.MCX.TimeServer",
        "com.apple.NSExtension", "com.apple.SystemConfiguration",
        "com.apple.TCC.configuration-profile-policy", "com.apple.airprint", "com.apple.app.lock",
        "com.apple.applicationaccess", "com.apple.appstore", "com.apple.asam",
        "com.apple.cellularprivatenetwork.managed", "com.apple.conferenceroomdisplay",
        "com.apple.desktop", "com.apple.dnsProxy.managed", "com.apple.domains",
        "com.apple.familycontrols.contentfilter", "com.apple.fileproviderd", "com.apple.finder",
        "com.apple.gamed", "com.apple.loginitems.managed", "com.apple.loginwindow",
        "com.apple.mcxprinting", "com.apple.notificationsettings", "com.apple.preference.security",
        "com.apple.preference.users", "com.apple.screensaver", "com.apple.screensaver.user",
        "com.apple.security.firewall", "com.apple.security.smartcard", "com.apple.servicemanagement",
        "com.apple.shareddeviceconfiguration", "com.apple.syspolicy.kernel-extension-policy",
        "com.apple.systempolicy.control", "com.apple.systempolicy.managed", "com.apple.tvremote",
        "com.apple.universalaccess", "loginwindow",
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
                "Only computer-level (System) profiles can be migrated. User-channel profiles are out of scope.")
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

        let types = document.payloads.compactMap(\.type)

        let blocked = types.filter(blockedPayloadTypes.contains)
        if !blocked.isEmpty {
            add(.blockedPayloadType, .blocker, "Payload type the Blueprints API refuses",
                "Blueprints cannot contain \(Set(blocked).sorted().joined(separator: ", ")). The API rejects the whole blueprint with “Payload disabled”. Probed \(payloadTableProbeDate); if Jamf has since enabled it, the create call is the authority.")
        }

        let nonCanonical = types.compactMap { type in
            nonCanonicalPayloadTypes[type].map { (written: type, expected: $0) }
        }
        if !nonCanonical.isEmpty {
            add(.nonCanonicalPayloadType, .blocker, "Payload type Jamf Pro spells differently",
                "Jamf Pro wrote \(nonCanonical.map { "“\($0.written)”" }.joined(separator: ", ")), but the Blueprints API only accepts \(nonCanonical.map { "“\($0.expected)”" }.joined(separator: ", ")). Rewriting the type would break the rule that every payload type matches the installed profile, so this profile can't be transformed in place.")
        }

        let unrecognised = Set(types).subtracting(supportedPayloadTypes)
            .subtracting(blockedPayloadTypes)
            .subtracting(nonCanonicalPayloadTypes.keys)
        if !unrecognised.isEmpty {
            add(.unsupportedPayloadType, .warning, "Payload type not in the known registry",
                "The configuration-profile component matches payload types against a fixed registry, and \(unrecognised.sorted().joined(separator: ", ")) wasn't in it when this was probed (\(payloadTableProbeDate)). Create may fail with “Failed to validate configuration.” Attempting it is safe: the API is the authority and the registry may have grown.")
        }

        let apiOnly = Set(types).intersection(supportedPayloadTypes).subtracting(uiManageablePayloadTypes)
        if !apiOnly.isEmpty {
            add(.apiOnlyPayload, .info, "Not editable in the Jamf Pro UI",
                "\(apiOnly.sorted().joined(separator: ", ")) will appear in the blueprint as read-only “Legacy payload” items, editable only through the API.")
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

        // Empty strings and empty arrays are artefacts of the classic UI that the DDM API
        // rejects. Only a payload's own keys are checked: that is the depth at which the
        // API enforces it. Seen live as an empty Wi-Fi SetupModes (HTTP 400 SIZE).
        var rejected: [String] = []
        for payload in document.payloads {
            for entry in payload.content.entries where !FidelityVerifier.wrapperKeys.contains(entry.key) {
                let empty: String?
                switch entry.value {
                case let .string(text) where text.isEmpty: empty = "empty string"
                case let .array(values) where values.isEmpty: empty = "empty array"
                default: empty = nil
                }
                if let empty {
                    rejected.append("payload \(payload.index + 1) (\(payload.type ?? "unknown type")) has an \(empty) for \(entry.key)")
                }
            }
        }
        if !rejected.isEmpty {
            add(.serverValidation, .blocker, "The Blueprints API will reject this payload",
                "Empty values are rejected by the API: " + rejected.joined(separator: "; ")
                    + ". Give the key a value in the classic profile, or remove it, then reload. Otherwise create fails with HTTP 400.")
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

    /// Certificate payload types are not checked here: they are all in
    /// `blockedPayloadTypes`, so saying their contents would be uploaded is misleading.
    private static func containsSensitiveContent(_ document: ProfileDocument) -> Bool {
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
