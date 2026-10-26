import Foundation
import JTKit

/// In-memory Jamf Platform API for offline demo mode and tests: Blueprints and
/// device groups. It answers the requests JTKit's client sends (through
/// `DemoURLProtocol`, never the network), so demo mode runs the same code as a
/// real tenant and gets JTKit's models back.
///
/// It mimics the behaviour seen against the real service: on create it re-adds
/// `payloadVersion` / `payloadOrganization` / `payloadDisplayName` to each payload, and a
/// deployment moves through `PENDING → DEPLOYING → SUCCEEDED` over successive polls.
nonisolated final class DemoBlueprintServer: @unchecked Sendable {
    /// What the server answers to one request.
    struct Response: Sendable {
        var status: Int
        var body: Data
    }

    private struct Stored {
        var blueprint: LosslessJSON.Object
        var pollsSinceDeploy: Int?
    }

    private let lock = NSLock()
    private var blueprints: [String: Stored] = [:]
    private var lastStarted = Date.distantPast
    private var createCountValue = 0
    private var deployCountValue = 0
    private let groups: [JamfPlatform.DeviceGroup]
    /// Polls needed before a deployment reports success.
    private let pollsToSucceed: Int
    private let failDeployments: Bool

    var createCount: Int { lock.withLock { createCountValue } }
    var deployCount: Int { lock.withLock { deployCountValue } }

    init(groups: [JamfPlatform.DeviceGroup] = DemoFixtures.platformGroups, pollsToSucceed: Int = 3, failDeployments: Bool = false) {
        self.groups = groups
        self.pollsToSucceed = pollsToSucceed
        self.failDeployments = failDeployments
    }

    /// Adds an empty, undeployed Blueprint, e.g. a same-named one for the duplicate check.
    func seed(name: String) -> String {
        let id = UUID().uuidString.lowercased()
        lock.withLock {
            blueprints[id] = Stored(blueprint: Self.blueprint(
                id: id, name: name, description: nil, deviceGroups: [], created: Self.now(), updated: nil,
                state: "NOT_DEPLOYED", steps: []))
        }
        return id
    }

    // MARK: Requests

    /// Answers one request. `path` may start with a slash.
    func handle(method: String, path: String, query: [String: String], body: Data) -> Response {
        let parts = path.split(separator: "/").map(String.init)
        let method = method.uppercased()
        return lock.withLock {
            if method == "GET", parts == ["device-groups", "v1", "device-groups"] {
                return groupPage(query: query)
            }
            guard parts.count >= 3, Array(parts[0...2]) == ["blueprints", "v1", "blueprints"] else {
                return Self.error(404, "NOT_FOUND", "No such resource in demo mode.")
            }
            switch (method, parts.count) {
            case ("GET", 3):
                return list(search: query["search"] ?? "")
            case ("POST", 3):
                return create(body)
            case ("GET", 4):
                return detail(id: parts[3])
            case ("POST", 5) where parts[4] == "deploy":
                return deploy(id: parts[3])
            case ("GET", 5) where parts[4] == "report":
                return report(id: parts[3])
            default:
                return Self.error(404, "NOT_FOUND", "No such resource in demo mode.")
            }
        }
    }

    private func groupPage(query: [String: String]) -> Response {
        let page = query["page"].flatMap(Int.init) ?? 0
        let size = max(query["page-size"].flatMap(Int.init) ?? 100, 1)
        let slice = groups.dropFirst(page * size).prefix(size)
        let results: [LosslessJSON] = slice.map { group in
            var object = LosslessJSON.Object([
                "id": .string(group.id),
                "name": .string(group.name),
                "description": group.description.map(LosslessJSON.string) ?? .null,
                "deviceType": .string(Self.raw(group.deviceType)),
                "groupType": .string(Self.raw(group.groupType)),
            ])
            if let count = group.memberCount { object["memberCount"] = .number(.init(count)) }
            return .object(object)
        }
        return Self.json(200, .object(LosslessJSON.Object([
            "totalCount": .number(.init(groups.count)),
            "hasNext": .bool((page + 1) * size < groups.count),
            "results": .array(results),
        ])))
    }

    private func list(search: String) -> Response {
        let matches = blueprints.values.map(\.blueprint).filter { blueprint in
            guard !search.isEmpty else { return true }
            return blueprint["name"]?.stringValue?.localizedCaseInsensitiveContains(search) ?? false
        }
        let overviews: [LosslessJSON] = matches.map { blueprint in
            var overview = blueprint
            overview["steps"] = nil
            return .object(overview)
        }
        return Self.json(200, .object(LosslessJSON.Object([
            "totalCount": .number(.init(overviews.count)),
            "results": .array(overviews),
        ])))
    }

    private func create(_ data: Data) -> Response {
        guard let request = try? LosslessJSON(data: data) else {
            return Self.error(400, "INVALID_FIELD", "The body is not valid JSON.")
        }
        let groups = request["scope"]?["deviceGroups"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !groups.isEmpty else {
            return Self.error(400, "INVALID_FIELD", "must not be empty", field: "scope.deviceGroups")
        }
        let steps = request["steps"]?.arrayValue ?? []
        // Observed live: Wi-Fi SetupModes must not be empty.
        for step in steps {
            for component in step["components"]?.arrayValue ?? [] {
                for (index, payload) in (component["configuration"]?["payloadContent"]?.arrayValue ?? []).enumerated()
                where payload["payloadType"]?.stringValue == "com.apple.wifi.managed" && payload["SetupModes"]?.arrayValue?.isEmpty == true {
                    return Self.error(400, "SIZE", "size must be between 1 and 2147483647",
                                      field: "steps[0].components[0].configuration.payloadContent[\(index)].setupModes")
                }
            }
        }
        createCountValue += 1
        let id = UUID().uuidString.lowercased()
        let now = Self.now()
        let storedSteps: [LosslessJSON] = steps.map { step in
            guard var object = step.objectValue else { return step }
            object["components"] = .array((step["components"]?.arrayValue ?? []).map { component in
                guard var item = component.objectValue else { return component }
                if let configuration = item["configuration"] { item["configuration"] = Self.canonicalise(configuration) }
                return .object(item)
            })
            return .object(object)
        }
        blueprints[id] = Stored(blueprint: Self.blueprint(
            id: id, name: request["name"]?.stringValue ?? "", description: request["description"]?.stringValue,
            deviceGroups: groups, created: now, updated: now, state: "NOT_DEPLOYED", steps: storedSteps))
        return Self.json(201, .object(LosslessJSON.Object([
            "id": .string(id),
            "href": .string("demo://blueprints/\(id)"),
        ])))
    }

    private func detail(id: String) -> Response {
        guard var stored = blueprints[id] else { return Self.notFound() }
        if let polls = stored.pollsSinceDeploy {
            let next = polls + 1
            stored.pollsSinceDeploy = next
            let started = stored.blueprint["deploymentState"]?["lastDeployment"]?["started"]?.stringValue ?? Self.now()
            if failDeployments, next >= pollsToSucceed {
                Self.setDeployment(&stored.blueprint, state: "NOT_DEPLOYED", started: started, job: "FAILED")
            } else if next >= pollsToSucceed {
                Self.setDeployment(&stored.blueprint, state: "DEPLOYED", started: started, job: "SUCCEEDED")
            } else {
                Self.setDeployment(&stored.blueprint, state: "NOT_DEPLOYED", started: started, job: next == 1 ? "PENDING" : "DEPLOYING")
            }
            blueprints[id] = stored
        }
        return Self.json(200, .object(stored.blueprint))
    }

    private func deploy(id: String) -> Response {
        guard var stored = blueprints[id] else { return Self.notFound() }
        guard !(stored.blueprint["steps"]?.arrayValue ?? []).isEmpty else {
            return Self.error(409, "NOT_VALID_FOR_DEPLOYMENT", "Blueprint has no steps")
        }
        deployCountValue += 1
        stored.pollsSinceDeploy = 0
        // Each deployment gets its own start time, so a watch can tell it from the previous one.
        let started = max(Date(), lastStarted.addingTimeInterval(0.001))
        lastStarted = started
        let state = stored.blueprint["deploymentState"]?["state"]?.stringValue ?? "NOT_DEPLOYED"
        Self.setDeployment(&stored.blueprint, state: state,
                           started: started.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)),
                           job: "PENDING")
        blueprints[id] = stored
        return Response(status: 202, body: Data())
    }

    private func report(id: String) -> Response {
        guard let stored = blueprints[id] else { return Self.notFound() }
        let sizes = Dictionary(groups.map { ($0.id, $0.members) }, uniquingKeysWith: { first, _ in first })
        let scope = stored.blueprint["scope"]?["deviceGroups"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let devices = scope.reduce(0) { $0 + (sizes[$1] ?? 0) }
        let deployed = JamfPlatform.DeploymentState(json: stored.blueprint["deploymentState"])?.isDeployedSuccessfully ?? false
        let succeeded = deployed ? devices : 0
        return Self.json(200, .object(LosslessJSON.Object([
            "succeeded": .number(.init(succeeded)),
            "failed": .number(.init(0)),
            "pending": .number(.init(devices - succeeded)),
        ])))
    }

    // MARK: Building answers

    private static func blueprint(
        id: String, name: String, description: String?, deviceGroups: [String], created: String, updated: String?,
        state: String, steps: [LosslessJSON]
    ) -> LosslessJSON.Object {
        LosslessJSON.Object([
            "id": .string(id),
            "name": .string(name),
            "description": description.map(LosslessJSON.string) ?? .null,
            "scope": .object(LosslessJSON.Object(["deviceGroups": .array(deviceGroups.map(LosslessJSON.string))])),
            "created": .string(created),
            "updated": updated.map(LosslessJSON.string) ?? .null,
            "deploymentState": .object(LosslessJSON.Object(["state": .string(state)])),
            "steps": .array(steps),
        ])
    }

    private static func setDeployment(_ blueprint: inout LosslessJSON.Object, state: String, started: String, job: String) {
        blueprint["deploymentState"] = .object(LosslessJSON.Object([
            "state": .string(state),
            "lastDeployment": .object(LosslessJSON.Object(["started": .string(started), "state": .string(job)])),
        ]))
    }

    /// Server-style canonicalisation of a `com.jamf.ddm-configuration-profile` configuration.
    private static func canonicalise(_ configuration: LosslessJSON) -> LosslessJSON {
        guard var object = configuration.objectValue else { return configuration }
        let payloads = object["payloadContent"]?.arrayValue ?? []
        object["payloadContent"] = .array(payloads.map { payload in
            guard var item = payload.objectValue else { return payload }
            // Observed live: these payload-level keys are not stored.
            item["PayloadDescription"] = nil
            item["PayloadEnabled"] = nil
            // Observed live (via jamf-cli's wire probes): the API overwrites each
            // payload's UUID with its identifier.
            if let identifier = item["payloadIdentifier"] { item["payloadUUID"] = identifier }
            if item["payloadVersion"] == nil { item["payloadVersion"] = .integer(1) }
            if item["payloadOrganization"] == nil { item["payloadOrganization"] = .string("Jamf") }
            if item["payloadDisplayName"] == nil {
                item["payloadDisplayName"] = .string(item["payloadType"]?.stringValue ?? "Payload")
            }
            return .object(item)
        })
        return .object(object)
    }

    private static func json(_ status: Int, _ value: LosslessJSON) -> Response {
        Response(status: status, body: value.serialized())
    }

    /// An error in the gateway's shape, so JTKit reads it as from a real tenant.
    private static func error(_ status: Int, _ code: String, _ description: String, field: String? = nil) -> Response {
        var item = LosslessJSON.Object(["code": .string(code)])
        if let field { item["field"] = .string(field) }
        item["description"] = .string(description)
        return json(status, .object(LosslessJSON.Object([
            "httpStatus": .number(.init(status)),
            "traceId": .string("demo-trace"),
            "errors": .array([.object(item)]),
        ])))
    }

    private static func notFound() -> Response {
        error(404, "NOT_FOUND", "Blueprint doesn't exist")
    }

    private static func now() -> String {
        Date().formatted(.iso8601)
    }

    private static func raw(_ type: JamfPlatform.DeviceGroup.DeviceType) -> String {
        switch type {
        case .computer: "COMPUTER"
        case .mobile: "MOBILE"
        case let .other(raw): raw
        }
    }

    private static func raw(_ type: JamfPlatform.DeviceGroup.GroupType) -> String {
        switch type {
        case .smart: "SMART"
        case .static: "STATIC"
        case let .other(raw): raw
        }
    }
}

