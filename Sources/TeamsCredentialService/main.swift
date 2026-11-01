@preconcurrency import Foundation
import Security
import TeamsCredentialIPC

private struct Envelope: Codable {
    var scope: String?
    var sessionID: String?
    var revision: UInt64
    var credential: Data?
}

private final class Store: @unchecked Sendable {
    static let shared = Store()
    let queue = DispatchQueue(label: "dev.native.teamschat.credentials")
    let boot = UUID().uuidString
    var revision: UInt64 = 0
    var scope: String?
    var sessionID: String?
    var credential: Data?
    var status: OSStatus = errSecNotAvailable
    var revocationDirty = false
    var revokedScope: String?
    var revokedSessionID: String?
    var testLoadFault = false
    var testRevokeFault = false
    var isTest: Bool { serviceName.hasPrefix("dev.native.teamschat.helper.test.") }
    var version: String { "\(boot):\(revision)" }
    private let serviceName: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "TeamsCredentialStoreService") as? String ?? ""
        if value == "dev.native.teamschat.helper.session.v2" { return value }
        let prefix = "dev.native.teamschat.helper.test."
        if value.hasPrefix(prefix), UUID(uuidString: String(value.dropFirst(prefix.count))) != nil { return value }
        return ""
    }()
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName, kSecAttrAccount as String: "current"] }

    init() { reload() }

    func ensureReady() { if status != errSecSuccess && !revocationDirty { reload() } }

    private func reload() {
        guard !serviceName.isEmpty else { status = errSecParam; return }
        var previous: DarwinBoolean = true
        let get = SecKeychainGetUserInteractionAllowed(&previous)
        guard get == errSecSuccess else { status = get; return }
        let disable = SecKeychainSetUserInteractionAllowed(false)
        guard disable == errSecSuccess else { status = disable; return }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        var match = query; match[kSecReturnData as String] = true
        var result: CFTypeRef?
        let found = SecItemCopyMatching(match as CFDictionary, &result)
        if found == errSecItemNotFound {
            scope = nil; sessionID = nil; credential = nil; revision &+= 1; status = errSecSuccess; return
        }
        guard found == errSecSuccess else { status = found; return }
        guard let data = result as? Data, data.count <= 200_000,
              let record = try? JSONDecoder().decode(Envelope.self, from: data),
              (record.credential?.count ?? 0) <= 100_000 else { status = errSecDecode; return }
        let empty = record.scope == nil && record.sessionID == nil && record.credential == nil
        let validScope = record.scope.map(Self.validScope) ?? false
        let validSession = record.sessionID.flatMap(UUID.init(uuidString:)) != nil
        guard empty || (validScope && validSession && (record.credential == nil || !(record.credential?.isEmpty ?? true))) else {
            status = errSecDecode; return
        }
        scope = record.scope; sessionID = record.sessionID; credential = record.credential; revision = record.revision; status = errSecSuccess
    }

    static func validScope(_ scope: String) -> Bool {
        let parts = scope.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { UUID(uuidString: String($0)) != nil }
    }

    func removeTestRecord() {
        guard serviceName.hasPrefix("dev.native.teamschat.helper.test.") else { return }
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        SecItemDelete(query as CFDictionary)
    }

    func persist() -> OSStatus {
        guard let data = try? JSONEncoder().encode(Envelope(scope: scope, sessionID: sessionID, revision: revision, credential: credential)) else { return errSecParam }
        var previous: DarwinBoolean = true
        let get = SecKeychainGetUserInteractionAllowed(&previous)
        guard get == errSecSuccess else { return get }
        let disable = SecKeychainSetUserInteractionAllowed(false)
        guard disable == errSecSuccess else { return disable }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }
}

