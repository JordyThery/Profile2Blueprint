import Foundation
import JTKit

/// A fully built Blueprint, ready for JTKit's `create`. `body` is the exact JSON
/// JTKit sends, so the preview shows what goes over the wire (a test checks it).
nonisolated struct BlueprintRequest: Hashable, Sendable {
    var name: String
    var description: String?
    var deviceGroupIDs: [String]
    var stepName: String
    var componentIdentifier: String
    var configuration: LosslessJSON.Object

    /// The single step: one configuration-profile component.
    var steps: [LosslessJSON] {
        let component = LosslessJSON.object(LosslessJSON.Object([
            "identifier": .string(componentIdentifier),
            "configuration": .object(configuration),
        ]))
        return [.object(LosslessJSON.Object([
            "name": .string(stepName),
            "activationPredicate": .null,
            "components": .array([component]),
        ]))]
    }

    /// The POST body as JTKit's `create` builds it: no description is left out.
    var body: LosslessJSON {
        var body = LosslessJSON.Object(["name": .string(name)])
        if let description, !description.isEmpty { body["description"] = .string(description) }
        body["scope"] = .object(LosslessJSON.Object(["deviceGroups": .array(deviceGroupIDs.map(LosslessJSON.string))]))
        body["steps"] = .array(steps)
        return .object(body)
    }
}

nonisolated extension JamfPlatform.Blueprints {
    /// Blueprints whose name equals `name` (case-insensitive), for the duplicate
    /// check. A Blueprint without a name is never a duplicate of anything.
    func blueprints(named name: String) async throws -> [JamfPlatform.BlueprintOverview] {
        let query = [
            URLQueryItem(name: "sort", value: "created:desc"),
            URLQueryItem(name: "search", value: String(name.prefix(1_000))),
        ]
        let named = try await client.allPages(Self.path, query: query) { json in
            JamfPlatform.BlueprintOverview(json: json).map { NamedOverview(overview: $0, sentName: json["name"]?.stringValue) }
        }
        return named.filter { $0.sentName?.caseInsensitiveCompare(name) == .orderedSame }.map(\.overview)
    }

    /// The device report, or none yet (JTKit reads a 404 as "no report").
    func reportIfAny(id: String) async -> JamfPlatform.BlueprintReport? {
        (try? await report(id: id)) ?? nil
    }
}

/// An overview with the name exactly as the server sent it (JTKit fills in a
/// placeholder for a missing one).
private nonisolated struct NamedOverview: Sendable {
    var overview: JamfPlatform.BlueprintOverview
    var sentName: String?
}

nonisolated extension JamfPlatform.DeviceGroup {
    /// The group's device count for display: "12 devices", or "unknown
    /// device count" when the server leaves it out (never shown as 0).
    var memberCountText: String {
        guard let memberCount else { return "unknown device count" }
        return "\(memberCount) device\(memberCount == 1 ? "" : "s")"
    }

    /// The bare count, or "unknown".
    var memberCountShort: String { memberCount.map(String.init) ?? "unknown" }
}

nonisolated extension Array where Element == JamfPlatform.DeviceGroup {
    /// Sum of the member counts the server gave; groups without one add nothing.
    var knownDeviceCount: Int { reduce(0) { $0 + ($1.memberCount ?? 0) } }

    /// Some group came without a member count, so `knownDeviceCount` is a lower bound.
    var hasUnknownDeviceCount: Bool { contains { $0.memberCount == nil } }
}

nonisolated extension JamfPlatform.DeploymentState {
    var isDeployedSuccessfully: Bool {
        state == .deployed && lastDeploymentState == "SUCCEEDED"
    }

    var displayText: String {
        guard let last = lastDeploymentState else { return state.displayName }
        return "\(state.displayName) · last deployment \(last.capitalized)"
    }
}

nonisolated extension JamfPlatform.DeploymentStatus {
    /// While the new deployment hasn't shown up yet, says so.
    var displayText: String {
        let main = blueprintState?.displayName ?? "Deployment requested"
        guard let job = jobState else { return "\(main) · waiting for the deployment to start" }
        return "\(main) · last deployment \(job.capitalized)"
    }
}
