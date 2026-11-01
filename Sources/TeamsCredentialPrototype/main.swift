@preconcurrency import Foundation
import Security
import os

// This prototype accepts only synthetic values and uses an isolated, disposable test Keychain.
@_silgen_name("getauid") private func getAuditUID(_ id: UnsafeMutablePointer<UInt32>) -> Int32

@objc protocol PrototypeCredentialClient {
    func fetchDummy(intent: String, reply: @escaping @Sendable (Data?) -> Void)
}

@objc protocol PrototypeCredentialService {
    func revision(reply: @escaping @Sendable (String) -> Void)
    func saveDummy(intent: String, accountScope: String, expectedRevision: String, reply: @escaping @Sendable (Bool) -> Void)
    func loadDummy(accountScope: String, reply: @escaping @Sendable (Data?, String) -> Void)
    func clearDummy(accountScope: String, reply: @escaping @Sendable (String, Int32) -> Void)
    func processID(reply: @escaping @Sendable (Int32) -> Void)
    func shutdown(reply: @escaping @Sendable () -> Void)
    func diagnoseLogin(reply: @escaping @Sendable (String) -> Void)
}

private struct PrototypeEnvelope: Codable {
    var revision: UInt64
    var value: Data?
    var scope: String?
}

final class PrototypeStore: @unchecked Sendable {
    static let shared = PrototypeStore()
    let queue = DispatchQueue(label: "dev.native.teamschat.prototype-store")
    let bootID = UUID().uuidString
    var revision: UInt64 = 0
    var version: String { "\(bootID):\(revision)" }
    var value: Data?
    var scope: String?
    var ready = false
    private let service = Bundle.main.object(forInfoDictionaryKey: "TeamsPrototypeStore") as? String ?? ""
    private var keychain: SecKeychain?
    private var query: [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                     kSecAttrAccount as String: "dummy"]
        if let keychain { result[kSecMatchSearchList as String] = [keychain] }
        return result
    }
    init() {
        guard service.hasPrefix("dev.native.teamschat.prototype."),
              let path = Bundle.main.object(forInfoDictionaryKey: "TeamsPrototypeKeychain") as? String,
              path.contains("/.codex/validation/xpc-proof.") else { return }
        let password = Array("dummy-only-test".utf8)
        var store: SecKeychain?
        let status: OSStatus
        if FileManager.default.fileExists(atPath: path) {
            status = SecKeychainOpen(path, &store)
        } else {
            status = password.withUnsafeBytes { bytes in SecKeychainCreate(path, UInt32(bytes.count), bytes.baseAddress, false, nil, &store) }
        }
        guard status == errSecSuccess, let store else { return }
        let unlock = password.withUnsafeBytes { bytes in SecKeychainUnlock(store, UInt32(bytes.count), bytes.baseAddress, true) }
        guard unlock == errSecSuccess else { return }
        keychain = store
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(lookup as CFDictionary, &result)
        if lookupStatus == errSecItemNotFound { ready = true }
        else if lookupStatus == errSecSuccess, let data = result as? Data,
                let saved = try? JSONDecoder().decode(PrototypeEnvelope.self, from: data) {
            revision = saved.revision; value = saved.value; scope = saved.scope; ready = true
        }
    }
    func persist(revision: UInt64, value: Data?, scope: String?) -> Bool {
        guard service.hasPrefix("dev.native.teamschat.prototype."), keychain != nil, ready,
              let data = try? JSONEncoder().encode(PrototypeEnvelope(revision: revision, value: value, scope: scope)) else { return false }
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return false }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.removeValue(forKey: kSecMatchSearchList as String)
            item[kSecUseKeychain as String] = keychain
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            Logger(subsystem: "dev.native.teamschat.prototype", category: "keychain").notice("dummy add status \(added, privacy: .public)")
            return added == errSecSuccess
        }
        Logger(subsystem: "dev.native.teamschat.prototype", category: "keychain").notice("dummy update status \(status, privacy: .public)")
        return status == errSecSuccess
    }
    func removeForTest() {
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        SecItemDelete(query as CFDictionary)
    }
}

final class PrototypeConnection: NSObject, PrototypeCredentialService, @unchecked Sendable {
    let connection: NSXPCConnection
    private var active = true
    private var consumedIntents: Set<String> = []
    init(_ connection: NSXPCConnection) { self.connection = connection }

