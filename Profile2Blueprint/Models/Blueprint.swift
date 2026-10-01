import Foundation

/// A fully built `POST /v1/blueprints` body. `body` is the exact JSON that is sent.
nonisolated struct BlueprintRequest: Hashable, Sendable {
    var name: String
    var description: String?
    var deviceGroupIDs: [String]
    var stepName: String
    var componentIdentifier: String
    var configuration: JSONObject

    var body: JSONValue {
        let component = JSONValue.object(JSONObject([
            "identifier": .string(componentIdentifier),
            "configuration": .object(configuration),
        ]))
        let step = JSONValue.object(JSONObject([
            "name": .string(stepName),
            "activationPredicate": .null,
            "components": .array([component]),
        ]))
        return .object(JSONObject([
            "name": .string(name),
            "description": description.map(JSONValue.string) ?? .null,
            "scope": .object(JSONObject(["deviceGroups": .array(deviceGroupIDs.map(JSONValue.string))])),
            "steps": .array([step]),
        ]))
    }
}

/// `201` response of create.
nonisolated struct BlueprintCreated: Decodable, Hashable, Sendable {
    var id: String
    var href: String?
}

nonisolated struct Deployment: Decodable, Hashable, Sendable {
    var started: String?
    /// `PENDING`, `DEPLOYING`, `SUCCEEDED` or `FAILED` per the spec.
    var state: String
}

nonisolated struct DeploymentState: Decodable, Hashable, Sendable {
    /// `NOT_DEPLOYED`, `DEPLOYED` or `OUT_OF_DATE` per the spec.
    var state: String
    var lastDeployment: Deployment?

    var isDeployedSuccessfully: Bool {
        state == "DEPLOYED" && lastDeployment?.state == "SUCCEEDED"
    }

    var hasFailed: Bool {
        lastDeployment?.state == "FAILED"
    }

    var displayText: String {
        let main = state.replacingOccurrences(of: "_", with: " ").capitalized
        guard let last = lastDeployment?.state else { return main }
        return "\(main) · last deployment \(last.capitalized)"
    }
}

/// Entry of `GET /v1/blueprints`.
nonisolated struct BlueprintOverview: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var description: String?
    var created: String?
    var updated: String?
    var deploymentState: DeploymentState?
}

nonisolated struct BlueprintList: Decodable, Sendable {
    var results: [BlueprintOverview]
    var totalCount: Int?
}

nonisolated struct BlueprintScope: Decodable, Hashable, Sendable {
    var deviceGroups: [String]
}

nonisolated struct BlueprintComponentDetail: Decodable, Hashable, Sendable {
    var identifier: String
    var configuration: JSONValue?
}

nonisolated struct BlueprintStepDetail: Decodable, Hashable, Sendable {
    var name: String?
    var components: [BlueprintComponentDetail]
    var activationPredicate: String?
}

/// `GET /v1/blueprints/{id}`.
nonisolated struct BlueprintDetail: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var description: String?
    var scope: BlueprintScope?
    var created: String?
    var updated: String?
    var deploymentState: DeploymentState
    var steps: [BlueprintStepDetail]
}

/// `GET /v1/blueprints/{id}/report`.
nonisolated struct BlueprintReport: Decodable, Hashable, Sendable {
    var succeeded: Int
    var failed: Int
    var pending: Int

    var total: Int { succeeded + failed + pending }
}
