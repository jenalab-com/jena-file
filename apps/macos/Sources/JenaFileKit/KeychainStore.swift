import Foundation
import Security

/// Passwords for saved servers, in the login Keychain (ADR-005). The core never
/// stores secrets; profiles.json only has the profile id we use as the account.
public struct KeychainStore {
    public let service: String

    public init(service: String = "com.jenalab.jena-file") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(_ password: String, for account: String) -> Bool {
        let data = Data(password.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = L("jena-file 서버 비밀번호")
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
