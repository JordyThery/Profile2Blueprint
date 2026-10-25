import Foundation
import JTKit
import OSLog

extension KeychainSecretStore {
    /// The tenants' OAuth client secrets, where they have always been: service
    /// `be.jordythery.profile2blueprint.oauth-client-secret`, account = the
    /// tenant's id, readable after first unlock.
    nonisolated static func profile2Blueprint() -> KeychainSecretStore {
        KeychainSecretStore(service: "be.jordythery.profile2blueprint.oauth-client-secret",
                            accessibility: .afterFirstUnlock,
                            label: "Profile2Blueprint OAuth client secret",
                            log: { Log.app.error("\($0, privacy: .public)") })
    }
}

/// Passes everything to the app's secret store and notes which accounts got a
/// new secret, so the activity log can say so after a save. The values are
/// never kept.
nonisolated final class RecordingSecretStore: SecretStore, @unchecked Sendable {
    private let base: any SecretStore
    private let lock = NSLock()
    private var written = Set<String>()

    init(_ base: any SecretStore) {
        self.base = base
    }

    func secret(for account: String) -> String? {
        base.secret(for: account)
    }

    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool {
        let saved = base.setSecret(secret, for: account)
        if saved, secret != nil {
            lock.withLock { _ = written.insert(account) }
        }
        return saved
    }

    /// The accounts that got a new secret since the last call.
    func takeWrittenAccounts() -> Set<String> {
        lock.withLock {
            defer { written = [] }
            return written
        }
    }
}