    func invalidate() { PrototypeStore.shared.queue.async { self.active = false } }
    func revision(reply: @escaping @Sendable (String) -> Void) {
        PrototypeStore.shared.queue.async { reply(PrototypeStore.shared.ready ? PrototypeStore.shared.version : "") }
    }
    func saveDummy(intent: String, accountScope: String, expectedRevision: String, reply: @escaping @Sendable (Bool) -> Void) {
        guard UUID(uuidString: intent) != nil, accountScope.range(of: "^[A-Za-z0-9:.-]{1,128}$", options: .regularExpression) != nil else { reply(false); return }
        let store = PrototypeStore.shared
        store.queue.async {
            guard self.active, store.ready, (store.scope == nil || store.scope == accountScope),
                  store.version == expectedRevision, self.consumedIntents.insert(intent).inserted else { reply(false); return }
            guard let client = self.connection.remoteObjectProxyWithErrorHandler({ _ in reply(false) }) as? PrototypeCredentialClient else {
                reply(false); return
            }
            client.fetchDummy(intent: intent) { value in
                store.queue.async {
                    guard self.active, store.version == expectedRevision, (store.scope == nil || store.scope == accountScope), let value, value.count <= 64,
                          let text = String(data: value, encoding: .utf8), text.hasPrefix("DUMMY:") else {
                        reply(false); return
                    }
                    let next = store.revision &+ 1
                    guard store.persist(revision: next, value: value, scope: accountScope) else { reply(false); return }
                    store.value = value; store.revision = next; store.scope = accountScope
                    reply(true)
                }
            }
        }
    }
    func loadDummy(accountScope: String, reply: @escaping @Sendable (Data?, String) -> Void) {
        let store = PrototypeStore.shared
        store.queue.async { reply(self.active && store.ready && store.scope == accountScope ? store.value : nil, store.version) }
    }
    func diagnoseLogin(reply: @escaping @Sendable (String) -> Void) {
        PrototypeStore.shared.queue.async {
            guard self.active else { reply("inactive"); return }
            var previous: DarwinBoolean = true
            let getInteraction = SecKeychainGetUserInteractionAllowed(&previous)
            let disable = SecKeychainSetUserInteractionAllowed(false)
            defer { if disable == errSecSuccess { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
            guard getInteraction == errSecSuccess, disable == errSecSuccess else { reply("interaction-suppression-failed"); return }
            var keychain: SecKeychain?
            let defaultStatus = SecKeychainCopyDefault(&keychain)
            var flags: SecKeychainStatus = 0
            var settings = SecKeychainSettings(version: 1, lockOnSleep: false, useLockInterval: false, lockInterval: 0)
            let stateStatus = keychain.map { SecKeychainGetStatus($0, &flags) } ?? errSecParam
            let settingsStatus = keychain.map { SecKeychainCopySettings($0, &settings) } ?? errSecParam
            var buffer = [CChar](repeating: 0, count: 4096)
            var length = UInt32(buffer.count)
            let pathStatus = keychain.map { SecKeychainGetPath($0, &length, &buffer) } ?? errSecParam
            let path = pathStatus == errSecSuccess ? String(cString: buffer) : ""
            let isLogin = path.hasSuffix("/Library/Keychains/login.keychain-db")
            var auditUID: UInt32 = 0
            let auditStatus = getAuditUID(&auditUID)
            let service = "dev.native.teamschat.prototype.diagnostic." + UUID().uuidString
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "dummy", kSecValueData as String: Data("DUMMY:diagnostic".utf8)]
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            var readStatus: OSStatus = errSecItemNotFound
            var sameDummy = false
            var deleteStatus: OSStatus = errSecItemNotFound
            if addStatus == errSecSuccess {
                let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                            kSecAttrAccount as String: "dummy", kSecReturnData as String: true]
                var result: CFTypeRef?
                readStatus = SecItemCopyMatching(match as CFDictionary, &result)
                sameDummy = (result as? Data) == Data("DUMMY:diagnostic".utf8)
                deleteStatus = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                              kSecAttrAccount as String: "dummy"] as CFDictionary)
            }
            reply("pid=\(getpid()) uid=\(getuid()) euid=\(geteuid()) auditStatus=\(auditStatus) auditUID=\(auditUID) default=\(defaultStatus) isLogin=\(isLogin) state=\(stateStatus) unlocked=\((flags & SecKeychainStatus(kSecUnlockStateStatus)) != 0) settings=\(settingsStatus) dummyAdd=\(addStatus) dummyRead=\(readStatus) sameDummy=\(sameDummy) dummyDelete=\(deleteStatus)")
        }
    }
    func processID(reply: @escaping @Sendable (Int32) -> Void) { reply(getpid()) }
    func shutdown(reply: @escaping @Sendable () -> Void) { reply(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) } }
    func clearDummy(accountScope: String, reply: @escaping @Sendable (String, Int32) -> Void) {
        let store = PrototypeStore.shared
        store.queue.async {
            guard self.active, store.ready, store.scope == nil || store.scope == accountScope else { reply(store.version, -1); return }
            let next = store.revision &+ 1
            store.revision = next; store.value = nil; store.scope = nil
            let success = store.persist(revision: next, value: nil, scope: nil)
            reply(store.version, success ? 0 : -2)
        }
    }
}

final class PrototypeListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let fingerprint = Bundle.main.object(forInfoDictionaryKey: "TeamsSigningCertificate") as? String,
              fingerprint.range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil else { return false }
        let requirement = "identifier \"dev.native.teamschat\" and certificate leaf = H\"\(fingerprint)\""
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: PrototypeCredentialService.self)
        connection.remoteObjectInterface = NSXPCInterface(with: PrototypeCredentialClient.self)
        let service = PrototypeConnection(connection)
        connection.exportedObject = service
        connection.invalidationHandler = { service.invalidate() }
        connection.interruptionHandler = { service.invalidate() }
        connection.resume()
        return true
    }
}

let delegate = PrototypeListener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
