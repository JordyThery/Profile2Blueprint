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

    init(
        id: UUID = UUID(),
        name: String = "",
        region: Region = .us,
        environmentID: String = "",
        clientID: String = "",
        hostOverride: String? = nil,
        allowClassicScopeChanges: Bool = false
    ) {
        self.allowClassicScopeChanges = allowClassicScopeChanges
        self.id = id
        self.name = name
        self.region = region
        self.environmentID = environmentID
        self.clientID = clientID
        self.hostOverride = hostOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, region, environmentID, clientID, hostOverride, allowClassicScopeChanges
    }

    /// Tolerates tenants saved before `allowClassicScopeChanges` existed (they decode as off).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        region = try container.decode(Region.self, forKey: .region)
        environmentID = try container.decode(String.self, forKey: .environmentID)
        clientID = try container.decode(String.self, forKey: .clientID)
        hostOverride = try container.decodeIfPresent(String.self, forKey: .hostOverride)
        allowClassicScopeChanges = try container.decodeIfPresent(Bool.self, forKey: .allowClassicScopeChanges) ?? false
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
