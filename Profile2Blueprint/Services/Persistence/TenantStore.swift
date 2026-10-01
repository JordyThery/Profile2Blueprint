import Foundation
import OSLog

/// Non-secret tenant configuration persisted between launches.
nonisolated struct TenantConfiguration: Codable, Sendable, Equatable {
    var tenants: [Tenant] = []
    var currentTenantID: UUID?
}

/// Reads and writes `tenants.json` in the app's Application Support folder.
/// Client secrets are never written here; they go to the Keychain.
nonisolated struct TenantStore: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func appDefault() -> TenantStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return TenantStore(fileURL: base.appending(path: "Profile2Blueprint/tenants.json"))
    }

    func load() -> TenantConfiguration {
        guard let data = try? Data(contentsOf: fileURL) else { return TenantConfiguration() }
        do {
            return try JSONDecoder().decode(TenantConfiguration.self, from: data)
        } catch {
            Log.app.error("Could not read tenants.json: \(error.localizedDescription, privacy: .public)")
            return TenantConfiguration()
        }
    }

    func save(_ configuration: TenantConfiguration) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }
}
