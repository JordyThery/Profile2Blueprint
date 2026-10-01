import Foundation

nonisolated protocol DeviceGroupsAPI: Sendable {
    /// Returns every device group matching the RSQL `filter`, following all pages.
    func listGroups(filter: String?) async throws -> [PlatformGroup]
}

extension DeviceGroupsAPI {
    /// macOS migrations only target computer groups.
    nonisolated func computerGroups() async throws -> [PlatformGroup] {
        try await listGroups(filter: #"deviceType=="COMPUTER""#)
    }
}

/// `GET /device-groups/v1/device-groups` (permission `device-groups:read`).
nonisolated struct LiveDeviceGroupsAPI: DeviceGroupsAPI {
    let client: HTTPClient
    var pageSize = 100
    /// Hard stop so a misbehaving server can't loop forever.
    var maxPages = 1_000

    func listGroups(filter: String?) async throws -> [PlatformGroup] {
        var groups: [PlatformGroup] = []
        var page = 0

        while true {
            var query = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page-size", value: String(pageSize)),
                URLQueryItem(name: "sort", value: "name"),
            ]
            if let filter, !filter.isEmpty {
                query.append(URLQueryItem(name: "filter", value: filter))
            }

            let result = try await client.get(Page<PlatformGroup>.self, path: "device-groups/v1/device-groups", query: query)
            groups.append(contentsOf: result.results)

            guard result.hasNext, !result.results.isEmpty else { break }
            page += 1
            if page >= maxPages { throw APIError.paginationLimitExceeded }
        }
        return groups
    }
}
