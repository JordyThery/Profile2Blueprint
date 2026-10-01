import Foundation

/// The only Classic API write the app can make: replacing a profile's `<scope>`.
/// Exists only when "classic scope changes" are explicitly enabled for the tenant,
/// and `HTTPClient` additionally refuses any PUT whose body isn't scope-only.
nonisolated protocol ClassicScopeWriter: Sendable {
    func replaceScope(profileID: Int, body: Data) async throws
}

/// `PUT /proclassic/osxconfigurationprofiles/id/{id}` (permission `configuration-profiles:update`).
///
/// Unverified against a live tenant: the spec doesn't document the body. This follows the
/// Classic API convention of partial XML updates (only the elements sent are changed).
nonisolated struct LiveClassicScopeWriter: ClassicScopeWriter {
    let client: HTTPClient

    func replaceScope(profileID: Int, body: Data) async throws {
        _ = try await client.send(HTTPRequest(
            method: "PUT",
            path: "proclassic/osxconfigurationprofiles/id/\(profileID)",
            body: body,
            accept: "application/xml",
            contentType: "application/xml"
        ))
    }
}