private final class ConnectionService: NSObject, TeamsCredentialTestServiceProtocol, @unchecked Sendable {
    private var connection: NSXPCConnection?
    private var active = true
    private var consumed: Set<String> = []
    private var pending: Set<String> = []
    init(_ connection: NSXPCConnection) { self.connection = connection }
    func invalidate() {
        Store.shared.queue.async {
            self.active = false; self.connection = nil; self.pending.removeAll(); self.consumed.removeAll()
        }
    }
    private func validScope(_ scope: String) -> Bool { Store.validScope(scope) }
    private let ok = TeamsCredentialProtocolStatus.success.rawValue
    private let invalid = TeamsCredentialProtocolStatus.invalidRequest.rawValue
    private let stale = TeamsCredentialProtocolStatus.stale.rawValue
    private let mismatch = TeamsCredentialProtocolStatus.scopeMismatch.rawValue
    private let revoked = TeamsCredentialProtocolStatus.revoked.rawValue
    private let unavailable = TeamsCredentialProtocolStatus.unavailable.rawValue

    func configureFault(_ name: String, reply: @escaping @Sendable (Bool) -> Void) {
        let store = Store.shared
        store.queue.async {
            guard self.active, store.isTest else { reply(false); return }
            switch name {
            case "load-once": store.testLoadFault = true
            case "revoke-once": store.testRevokeFault = true
            case "restart":
                reply(true)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
                return
            default: reply(false); return
            }
            reply(true)
        }
    }
    func disposeTestRecord(reply: @escaping @Sendable (Int32) -> Void) {
        let store = Store.shared
        store.queue.async {
            guard self.active, store.isTest else { reply(errSecParam); return }
            store.removeTestRecord()
            store.scope = nil; store.sessionID = nil; store.credential = nil; store.revocationDirty = false
            store.revision &+= 1; store.status = errSecSuccess
            reply(errSecSuccess)
        }
    }
    func load(accountScope: String, reply: @escaping @Sendable (Data?, String, String?, Int32, Int32) -> Void) {
        let store = Store.shared
        store.queue.async {
            if store.isTest && store.testLoadFault {
                store.testLoadFault = false; store.status = errSecInteractionNotAllowed
                reply(nil, store.version, nil, self.ok, store.status); return
            }
            store.ensureReady()
            guard self.active, self.validScope(accountScope) else { reply(nil, "", nil, self.invalid, 0); return }
            guard store.status == errSecSuccess else { reply(nil, store.version, nil, self.ok, store.status); return }
            guard store.scope == nil || store.scope == accountScope else { reply(nil, store.version, nil, self.mismatch, 0); return }
            reply(store.credential, store.version, store.sessionID, self.ok, 0)
        }
    }
    func begin(accountScope: String, expectedVersion: String, reply: @escaping @Sendable (String, String?, Int32, Int32) -> Void) {
        let store = Store.shared
        store.queue.async {
            store.ensureReady()
            guard self.active, self.validScope(accountScope) else { reply("", nil, self.invalid, 0); return }
            guard store.status == errSecSuccess else { reply(store.version, nil, self.ok, store.status); return }
            guard store.version == expectedVersion else { reply(store.version, nil, self.stale, 0); return }
            guard store.scope == nil else { reply(store.version, nil, self.mismatch, 0); return }
            let id = UUID().uuidString
            store.scope = accountScope; store.sessionID = id; store.revision &+= 1
            let result = store.persist()
            if result != errSecSuccess { store.scope = nil; store.sessionID = nil }
            reply(store.version, result == errSecSuccess ? id : nil, self.ok, result)
        }
    }
    func save(intent: String, accountScope: String, sessionID: String, expectedVersion: String,
              reply: @escaping @Sendable (String, Int32, Int32) -> Void) {
        guard UUID(uuidString: intent) != nil, UUID(uuidString: sessionID) != nil, validScope(accountScope) else { reply("", invalid, 0); return }
        let store = Store.shared
        store.queue.async {
            store.ensureReady()
            guard self.active else { reply(store.version, self.unavailable, 0); return }
            guard store.status == errSecSuccess else { reply(store.version, self.ok, store.status); return }
            guard store.scope == accountScope else { reply(store.version, self.mismatch, 0); return }
            guard store.sessionID == sessionID else { reply(store.version, self.revoked, 0); return }
            guard store.version == expectedVersion, self.consumed.insert(intent).inserted else { reply(store.version, self.stale, 0); return }
            self.pending.insert(intent)
            guard let connection = self.connection,
                  let client = connection.remoteObjectProxyWithErrorHandler({ _ in
                store.queue.async {
                    guard self.pending.remove(intent) != nil else { return }
                    reply("", self.unavailable, 0)
                }
            }) as? TeamsCredentialPull else {
                self.pending.remove(intent); reply("", self.unavailable, 0); return
            }
            client.fetch(intent: intent, accountScope: accountScope, sessionID: sessionID) { data in
                store.queue.async {
                    guard self.pending.remove(intent) != nil else { return }
                    guard self.active, store.status == errSecSuccess, store.version == expectedVersion,
                          store.scope == accountScope, store.sessionID == sessionID,
                          let data, !data.isEmpty, data.count <= 100_000 else { reply(store.version, self.stale, 0); return }
                    let previous = (store.credential, store.revision)
                    store.credential = data; store.revision &+= 1
                    let status = store.persist()
                    if status != errSecSuccess { (store.credential, store.revision) = previous }
                    let version = store.version
                    if Bundle.main.object(forInfoDictionaryKey: "TeamsTestDelaySaveReply") as? Bool == true {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { reply(version, self.ok, status) }
                    } else { reply(version, self.ok, status) }
                }
            }
        }
    }
    func revoke(accountScope: String, sessionID: String, reply: @escaping @Sendable (String, Int32, Int32) -> Void) {
        let store = Store.shared
        store.queue.async {
            store.ensureReady()
            guard self.active, self.validScope(accountScope), UUID(uuidString: sessionID) != nil else { reply("", self.invalid, 0); return }
            if store.revocationDirty {
                guard store.revokedScope == accountScope, store.revokedSessionID == sessionID else { reply(store.version, self.revoked, 0); return }
                let status = store.persist()
                if status == errSecSuccess {
                    store.revocationDirty = false; store.revokedScope = nil; store.revokedSessionID = nil
                    store.status = errSecSuccess; store.removeTestRecord()
                } else { store.status = status }
                reply(store.version, self.ok, status); return
            }
            guard store.status == errSecSuccess else { reply(store.version, self.ok, store.status); return }
            guard store.scope == accountScope else { reply(store.version, self.mismatch, 0); return }
            guard store.sessionID == sessionID else { reply(store.version, self.revoked, 0); return }
            store.revokedScope = accountScope; store.revokedSessionID = sessionID
            store.revision &+= 1; store.scope = nil; store.sessionID = nil; store.credential = nil
            store.revocationDirty = true
            let status: OSStatus
            if store.isTest && store.testRevokeFault { store.testRevokeFault = false; status = errSecInteractionNotAllowed }
            else { status = store.persist() }
            if status == errSecSuccess { store.revocationDirty = false; store.revokedScope = nil; store.revokedSessionID = nil; store.removeTestRecord() }
            else { store.status = status }
            reply(store.version, self.ok, status)
        }
    }

}

private final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let fingerprint = Bundle.main.object(forInfoDictionaryKey: "TeamsSigningCertificate") as? String,
              fingerprint.range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil else { return false }
        connection.setCodeSigningRequirement("identifier \"dev.native.teamschat\" and certificate leaf = H\"\(fingerprint)\"")
        let testService = (Bundle.main.object(forInfoDictionaryKey: "TeamsCredentialStoreService") as? String)?.hasPrefix("dev.native.teamschat.helper.test.") == true
        connection.exportedInterface = NSXPCInterface(with: testService ? TeamsCredentialTestServiceProtocol.self : TeamsCredentialServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: TeamsCredentialPull.self)
        let service = ConnectionService(connection)
        connection.exportedObject = service
        connection.invalidationHandler = { service.invalidate() }
        connection.interruptionHandler = { service.invalidate() }
        connection.resume()
        return true
    }
}

private let delegate = Listener()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
