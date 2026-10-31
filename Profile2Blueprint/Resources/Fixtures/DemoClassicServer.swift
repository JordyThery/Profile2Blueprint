import Foundation
import JTKit

/// Demo mode's Classic API: the Contoso profiles of `DemoFixtures`, behind
/// JTKit's demo Jamf Platform server (`proclassic/…`, as through the gateway).
/// The app reads and writes them with its real `LiveClassicAPI` and
/// `LiveClassicScopeWriter`, through JTKit's client and the app's allow-list.
///
/// It answers like Jamf Pro: lists as JSON, a single profile as XML, and a
/// PUT as a partial update that replaces only `<scope>`. Anything else is
/// refused, so unscope and restore can be tried and nothing more.
nonisolated final class DemoClassicServer: DemoServer, @unchecked Sendable {
    private let lock = NSLock()
    private var profilesXML: [ProfileKey: String] = DemoFixtures.profilesByKey
    private var writes: [(key: ProfileKey, body: String)] = []

    /// The scope writes received, oldest first.
    var scopeWrites: [(key: ProfileKey, body: String)] { lock.withLock { writes } }

    /// The profile as the server holds it now.
    func profileXML(key: ProfileKey) -> String? { lock.withLock { profilesXML[key] } }

    func respond(to request: DemoRequest) -> DemoResponse {
        // proclassic/{resource} or proclassic/{resource}/id/{id}
        let parts = request.pathSegments
        guard parts.count >= 2, parts[0] == "proclassic",
              let platform = ProfilePlatform.allCases.first(where: { $0.classicResource == parts[1] }) else {
            return Self.notFound()
        }
        switch (request.method, parts.count) {
        case ("GET", 2):
            return DemoResponse(status: 200, body: Data(DemoFixtures.profileListJSON(platform: platform).utf8))
        case ("GET", 4) where parts[2] == "id":
            guard let id = Int(parts[3]), let xml = profileXML(key: ProfileKey(platform: platform, id: id)) else {
                return Self.notFound()
            }
            return Self.xml(200, xml)
        case ("PUT", 4) where parts[2] == "id":
            guard let id = Int(parts[3]) else { return Self.notFound() }
            return putScope(key: ProfileKey(platform: platform, id: id), body: request.body)
        default:
            return Self.notFound()
        }
    }

    /// A Classic partial update: replaces only `<scope>`.
    private func putScope(key: ProfileKey, body: Data) -> DemoResponse {
        guard RequestPolicy.isScopeOnlyProfileXML(body) else {
            return Self.errorPage(400, "Bad Request: only the scope can be changed in demo mode")
        }
        return lock.withLock {
            guard let xml = profilesXML[key],
                  let document = try? XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace]),
                  let root = document.rootElement(),
                  let newScope = try? XMLDocument(data: body).rootElement()?.elements(forName: "scope").first?.copy() as? XMLElement else {
                return Self.notFound()
            }
            if let old = root.elements(forName: "scope").first { root.removeChild(at: old.index) }
            root.addChild(newScope)
            profilesXML[key] = document.xmlString
            writes.append((key, String(decoding: body, as: UTF8.self)))
            return Self.xml(201, "<\(key.platform.profileRootElement)><id>\(key.id)</id></\(key.platform.profileRootElement)>")
        }
    }

    private static func xml(_ status: Int, _ text: String) -> DemoResponse {
        DemoResponse(status: status, headers: ["Content-Type": "application/xml"], body: Data(text.utf8))
    }

    /// Jamf Pro's Classic errors are HTML pages.
    private static func errorPage(_ status: Int, _ message: String) -> DemoResponse {
        DemoResponse(status: status, headers: ["Content-Type": "text/html"],
                     body: Data("<html><body><p>\(message)</p></body></html>".utf8))
    }

    private static func notFound() -> DemoResponse {
        errorPage(404, "The server has not found anything matching the request URI")
    }
}

nonisolated extension MigrationEnvironment {
    /// Demo mode's name, in history, scope backups and the activity log: JTKit's
    /// demo connection, "Contoso (Demo)".
    static let demoDisplayName = Connection.demoJamfPlatform.name

    /// Another name a demo backup can carry. A backup under it is never
    /// matched by name on a real tenant.
    static let earlierDemoDisplayName = "Offline demo"

    /// Demo mode: JTKit's demo Jamf Platform connection, with the app's
    /// Contoso groups and Classic profiles added to its server, read and
    /// written by the same code as a tenant. Classic scope changes are
    /// enabled here (in memory only) so the full flow, including unscope and
    /// restore, can be tried without a tenant.
    ///
    /// The app passes its `DemoMode`'s server and session; tests and previews
    /// get a server and a private demo network of their own.
    ///
    /// The Environment ID stays empty, so a demo scope backup is matched by
    /// name and never on a real tenant (`ScopeBackup.belongs(to:)`).
    static func demo(
        log: ActivityLog? = nil,
        server: DemoJamfPlatformServer = DemoJamfPlatformServer(),
        classicServer: DemoClassicServer = DemoClassicServer(),
        session: URLSession? = nil,
        classicScopeChanges: Bool = true
    ) -> MigrationEnvironment {
        let client = demoClient(log: log, server: server, classicServer: classicServer, session: session)
        return MigrationEnvironment(
            displayName: demoDisplayName,
            isDemo: true,
            environmentID: nil,
            classic: LiveClassicAPI(client: client),
            platform: client,
            classicScopeWriter: classicScopeChanges ? LiveClassicScopeWriter(client: client) : nil
        )
    }

    /// JTKit's client for the demo connection, with the app's allow-list
    /// (scope-only Classic writes allowed), on the demo network. The app's
    /// groups and Classic profiles are added to `server` first.
    static func demoClient(
        log: ActivityLog? = nil,
        server: DemoJamfPlatformServer = DemoJamfPlatformServer(),
        classicServer: DemoClassicServer = DemoClassicServer(),
        session: URLSession? = nil
    ) -> JamfPlatform.Client {
        server.add(groups: DemoFixtures.addedPlatformGroups)
        server.route("proclassic", to: classicServer)
        let connection = Connection.demoJamfPlatform
        let session = session ?? DemoNetwork(servers: [DemoSamples.platformHost: server]).session
        let recorder = RequestRecorder(session: session, log: log,
                                       service: ConnectionService.jamfPlatform.displayName, connection: connection.name)
        do {
            return try JamfPlatform.Client(
                connection: connection,
                secret: { DemoSecretStore().secret(for: connection.id.uuidString) ?? "" },
                recorder: recorder,
                permits: { RequestPolicy.isPermitted($0, classicWrites: .scopeOnly) },
                hints: RequestPolicy.hints(for:)
            )
        } catch {
            preconditionFailure("JTKit’s demo connection is always valid: \(error)")
        }
    }
}
