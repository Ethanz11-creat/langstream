import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.flowtype.app"

    /// Security: use kSecAttrAccessibleWhenUnlockedThisDeviceOnly to prevent
    /// iCloud Keychain syncing of API keys, and kSecUseDataProtectionKeychain
    /// for modern data-protection-based keychain on macOS.
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        var deleteQuery = baseQuery
        deleteQuery[kSecAttrAccount as String] = key
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecAttrAccount as String] = key
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.log("[KeychainHelper] save failed for '\(key)': \(status)")
        }
        return status == errSecSuccess
    }

    static func load(key: String) -> String? {
        var query = baseQuery
        query[kSecAttrAccount as String] = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        var query = baseQuery
        query[kSecAttrAccount as String] = key
        SecItemDelete(query as CFDictionary)
    }
}
