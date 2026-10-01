import Foundation

/// In-memory Blueprints API for offline demo mode and tests.
///
/// It mimics the behaviour seen against the real service: on create it re-adds
/// `payloadVersion` / `payloadOrganization` / `payloadDisplayName` to each payload, and a
/// deployment moves through `PENDING → DEPLOYING → SUCCEEDED` over successive polls.
actor DemoBlueprintServer {
    private struct Stored {
        var detail: BlueprintDetail
        var pollsSinceDeploy: Int?
    }

    private var blueprints: [String: Stored] = [:]
    private let groupSizes: [String: Int]
    /// Polls needed before a deployment reports success.
    private let pollsToSucceed: Int
    private let failDeployments: Bool

    private(set) var createCount = 0
    private(set) var deployCount = 0

    init(groups: [PlatformGroup] = DemoFixtures.platformGroups, pollsToSucceed: Int = 3, failDeployments: Bool = false) {
        groupSizes = Dictionary(groups.map { ($0.id, $0.memberCount) }, uniquingKeysWith: { first, _ in first })
        self.pollsToSucceed = pollsToSucceed
        self.failDeployments = failDeployments
    }

    func seed(name: String) -> String {
        let id = UUID().uuidString.lowercased()
        blueprints[id] = Stored(detail: BlueprintDetail(
            id: id, name: name, description: nil, scope: BlueprintScope(deviceGroups: []),
            created: Date().formatted(.iso8601), updated: nil,
            deploymentState: DeploymentState(state: "NOT_DEPLOYED", lastDeployment: nil), steps: []
        ))
        return id
    }

    func list(named name: String) -> [BlueprintOverview] {
        blueprints.values.map(\.detail)
            .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .map { BlueprintOverview(id: $0.id, name: $0.name, description: $0.description, created: $0.created, updated: $0.updated, deploymentState: $0.deploymentState) }
    }

    func create(_ request: BlueprintRequest) throws -> BlueprintCreated {
        guard !request.deviceGroupIDs.isEmpty else {
            throw APIError.http(status: 400, method: "POST", path: "blueprints/v1/blueprints",
                                body: APIErrorBody(httpStatus: 400, traceId: "demo-trace", errors: [APIErrorDetail(code: "INVALID_FIELD", field: "scope.deviceGroups", description: "must not be empty")]),
                                rawBody: nil)
        }
        // Observed live: Wi-Fi SetupModes must not be empty.
        let payloads = request.configuration["payloadContent"]?.arrayValue ?? []
        for (index, payload) in payloads.enumerated() {
            if payload.objectValue?["payloadType"]?.stringValue == "com.apple.wifi.managed",
               payload.objectValue?["SetupModes"]?.arrayValue?.isEmpty == true {
                throw APIError.http(status: 400, method: "POST", path: "blueprints/v1/blueprints",
                                    body: APIErrorBody(httpStatus: 400, traceId: "demo-trace", errors: [APIErrorDetail(
                                        code: "SIZE", field: "steps[0].components[0].configuration.payloadContent[\(index)].setupModes",
                                        description: "size must be between 1 and 2147483647")]),
                                    rawBody: nil)
            }
        }
        createCount += 1
        let id = UUID().uuidString.lowercased()
        let now = Date().formatted(.iso8601)
        let steps = request.body.objectValue?["steps"]?.arrayValue ?? []
        let stepDetails: [BlueprintStepDetail] = steps.compactMap(\.objectValue).map { step in
            let components = (step["components"]?.arrayValue ?? []).compactMap(\.objectValue).map { component in
                BlueprintComponentDetail(
                    identifier: component["identifier"]?.stringValue ?? "",
                    configuration: component["configuration"].map(Self.canonicalise)
                )
            }
            return BlueprintStepDetail(name: step["name"]?.stringValue, components: components, activationPredicate: nil)
        }
        blueprints[id] = Stored(detail: BlueprintDetail(
            id: id, name: request.name, description: request.description,
            scope: BlueprintScope(deviceGroups: request.deviceGroupIDs),
            created: now, updated: now,
            deploymentState: DeploymentState(state: "NOT_DEPLOYED", lastDeployment: nil),
            steps: stepDetails
        ))
        return BlueprintCreated(id: id, href: "demo://blueprints/\(id)")
    }

    func detail(id: String) throws -> BlueprintDetail {
        guard var stored = blueprints[id] else { throw Self.notFound(id) }
        if let polls = stored.pollsSinceDeploy {
            let next = polls + 1
            stored.pollsSinceDeploy = next
            let started = stored.detail.deploymentState.lastDeployment?.started ?? Date().formatted(.iso8601)
            if failDeployments, next >= pollsToSucceed {
                stored.detail.deploymentState = DeploymentState(state: "NOT_DEPLOYED", lastDeployment: Deployment(started: started, state: "FAILED"))
            } else if next >= pollsToSucceed {
                stored.detail.deploymentState = DeploymentState(state: "DEPLOYED", lastDeployment: Deployment(started: started, state: "SUCCEEDED"))
            } else {
                stored.detail.deploymentState = DeploymentState(state: "NOT_DEPLOYED", lastDeployment: Deployment(started: started, state: next == 1 ? "PENDING" : "DEPLOYING"))
            }
            blueprints[id] = stored
        }
        return stored.detail
    }

    func deploy(id: String) throws {
        guard var stored = blueprints[id] else { throw Self.notFound(id) }
        guard !(stored.detail.steps.isEmpty) else {
            throw APIError.http(status: 409, method: "POST", path: "blueprints/v1/blueprints/\(id)/deploy",
                                body: APIErrorBody(httpStatus: 409, traceId: "demo-trace", errors: [APIErrorDetail(code: "NOT_VALID_FOR_DEPLOYMENT", description: "Blueprint has no steps")]),
                                rawBody: nil)
        }
        deployCount += 1
        stored.pollsSinceDeploy = 0
        stored.detail.deploymentState = DeploymentState(state: stored.detail.deploymentState.state,
                                                         lastDeployment: Deployment(started: Date().formatted(.iso8601), state: "PENDING"))
        blueprints[id] = stored
    }

    func report(id: String) throws -> BlueprintReport {
        guard let stored = blueprints[id] else { throw Self.notFound(id) }
        let devices = (stored.detail.scope?.deviceGroups ?? []).reduce(0) { $0 + (groupSizes[$1] ?? 0) }
        let succeeded = stored.detail.deploymentState.isDeployedSuccessfully ? devices : 0
        return BlueprintReport(succeeded: succeeded, failed: 0, pending: devices - succeeded)
    }

    /// Server-style canonicalisation of a `com.jamf.ddm-configuration-profile` configuration.
    private static func canonicalise(_ configuration: JSONValue) -> JSONValue {
        guard var object = configuration.objectValue else { return configuration }
        let payloads = object["payloadContent"]?.arrayValue ?? []
        object["payloadContent"] = .array(payloads.map { payload in
            guard var item = payload.objectValue else { return payload }
            // Observed live: these payload-level keys are not stored.
            item["PayloadDescription"] = nil
            item["PayloadEnabled"] = nil
            if item["payloadVersion"] == nil { item["payloadVersion"] = .integer(1) }
            if item["payloadOrganization"] == nil { item["payloadOrganization"] = .string("Jamf") }
            if item["payloadDisplayName"] == nil {
                item["payloadDisplayName"] = .string(item["payloadType"]?.stringValue ?? "Payload")
            }
            return .object(item)
        })
        return .object(object)
    }

    private static func notFound(_ id: String) -> APIError {
        .http(status: 404, method: "GET", path: "blueprints/v1/blueprints/\(id)",
              body: APIErrorBody(httpStatus: 404, traceId: "demo-trace", errors: [APIErrorDetail(code: "NOT_FOUND", description: "Blueprint doesn't exist")]),
              rawBody: nil)
    }
}

nonisolated struct DemoBlueprintsAPI: BlueprintsAPI {
    let server: DemoBlueprintServer

    func blueprints(named name: String) async throws -> [BlueprintOverview] { await server.list(named: name) }
    func create(_ request: BlueprintRequest) async throws -> BlueprintCreated { try await server.create(request) }
    func blueprint(id: String) async throws -> BlueprintDetail { try await server.detail(id: id) }
    func deploy(id: String) async throws { try await server.deploy(id: id) }
    func report(id: String) async throws -> BlueprintReport { try await server.report(id: id) }
}
