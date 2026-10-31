import Foundation
import JTKit

/// Whether Classic API writes are allowed. Off unless the user explicitly enables
/// "classic scope changes" for the tenant; even then only scope-only PUTs pass.
nonisolated enum ClassicWritePolicy: Sendable, Hashable {
    case denied
    case scopeOnly
}

/// Profile2Blueprint's list of the requests it may send at all, checked by
/// JTKit's client before anything reaches the network.
nonisolated enum RequestPolicy {
    /// Allowed:
    /// - any GET;
    /// - POST to create a blueprint or deploy one;
    /// - only with `.scopeOnly`: PUT to a classic profile (either platform's resource)
    ///   whose XML body contains nothing but `<scope>`.
    /// Everything else (PATCH, DELETE, undeploy, device-group writes, payload edits) is refused.
    static func isPermitted(_ request: HTTPRequest, classicWrites: ClassicWritePolicy = .denied) -> Bool {
        let path = request.path.hasPrefix("/") ? String(request.path.dropFirst()) : request.path
        switch request.method.uppercased() {
        case "GET":
            return true
        case "POST":
            let parts = path.split(separator: "/").map(String.init)
            // blueprints/v1/blueprints  or  blueprints/v1/blueprints/{id}/deploy
            guard parts.count >= 3, parts[0] == "blueprints", parts[2] == "blueprints" else { return false }
            return parts.count == 3 || (parts.count == 5 && parts[4] == "deploy")
        case "PUT":
            guard classicWrites == .scopeOnly,
                  path.wholeMatch(of: /proclassic\/(?:osxconfigurationprofiles|mobiledeviceconfigurationprofiles)\/id\/\d+/) != nil,
                  let body = request.body else { return false }
            return isScopeOnlyProfileXML(body)
        default:
            return false
        }
    }

    /// A classic profile root (either platform) with exactly one child element, `<scope>`.
    static func isScopeOnlyProfileXML(_ data: Data) -> Bool {
        guard let document = try? XMLDocument(data: data, options: []),
              let root = document.rootElement(), let name = root.name,
              ProfilePlatform.allCases.contains(where: { $0.profileRootElement == name }) else { return false }
        let children = (root.children ?? []).compactMap { $0 as? XMLElement }
        return children.count == 1 && children[0].name == "scope"
    }

    /// The app's hint for a refused request: what it does send.
    static func hints(for error: JamfPlatform.APIError) -> [String] {
        guard case let .refused(method, _) = error.kind else { return [] }
        return ["This app only reads, creates and deploys blueprints"
            + (method.uppercased() == "PUT" ? ", and changes classic scope only when that is explicitly enabled." : ".")]
    }
}
