import Foundation
import JTKit

/// Read-only access to Jamf Pro classic configuration profiles, macOS and mobile.
/// There are deliberately no write methods.
nonisolated protocol ClassicAPI: Sendable {
    func listProfiles(platform: ProfilePlatform) async throws -> [ClassicProfileSummary]
    func profile(key: ProfileKey) async throws -> ClassicProfile
}

/// `GET /proclassic/{resource}…` (permission `configuration-profiles:read`).
nonisolated struct LiveClassicAPI: ClassicAPI {
    let client: PlatformClient

    func listProfiles(platform: ProfilePlatform) async throws -> [ClassicProfileSummary] {
        let response = try await client.send(HTTPRequest(path: "proclassic/\(platform.classicResource)", accept: "application/xml"))
        return try ClassicXMLParser.parseProfileList(response.data, platform: platform)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func profile(key: ProfileKey) async throws -> ClassicProfile {
        let response = try await client.send(HTTPRequest(
            path: "proclassic/\(key.platform.classicResource)/id/\(key.id)", accept: "application/xml"))
        return try ClassicXMLParser.parseProfile(response.data, platform: key.platform)
    }
}
