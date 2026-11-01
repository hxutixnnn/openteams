import Foundation

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

final class Client: NSObject, PrototypeCredentialClient, @unchecked Sendable {
    let intent = UUID().uuidString
    let lock = NSLock()
    var callbacks = 0
    let hold = CommandLine.arguments.contains("--clear-during-save") || CommandLine.arguments.contains("--interrupt")
    let arrived = DispatchSemaphore(value: 0)
    var pending: (@Sendable (Data?) -> Void)?
    func release() { lock.lock(); let callback = pending; pending = nil; lock.unlock(); callback?(Data("DUMMY:proof".utf8)) }
    func fetchDummy(intent: String, reply: @escaping @Sendable (Data?) -> Void) {
        lock.lock(); callbacks += 1; let valid = intent == self.intent && callbacks == 1
        if valid && hold { pending = reply; lock.unlock(); arrived.signal(); return }
        lock.unlock(); reply(valid ? Data("DUMMY:proof".utf8) : nil)
    }
}

#if BUILD_TWO
let buildLabel = "changed"
#else
let buildLabel = "original"
#endif
let fingerprint = Bundle.main.object(forInfoDictionaryKey: "TeamsSigningCertificate") as! String
let connection = NSXPCConnection(serviceName: "dev.native.teamschat.credential-prototype")
connection.setCodeSigningRequirement("identifier \"dev.native.teamschat.credential-prototype\" and certificate leaf = H\"\(fingerprint)\"")
connection.remoteObjectInterface = NSXPCInterface(with: PrototypeCredentialService.self)
connection.exportedInterface = NSXPCInterface(with: PrototypeCredentialClient.self)
let client = Client()
connection.exportedObject = client
connection.resume()
let done = DispatchSemaphore(value: 0)
let lock = NSLock()
var succeeded = false
var helperPID: Int32 = 0
var observedRevision = "none"
let saveOnly = CommandLine.arguments.contains("--save-only")
let loadOnly = CommandLine.arguments.contains("--load-only")
let expectEmpty = CommandLine.arguments.contains("--expect-empty")
let replay = CommandLine.arguments.contains("--replay")
let wrongScope = CommandLine.arguments.contains("--wrong-scope")
let staleIndex = CommandLine.arguments.firstIndex(of: "--stale-version")
let staleVersion = staleIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as! PrototypeCredentialService
func finish(_ value: Bool) {
    lock.lock(); succeeded = value; lock.unlock(); done.signal()
}
proxy.processID { pid in
    lock.lock(); helperPID = pid; lock.unlock()
    if CommandLine.arguments.contains("--diagnose-login") {
        proxy.diagnoseLogin { details in
            var auditUID: UInt32 = 0
            let auditStatus = getAuditUID(&auditUID)
            let combined = "clientPID=\(getpid()) clientUID=\(getuid()) clientEUID=\(geteuid()) clientAuditStatus=\(auditStatus) clientAuditUID=\(auditUID) " + details
            print("login diagnostic: \(combined)")
            if let index = CommandLine.arguments.firstIndex(of: "--diagnostic-output"), CommandLine.arguments.indices.contains(index + 1) {
                try? combined.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
            }
            finish(true)
        }
        return
    }
    if loadOnly || expectEmpty {
        proxy.loadDummy(accountScope: "dummy-account") { data, _ in
            guard expectEmpty ? data == nil : data == Data("DUMMY:proof".utf8) else { finish(false); return }
            proxy.clearDummy(accountScope: "dummy-account") { _, status in finish(status == 0) }
        }
        return
    }
    proxy.revision { revision in
        lock.lock(); observedRevision = revision; lock.unlock()
        proxy.saveDummy(intent: client.intent, accountScope: "dummy-account", expectedRevision: staleVersion ?? revision) { saved in
            if staleVersion != nil { finish(!saved); return }
            if client.hold {
                guard !saved else { finish(false); return }
                proxy.loadDummy(accountScope: "dummy-account") { data, _ in finish(data == nil) }
                return
            }
            guard saved else { finish(false); return }
            if saveOnly { proxy.shutdown { finish(true) }; return }
            if replay || wrongScope {
                proxy.revision { newer in
                    proxy.saveDummy(intent: wrongScope ? UUID().uuidString : client.intent,
                                    accountScope: wrongScope ? "different-account" : "dummy-account", expectedRevision: newer) { accepted in
                        proxy.clearDummy(accountScope: "dummy-account") { _, status in finish(!accepted && status == 0) }
                    }
                }
                return
            }
            proxy.loadDummy(accountScope: "dummy-account") { data, _ in
                guard data == Data("DUMMY:proof".utf8) else { finish(false); return }
                proxy.clearDummy(accountScope: "dummy-account") { _, status in finish(status == 0) }
            }
        }
    }
}
if client.hold && client.arrived.wait(timeout: .now() + 8) == .success {
    if CommandLine.arguments.contains("--interrupt") { connection.invalidate(); print("interrupted after dummy pull"); exit(0) }
    proxy.clearDummy(accountScope: "dummy-account") { _, status in if status == 0 { client.release() } else { finish(false) } }
}
let completed = done.wait(timeout: .now() + 8) == .success
connection.invalidate()
lock.lock(); let result = succeeded; let pid = helperPID; let version = observedRevision; lock.unlock()
client.lock.lock(); let callbacks = client.callbacks; client.lock.unlock()
print("build=\(buildLabel) completed=\(completed) success=\(result) callbacks=\(callbacks) helperPID=\(pid) version=\(version)")
exit(result ? 0 : 1)
