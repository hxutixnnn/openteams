import Foundation
import LocalAuthentication
import Security
import TeamsCore

enum GitHubTokenStoreError: Error { case invalidToken, keychain(OSStatus) }

enum GitHubTokenStore {
    private static let service = "dev.native.teamschat.github-issues"
    private static let account = "issues-write"
    fileprivate static let tokenSource = TimedGitHubTokenSource(source: GitHubKeychainTokenSource())
    private static let existenceSource = TimedGitHubTokenSource(source: GitHubKeychainTokenSource(attributesOnly: true))

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func normalized(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512, trimmed.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return nil }
        return trimmed
    }

    static func load() async -> String? {
        await tokenSource.gitHubToken()
    }

    fileprivate static func read(attributesOnly: Bool) -> String? {
        var query = baseQuery
        if attributesOnly { query[kSecReturnAttributes as String] = true }
        else { query[kSecReturnData as String] = true }
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if attributesOnly { return status == errSecItemNotFound ? "absent" : "present" }
        guard status == errSecSuccess else { return nil }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    static func contains() async -> Bool {
        await existenceSource.gitHubToken() != "absent"
    }

    static func save(_ token: String) async throws {
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
        await tokenSource.reset()
        await existenceSource.reset()
    }

    static func delete() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubTokenStoreError.keychain(status) }
        await tokenSource.reset()
        await existenceSource.reset()
    }
}

struct GitHubKeychainTokenSource: GitHubTokenSource {
    var attributesOnly = false

    func gitHubToken() async -> String? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: GitHubTokenStore.read(attributesOnly: attributesOnly))
            }
        }
    }
}

extension GitHubIssueClient {
    static func keychainBacked(transport: any HTTPTransport = TeamsWebURLSessionTransport()) -> GitHubIssueClient {
        GitHubIssueClient(tokenSource: GitHubTokenStore.tokenSource, transport: transport)
    }
}
