import Foundation
import Security

/// Keeps the sign-in safe on the phone: readable with the phone locked (so playing in the background works),
/// and only on this phone (not copied to another one by a backup).
enum Keychain {
    private static let access = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ADPlayer",
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let found = out as? [String: Any],
              let data = found[kSecValueData as String] as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        // kept the older way (also copied by backups): kept again, on this phone only
        if (found[kSecAttrAccessible as String] as? String) != access {
            let change = [kSecAttrAccessible as String: access] as [String: Any]
            if SecItemUpdate(base(key) as CFDictionary, change as CFDictionary) != errSecSuccess { set(key, value) }
        }
        return value
    }

    static func set(_ key: String, _ value: String?) {
        SecItemDelete(base(key) as CFDictionary)
        guard let value = value, !value.isEmpty else { return }
        var add = base(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = access
        SecItemAdd(add as CFDictionary, nil)
    }
}
