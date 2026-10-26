import Foundation
import JTKit

/// The only Classic API write the app can make: replacing a profile's `<scope>`.
/// Exists only when "classic scope changes" are explicitly enabled for the tenant,
/// and `PlatformClient` additionally refuses any PUT whose body isn't scope-only.
nonisolated protocol ClassicScopeWriter: Sendable {
    func replaceScope(key: ProfileKey, body: Data) async throws
}

/// `PUT /proclassic/{resource}/id/{id}` (permission `configuration-profiles:update`).
///
/// The spec does not document the request body. This uses the Classic API's partial-XML
/// update convention (only the elements sent are changed), verified against a live tenant.
nonisolated struct LiveClassicScopeWriter: ClassicScopeWriter {
    let client: PlatformClient

    func replaceScope(key: ProfileKey, body: Data) async throws {
        _ = try await client.send(HTTPRequest(
            method: "PUT",
            path: "proclassic/\(key.platform.classicResource)/id/\(key.id)",
            body: body,
            accept: "application/xml",
            contentType: "application/xml"
        ))
    }
}
