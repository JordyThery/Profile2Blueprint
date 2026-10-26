import Foundation
import JTKit

/// Read-only access to Jamf Pro classic configuration profiles, macOS and mobile.
/// There are deliberately no write methods.
nonisolated protocol ClassicAPI: Sendable {
    func listProfiles(platform: ProfilePlatform) async throws -> [ClassicProfileSummary]
    func profile(key: ProfileKey) async throws -> ClassicProfile
}

/// `GET /proclassic/{resource}…` (permission `configuration-profiles:read`; on
/// Jamf Pro the platform's Read … Configuration Profiles privilege).
///
/// The list is asked for as JSON and unwrapped by JTKit; a single profile stays
/// XML, because its payload and its scope backup need Jamf Pro's exact XML.
nonisolated struct LiveClassicAPI: ClassicAPI {
    let client: JamfPlatform.Client

    func listProfiles(platform: ProfilePlatform) async throws -> [ClassicProfileSummary] {
        let response = try await client.send(
            HTTPRequest(path: "proclassic/\(platform.classicResource)", accept: "application/json"),
            privilege: platform.readPrivilege)
        return try ClassicProfileList.parse(response.data, platform: platform)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func profile(key: ProfileKey) async throws -> ClassicProfile {
        let response = try await client.send(
            HTTPRequest(path: JamfClassic.path(key.platform.classicResource, id: String(key.id)), accept: "application/xml"),
            privilege: key.platform.readPrivilege)
        return try ClassicXMLParser.parseProfile(response.data, platform: key.platform)
    }
}

/// A classic profile list asked for as JSON, `{"os_x_configuration_profiles":[{"id":1,"name":"…"}]}`.
nonisolated enum ClassicProfileList {
    static func parse(_ data: Data, platform: ProfilePlatform) throws -> [ClassicProfileSummary] {
        guard let json = try? LosslessJSON(data: data),
              json[platform.listRootElement] != nil,
              let items = JamfClassic.listItems(json) else {
            throw APIError.decoding("Expected a list of \(platform.listRootElement) from the Classic API.")
        }
        return items.compactMap { item in
            guard let id = item["id"]?.numberValue?.intValue ?? item["id"]?.stringValue.flatMap({ Int($0) }) else { return nil }
            return ClassicProfileSummary(platform: platform, profileID: id, name: item["name"]?.stringValue ?? "")
        }
    }
}