// MARK: - Client

nonisolated extension DemoBlueprintServer {
    /// The demo's Environment ID.
    static let environmentID = "00000000-0000-4000-8000-00000000de70"

    /// A JTKit client whose requests this server answers, inside the app. With
    /// a log, its requests show in the activity log as "Offline demo".
    func client(log: ActivityLog?) -> JamfPlatform.Client {
        var components = URLComponents()
        components.scheme = "https"
        components.host = DemoURLProtocol.register(self)
        let recorder = RequestRecorder(session: DemoURLProtocol.session, log: log,
                                       service: ConnectionService.jamfPlatform.displayName, connection: "Offline demo")
        do {
            return try JamfPlatform.Client(
                baseURL: components.url ?? URL(filePath: "/"),
                scope: .environment(Self.environmentID),
                tokens: DemoTokens(),
                recorder: recorder,
                permits: { RequestPolicy.isPermitted($0) },
                hints: RequestPolicy.hints(for:)
            )
        } catch {
            preconditionFailure("The demo client's fixed settings are always valid: \(error)")
        }
    }
}

/// Demo mode signs in with nothing.
private nonisolated struct DemoTokens: BearerTokenSource {
    func token() async throws -> String { "demo-token" }
    func forgetToken() async {}
}

/// Hands the demo client's requests to its `DemoBlueprintServer`, by host
/// (`<id>.demo.invalid`, a name that can never reach the network).
nonisolated final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: DemoBlueprintServer] = [:]

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    /// Registers a server and returns the host its client uses.
    static func register(_ server: DemoBlueprintServer) -> String {
        let host = "\(UUID().uuidString.lowercased()).demo.invalid"
        lock.withLock { servers[host] = server }
        return host
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.hasSuffix(".demo.invalid") ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              let server = Self.lock.withLock({ Self.servers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let answer = server.handle(method: request.httpMethod ?? "GET", path: url.path(),
                                   query: query, body: request.httpBody ?? Self.read(request.httpBodyStream))
        if let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
