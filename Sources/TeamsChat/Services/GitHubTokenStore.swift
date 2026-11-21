import Foundation
import LocalAuthentication
import Security
import TeamsCore

enum GitHubTokenStoreError: Error { case invalidToken, keychain(OSStatus) }

enum GitHubTokenStore {
    private static let service = "dev.native.teamschat.github-issues"
    private static let account = "issues-write"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func normalized(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512, trimmed.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return nil }
        return trimmed
    }

    static func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GitHubTokenStoreError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw GitHubTokenStoreError.invalidToken }
        return token
    }

    static func contains() -> Bool {
        var query = baseQuery
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ token: String) throws {
        guard let token = normalized(token) else { throw GitHubTokenStoreError.invalidToken }
        let data = Data(token.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "OpenTeams GitHub issue reporting"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw GitHubTokenStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw GitHubTokenStoreError.keychain(status)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubTokenStoreError.keychain(status) }
    }
}

struct GitHubKeychainTokenSource: GitHubTokenSource {
    func gitHubToken() async throws -> String? { try GitHubTokenStore.load() }
}

extension GitHubIssueClient {
    static func keychainBacked(transport: any HTTPTransport = TeamsWebURLSessionTransport()) -> GitHubIssueClient {
        GitHubIssueClient(tokenSource: GitHubKeychainTokenSource(), transport: transport)
    }
}
