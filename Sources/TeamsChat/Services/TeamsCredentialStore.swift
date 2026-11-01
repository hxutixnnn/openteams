import Foundation
import LocalAuthentication
import Security
import TeamsCore
import TeamsCredentialPersistence

enum TeamsCredentialStore {
    private static let service = "dev.native.teamschat.session"
    private static let account = "current"
    private static let interactionLock = NSLock()

    private static func scoped<T>(interactive: Bool, _ body: () throws -> T) throws -> T {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var previous: DarwinBoolean = true
        if !interactive {
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                throw TeamsCredentialError.interactionRequired
            }
        }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        return try body()
    }

    private static func check(_ status: OSStatus) throws {
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw TeamsCredentialError.interactionRequired }
        guard status == errSecSuccess else { throw CocoaError(.fileReadNoPermission) }
    }

    static func load(interactive: Bool = false) throws -> TeamsCredentials? {
        try scoped(interactive: interactive) {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true]
            if !interactive {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
            }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            try check(status)
            guard let data = result as? Data else { throw CocoaError(.fileReadCorruptFile) }
            return try JSONDecoder().decode(TeamsCredentials.self, from: data)
        }
    }

    static func save(_ credentials: TeamsCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try scoped(interactive: false) {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account]
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                try check(SecItemAdd(item as CFDictionary, nil))
            } else { try check(status) }
        }
    }

    static func delete() throws {
        try scoped(interactive: true) {
            let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account] as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }
    }
}

struct TeamsKeychainCredentialAccess: TeamsCredentialAccess {
    func load(interactive: Bool) async throws -> TeamsCredentials? { try TeamsCredentialStore.load(interactive: interactive) }
    func save(_ credentials: TeamsCredentials) async throws { try TeamsCredentialStore.save(credentials) }
    func delete() async throws { try TeamsCredentialStore.delete() }
}

struct TeamsUnavailableCredentialAccess: TeamsCredentialAccess {
    func load(interactive: Bool) async throws -> TeamsCredentials? { throw CocoaError(.fileNoSuchFile) }
    func save(_ credentials: TeamsCredentials) async throws { throw CocoaError(.fileNoSuchFile) }
    func delete() async throws { throw CocoaError(.fileNoSuchFile) }
}
