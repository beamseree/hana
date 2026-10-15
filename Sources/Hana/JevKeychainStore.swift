import Foundation
import Security

/// Generic-password storage only. Errors intentionally contain neither the key nor OS descriptions.
struct JevKeychainStore {
    struct Failure: Error { let status: OSStatus }
    let service: String
    private let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    init(service: String = "com.beamseree.hana.jev-api-key",
         copyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching) {
        self.service = service; self.copyMatching = copyMatching
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "jev", kSecAttrSynchronizable as String: false]
    }
    func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw Failure(status: status)
        }
        return key
    }
    /// Menu refreshes ask for metadata only and cannot prompt for secret data.
    func containsKey() throws -> Bool {
        var query = query
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return true
    }
    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
        } else if status != errSecSuccess { throw Failure(status: status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
