import Foundation
import Security

/// Minimal generic-password Keychain wrapper, used to keep the S3 secret key out of UserDefaults.
struct KeychainStore {
    /// The Keychain service name items are filed under.
    let service: String

    static let defaultService = "com.thoughtqueue.app.s3"

    enum KeychainError: LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "Keychain error \(status): \(message)"
            case .invalidData:
                return "Keychain item is not valid UTF-8 text."
            }
        }
    }

    /// Creates a store for the given service name.
    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// Saves (or replaces) the secret for an account.
    func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(account: account)
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Loads the secret for an account, or nil when none is stored.
    func load(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes the secret for an account. Deleting a missing item is not an error.
    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// The attributes that identify one item: class, service and account.
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
