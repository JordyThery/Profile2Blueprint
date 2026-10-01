import Foundation

/// The subset of the Blueprints API the app uses. PATCH, DELETE and undeploy are
/// intentionally absent.
nonisolated protocol BlueprintsAPI: Sendable {
    /// Blueprints whose name equals `name` (case-insensitive), for the duplicate check.
    func blueprints(named name: String) async throws -> [BlueprintOverview]
    func create(_ request: BlueprintRequest) async throws -> BlueprintCreated
    func blueprint(id: String) async throws -> BlueprintDetail
    func deploy(id: String) async throws
    func report(id: String) async throws -> BlueprintReport
}

/// `/blueprints/v1/…` (permissions `blueprints:read`, `blueprints:create`, `blueprints:deploy`).
nonisolated struct LiveBlueprintsAPI: BlueprintsAPI {
    let client: HTTPClient
    var pageSize = 100
    var maxPages = 50

    func blueprints(named name: String) async throws -> [BlueprintOverview] {
        // The list envelope is `{results, totalCount}` with no `hasNext`, so page
        // until a short page or `totalCount` is reached.
        var all: [BlueprintOverview] = []
        for page in 0..<maxPages {
            let list = try await client.get(BlueprintList.self, path: "blueprints/v1/blueprints", query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page-size", value: String(pageSize)),
                URLQueryItem(name: "search", value: String(name.prefix(1_000))),
            ])
            all += list.results
            if list.results.count < pageSize { break }
            if let total = list.totalCount, all.count >= total { break }
        }
        return all.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func create(_ request: BlueprintRequest) async throws -> BlueprintCreated {
        let response = try await client.send(HTTPRequest(
            method: "POST",
            path: "blueprints/v1/blueprints",
            body: request.body.serializedData(),
            contentType: "application/json"
        ))
        return try client.decode(BlueprintCreated.self, from: response)
    }

    func blueprint(id: String) async throws -> BlueprintDetail {
        try await client.get(BlueprintDetail.self, path: "blueprints/v1/blueprints/\(Self.escape(id))")
    }

    func deploy(id: String) async throws {
        _ = try await client.send(HTTPRequest(method: "POST", path: "blueprints/v1/blueprints/\(Self.escape(id))/deploy"))
    }

    func report(id: String) async throws -> BlueprintReport {
        try await client.get(BlueprintReport.self, path: "blueprints/v1/blueprints/\(Self.escape(id))/report")
    }

    /// IDs are UUIDs; anything else is percent-encoded so it can't alter the path.
    private static func escape(_ id: String) -> String {
        FormEncoding.encode(id)
    }
}
