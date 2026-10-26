import Foundation
import JTKit

/// The only Classic API write the app can make: replacing a profile's `<scope>`.
/// Exists only when "classic scope changes" are explicitly enabled for the tenant,
/// and JTKit's client additionally (`RequestPolicy`) refuses any PUT whose body isn't scope-only.
nonisolated protocol ClassicScopeWriter: Sendable {
    func replaceScope(key: ProfileKey, body: Data) async throws
}

/// `PUT /proclassic/{resource}/id/{id}` (permission `configuration-profiles:update`;
/// on Jamf Pro the platform's Update … Configuration Profiles privilege).
///
/// The spec does not document the request body. This uses the Classic API's partial-XML
/// update convention (only the elements sent are changed), verified against a live tenant.
nonisolated struct LiveClassicScopeWriter: ClassicScopeWriter {
    let client: JamfPlatform.Client

    func replaceScope(key: ProfileKey, body: Data) async throws {
        _ = try await client.send(HTTPRequest(
            method: "PUT",
            path: JamfClassic.path(key.platform.classicResource, id: String(key.id)),
            body: body,
            accept: "application/xml",
            contentType: "application/xml"
        ), privilege: key.platform.updatePrivilege)
    }
}
