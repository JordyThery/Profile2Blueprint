import Foundation

/// Jamf Platform API Gateway region. Tokens are region-locked, so the token host
/// and the API host must always match.
nonisolated enum Region: String, Codable, CaseIterable, Identifiable, Sendable {
    case us
    case eu
    case apac

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .us: "United States (us)"
        case .eu: "Europe (eu)"
        case .apac: "Asia Pacific (apac)"
        }
    }
}

/// How a blueprint's suggested name is built from the classic profile's name.
/// Either affix may be empty; with both empty the name is the profile's name verbatim.
nonisolated struct BlueprintNaming: Codable, Hashable, Sendable {
    /// The suffix used before naming was configurable, kept as the default so existing
    /// tenants and the demo behave as before.
    static let defaultSuffix = " (migrated)"
    static let `default` = BlueprintNaming()

    var prefix: String
    var suffix: String

    init(prefix: String = "", suffix: String = Self.defaultSuffix) {
        self.prefix = prefix
        self.suffix = suffix
    }

    /// Affixes are written verbatim, so spacing is whatever was typed — a prefix of
    /// "TEST -" and "TEST - " are different on purpose.
    ///
    /// When the result exceeds `limit` the profile name is shortened rather than the
    /// affixes, so a naming convention survives a long source name. If the affixes
    /// alone fill the limit, the whole name is truncated instead.
    func name(for profileName: String, limit: Int = BlueprintBuilder.maxNameLength) -> String {
        let available = limit - prefix.count - suffix.count
        guard available > 0 else { return String((prefix + profileName + suffix).prefix(limit)) }
        return prefix + profileName.prefix(available) + suffix
    }
}

/// Web links into the Jamf Pro console, built from the address users see in their
/// browser. The gateway the app talks to has no route back to it, so it is entered
/// by hand rather than fetched (which would need an extra API permission).
nonisolated struct JamfProLinks: Hashable, Sendable {
    let base: URL

    /// Accepts the address with or without a scheme, a path or a trailing slash, as
    /// people paste it. Only the host (and port) is kept; anything else is `nil`.
    init?(_ address: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("https://") && !text.lowercased().hasPrefix("http://") {
            text = "https://" + text
        }
        guard let parsed = URLComponents(string: text), let host = parsed.host, host.contains("."), !host.contains(" ") else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = parsed.port
        guard let url = components.url else { return nil }
        base = url
    }

    /// Opens read-only (`o=r`), so following the link can't put a profile into edit mode.
    func classicProfile(id: Int) -> URL {
        base.appending(path: "OSXConfigurationProfiles.html")
            .appending(queryItems: [URLQueryItem(name: "id", value: String(id)), URLQueryItem(name: "o", value: "r")])
    }

    func blueprint(id: String) -> URL {
        base.appending(path: "view/mfe/blueprints").appending(path: id)
    }
}

/// A saved Jamf platform environment the app can talk to.
///
/// Only non-secret values live here. The OAuth client secret is stored in the
/// Keychain, keyed by `id`.
nonisolated struct Tenant: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var region: Region
    /// Platform environment UUID, sent as `X-Environment-Id`.
    var environmentID: String
    var clientID: String
    /// Optional gateway host override (for example a staging host).
    /// `nil` or empty means production: `{region}.api.jamfcloud.com`.
    var hostOverride: String?
    /// Explicit opt-in that allows the app to change (only) the scope of classic
    /// profiles on this tenant. Off by default; while off, every Classic write is refused.
    var allowClassicScopeChanges: Bool
    /// Prefix and suffix applied to suggested blueprint names on this tenant, so a test
    /// environment can be labelled differently from production.
    var naming: BlueprintNaming
    /// Template for the suggested blueprint description, with the tokens in
    /// `BlueprintBuilder.descriptionTokens`. Empty means no description.
    var descriptionTemplate: String
    /// The Jamf Pro web address, for "Open in Jamf Pro". Optional; the buttons are
    /// hidden while it is empty or invalid.
    var jamfProURL: String

    init(
        id: UUID = UUID(),
        name: String = "",
        region: Region = .us,
        environmentID: String = "",
        clientID: String = "",
        hostOverride: String? = nil,
        allowClassicScopeChanges: Bool = false,
        naming: BlueprintNaming = .default,
        descriptionTemplate: String = BlueprintBuilder.defaultDescriptionTemplate,
        jamfProURL: String = ""
    ) {
        self.allowClassicScopeChanges = allowClassicScopeChanges
        self.naming = naming
        self.descriptionTemplate = descriptionTemplate
        self.jamfProURL = jamfProURL
        self.id = id
        self.name = name
        self.region = region
        self.environmentID = environmentID
        self.clientID = clientID
        self.hostOverride = hostOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, region, environmentID, clientID, hostOverride, allowClassicScopeChanges, naming, descriptionTemplate, jamfProURL
    }

    /// Tolerates tenants saved before the later settings existed: scope changes decode
    /// as off, the name and description fall back to the wording used before they
    /// were configurable, and the Jamf Pro address as unset.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        region = try container.decode(Region.self, forKey: .region)
        environmentID = try container.decode(String.self, forKey: .environmentID)
        clientID = try container.decode(String.self, forKey: .clientID)
        hostOverride = try container.decodeIfPresent(String.self, forKey: .hostOverride)
        allowClassicScopeChanges = try container.decodeIfPresent(Bool.self, forKey: .allowClassicScopeChanges) ?? false
        naming = try container.decodeIfPresent(BlueprintNaming.self, forKey: .naming) ?? .default
        descriptionTemplate = try container.decodeIfPresent(String.self, forKey: .descriptionTemplate)
            ?? BlueprintBuilder.defaultDescriptionTemplate
        jamfProURL = try container.decodeIfPresent(String.self, forKey: .jamfProURL) ?? ""
    }

    /// Display name with a fallback for unnamed tenants.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled tenant" : trimmed
    }

    /// The gateway host, with any scheme or trailing slash stripped from the override.
    var host: String {
        if let override = hostOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            var value = override
            for prefix in ["https://", "http://"] where value.lowercased().hasPrefix(prefix) {
                value.removeFirst(prefix.count)
            }
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        return "\(region.rawValue).api.jamfcloud.com"
    }

    var usesHostOverride: Bool {
        !(hostOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// `https://<host>`; always HTTPS.
    var baseURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        guard let url = components.url, !host.isEmpty, !host.contains("/") else { return nil }
        return url
    }

    var jamfProLinks: JamfProLinks? { JamfProLinks(jamfProURL) }

    /// The environment ID normalised to the lowercase form the spec's pattern expects.
    var normalizedEnvironmentID: String {
        environmentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Human-readable problems that prevent connecting. Empty when the tenant is usable.
    var validationIssues: [String] {
        var issues: [String] = []
        if UUID(uuidString: normalizedEnvironmentID) == nil {
            issues.append("Environment ID must be a UUID (copy it from Integration details in Jamf Account).")
        }
        if clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Client ID is required.")
        }
        if baseURL == nil {
            issues.append("Host override is not a valid host name.")
        }
        return issues
    }
}
