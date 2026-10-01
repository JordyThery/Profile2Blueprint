import Foundation
import Security

/// Storage for OAuth client secrets. Secrets never leave this abstraction except to
/// build the token request body.
nonisolated protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ secret: String, for account: String) throws
    func deleteSecret(for account: String) throws
}

nonisolated struct KeychainError: Error, LocalizedError, Sendable {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Generic-password Keychain storage, scoped to this app (sandboxed apps only see
/// items they created).
nonisolated struct KeychainStore: SecretStore {
    let service: String

    init(service: String = "be.jordythery.profile2blueprint.oauth-client-secret") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func secret(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Profile2Blueprint OAuth client secret"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func deleteSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// Non-persistent store for tests and offline demo mode.
nonisolated final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    init(_ initial: [String: String] = [:]) {
        storage = initial
    }

    func secret(for account: String) throws -> String? {
        lock.withLock { storage[account] }
    }

    func setSecret(_ secret: String, for account: String) throws {
        lock.withLock { storage[account] = secret }
    }

    func deleteSecret(for account: String) throws {
        _ = lock.withLock { storage.removeValue(forKey: account) }
    }
}
