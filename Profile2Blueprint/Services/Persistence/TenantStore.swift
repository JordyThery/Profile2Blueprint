import Foundation
import JTKit
import OSLog

/// Non-secret tenant configuration persisted between launches.
nonisolated struct TenantConfiguration: Codable, Sendable, Equatable {
    var tenants: [Tenant] = []
    var currentTenantID: UUID?
}

/// `tenants.json` in the app's Application Support folder: the tenants and the
/// current tenant in one object. JTKit's `ConnectionStore` reads and writes the
/// tenants through it; the current tenant is written with
/// `saveCurrentTenantID(_:)`. Each keeps the other's part, and the file keeps
/// its format byte for byte. Client secrets are never written here; they go
/// to the Keychain.
///
/// As JTKit's own storage does: the first write makes `tenants.json.backup`
/// once, and a file that can't be read is copied to
/// `tenants.json.unreadable-<date and time>` and never written over.
final class TenantStore: ConnectionStorage {
    let fileURL: URL

    /// The current tenant as last read or written.
    private(set) var currentTenantID: UUID?
    /// Called after the tenants were written, with the list as it was and as
    /// it is now.
    var didSaveTenants: ((_ old: [Tenant], _ new: [Tenant]) -> Void)?

    private var tenants: [Tenant] = []
    /// False after a failed read, until a read works: nothing is written then.
    private var isReadable = true

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func appDefault() -> TenantStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return TenantStore(fileURL: base.appending(path: "Profile2Blueprint/tenants.json"))
    }

    var backupURL: URL { fileURL.appendingPathExtension("backup") }

    // MARK: ConnectionStorage

    func load() throws -> [Tenant] {
        do {
            let configuration: TenantConfiguration
            if FileManager.default.fileExists(atPath: fileURL.path) {
                configuration = try JSONDecoder().decode(TenantConfiguration.self, from: Data(contentsOf: fileURL))
            } else {
                configuration = TenantConfiguration()
            }
            tenants = configuration.tenants
            currentTenantID = configuration.currentTenantID
            isReadable = true
            return tenants
        } catch {
            isReadable = false
            Log.app.error("Could not read tenants.json: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func save(_ records: [Tenant]) throws {
        let old = tenants
        try write(TenantConfiguration(tenants: records, currentTenantID: currentTenantID))
        tenants = records
        didSaveTenants?(old, records)
    }

    func backUpOnce() throws {
        let files = FileManager.default
        guard files.fileExists(atPath: fileURL.path), !files.fileExists(atPath: backupURL.path) else { return }
        try files.copyItem(at: fileURL, to: backupURL)
    }

    func keepUnreadableCopy() -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let copy = fileURL.appendingPathExtension("unreadable-\(formatter.string(from: .now))")
        do {
            try FileManager.default.copyItem(at: fileURL, to: copy)
            return copy.path
        } catch {
            return nil
        }
    }

    // MARK: Current tenant

    /// Writes the current tenant, keeping the tenants as they are. Refused
    /// while the file can't be read.
    func saveCurrentTenantID(_ id: UUID?) throws {
        guard id != currentTenantID else { return }
        guard isReadable else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "The saved tenants couldn’t be read, so the current tenant isn’t saved until this is fixed.",
            ])
        }
        try backUpOnce()
        try write(TenantConfiguration(tenants: tenants, currentTenantID: id))
        currentTenantID = id
    }

    private func write(_ configuration: TenantConfiguration) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }
}
