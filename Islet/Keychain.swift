import Foundation
import Security
import IsletKit

/// Stores Dexcom credentials in the Keychain. Accessible after first unlock so background refresh works while locked.
enum Keychain {
    private static let service = "Islet.DexcomShare"
    private static let account = "credentials"

    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Couldn't save to the Keychain (\(status))." }
    }

    static func save(_ credentials: DexcomCredentials) throws {
        try saveData(try JSONEncoder().encode(credentials), account: account)
    }

    static func load() -> DexcomCredentials? {
        loadData(account: account).flatMap { try? JSONDecoder().decode(DexcomCredentials.self, from: $0) }
    }

    static func delete() {
        delete(account: account)
    }

    static func saveString(_ value: String, account: String) {
        if value.isEmpty { delete(account: account) } else { try? saveData(Data(value.utf8), account: account) }
    }

    static func loadString(account: String) -> String? {
        loadData(account: account).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func saveData(_ data: Data, account: String) throws {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private static func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
