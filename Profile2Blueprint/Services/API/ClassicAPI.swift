import Foundation

/// Read-only access to Jamf Pro classic macOS configuration profiles.
/// There are deliberately no write methods.
nonisolated protocol ClassicAPI: Sendable {
    func listProfiles() async throws -> [ClassicProfileSummary]
    func profile(id: Int) async throws -> ClassicProfile
}

/// `GET /proclassic/osxconfigurationprofiles…` (permission `configuration-profiles:read`).
nonisolated struct LiveClassicAPI: ClassicAPI {
    let client: HTTPClient

    func listProfiles() async throws -> [ClassicProfileSummary] {
        let response = try await client.send(HTTPRequest(path: "proclassic/osxconfigurationprofiles", accept: "application/xml"))
        return try ClassicXMLParser.parseProfileList(response.data)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func profile(id: Int) async throws -> ClassicProfile {
        let response = try await client.send(HTTPRequest(path: "proclassic/osxconfigurationprofiles/id/\(id)", accept: "application/xml"))
        return try ClassicXMLParser.parseProfile(response.data)
    }
}
