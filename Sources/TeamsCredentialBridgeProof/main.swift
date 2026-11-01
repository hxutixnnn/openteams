import Foundation
@testable import TeamsCredentialBridge
import TeamsCredentialIPC
import TeamsCore
import TeamsCredentialPersistence

actor PullGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var reached = false
    func wait() async { reached = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func mark() { reached = true }
}

@MainActor final class FaultController {
    let connection: NSXPCConnection
    init(certificate: String) {
        connection = NSXPCConnection(serviceName: "dev.native.teamschat.credential-service")
        connection.setCodeSigningRequirement("identifier \"dev.native.teamschat.credential-service\" and certificate leaf = H\"\(certificate)\"")
        connection.remoteObjectInterface = NSXPCInterface(with: TeamsCredentialTestServiceProtocol.self)
        connection.resume()
    }
    func configure(_ name: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let proxy = connection.remoteObjectProxy as! TeamsCredentialTestServiceProtocol
            proxy.configureFault(name) { continuation.resume(returning: $0) }
        }
    }
    func dispose() async -> Int32 {
        await withCheckedContinuation { continuation in
            let proxy = connection.remoteObjectProxy as! TeamsCredentialTestServiceProtocol
            proxy.disposeTestRecord { continuation.resume(returning: $0) }
        }
    }
}

@main struct Proof {
    @MainActor static func adapterProof(fingerprint: String) async throws {
        let tenant = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", account = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let expiry = Date().addingTimeInterval(3600).timeIntervalSince1970
        func jwt(_ audience: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["aud": audience, "oid": account, "tid": tenant, "exp": expiry])
            return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".dummy"
        }
        let handoff = try JSONSerialization.data(withJSONObject: ["csaBaseURL": "https://teams.cloud.microsoft/api/csa/amer", "accessToken": jwt("https://chatsvcagg.teams.microsoft.com"), "expiresAt": expiry,
            "messaging": ["baseURL": "https://teams.cloud.microsoft/api/chatsvc/amer", "accessToken": jwt("https://ic3.teams.office.com"), "expiresAt": expiry]])
        let processSave = CommandLine.arguments.contains("--adapter-process-save")
        let processLoad = CommandLine.arguments.contains("--adapter-process-load")
        let suite = (processSave || processLoad) ? CommandLine.arguments.last! : "TeamsAdapterProof." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw TeamsCredentialBridgeError.unavailable }
        defer { if !processSave { defaults.removePersistentDomain(forName: suite) } }
        if processSave {
            let adapter = TeamsHelperCredentialAccess(bridge: try TeamsCredentialBridge(certificate: fingerprint), defaults: defaults)
            try await adapter.save(TeamsCredentials(handoff: handoff, refreshToken: "DUMMY:process"))
            print("process-save=true"); return
        }
        if processLoad {
            let adapter = TeamsHelperCredentialAccess(bridge: try TeamsCredentialBridge(certificate: fingerprint), defaults: defaults)
            guard let loaded = try await adapter.load(interactive: false), loaded.refreshToken == "DUMMY:process" else { throw TeamsCredentialBridgeError.invalidInput }
            try await adapter.delete()
            print("process-recovery=true"); return
        }
        let first = TeamsHelperCredentialAccess(bridge: try TeamsCredentialBridge(certificate: fingerprint), defaults: defaults)
        guard try await first.load(interactive: false) == nil else { print("adapter-slot-not-empty"); exit(1) }
        try await first.save(TeamsCredentials(handoff: handoff, refreshToken: "DUMMY:adapter"))
        if CommandLine.arguments.contains("--adapter-restart") {
            let controller = FaultController(certificate: fingerprint)
            guard await controller.configure("restart") else { throw TeamsCredentialBridgeError.unavailable }
            try await Task.sleep(for: .seconds(1))
        }
        try await first.save(TeamsCredentials(handoff: handoff, refreshToken: "DUMMY:rotated"))
        defaults.set([tenant + ":cccccccc-cccc-cccc-cccc-cccccccccccc", tenant + ":" + account], forKey: "teamsCredentialRecoveryScopes")
        let second = TeamsHelperCredentialAccess(bridge: try TeamsCredentialBridge(certificate: fingerprint), defaults: defaults)
        guard let loaded = try await second.load(interactive: false), loaded.refreshToken == "DUMMY:rotated" else { print("adapter-load=false"); exit(1) }
        second.invalidate()
        if CommandLine.arguments.contains("--adapter-restart") {
            let controller = FaultController(certificate: fingerprint)
            guard await controller.configure("revoke-once") else { throw TeamsCredentialBridgeError.unavailable }
            var failed = false
            do { try await second.delete() } catch { failed = true }
            guard failed else { throw TeamsCredentialBridgeError.invalidInput }
        }
        try await second.delete()
        let third = TeamsHelperCredentialAccess(bridge: try TeamsCredentialBridge(certificate: fingerprint), defaults: defaults)
        guard try await third.load(interactive: false) == nil else { print("adapter-clear=false"); exit(1) }
        if CommandLine.arguments.contains("--adapter-restart") {
            try await third.save(TeamsCredentials(handoff: handoff, refreshToken: "DUMMY:revoke"))
            let other = try TeamsCredentialBridge(certificate: fingerprint)
            let scope = tenant + ":" + account
            let state = try await other.load(scope: scope)
            guard let sessionID = state.sessionID else { throw TeamsCredentialBridgeError.invalidInput }
            _ = try await other.revoke(scope: scope, sessionID: sessionID)
            try await third.delete()
        }
        print("adapter-save=true adapter-reload=true adapter-revoke=true")
    }
    @MainActor static func main() async {
        do {
            #if BUILD_TWO
            let buildLabel = "changed"
            #else
            let buildLabel = "original"
            #endif
            let fingerprint = Bundle.main.object(forInfoDictionaryKey: "TeamsSigningCertificate") as? String ?? ""
            if CommandLine.arguments.contains("--adapter") || CommandLine.arguments.contains("--adapter-restart") || CommandLine.arguments.contains("--adapter-process-save") || CommandLine.arguments.contains("--adapter-process-load") {
                try await adapterProof(fingerprint: fingerprint)
                exit(0)
            }
            let gate = PullGate()
            let testingCancel = CommandLine.arguments.contains("--cancel-pull")
            let lostReply = CommandLine.arguments.contains("--lost-reply")
            let staleIndex = CommandLine.arguments.firstIndex(of: "--stale-version")
            let staleVersion = staleIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
            let bridge: TeamsCredentialBridge
            if testingCancel { bridge = try TeamsCredentialBridge(certificate: fingerprint, beforePull: { await gate.wait() }) }
            else if staleVersion != nil { bridge = try TeamsCredentialBridge(certificate: fingerprint, beforePull: { await gate.mark() }) }
            else { bridge = try TeamsCredentialBridge(certificate: fingerprint) }
            let scope = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            let dummy = Data("DUMMY:shipping-proof".utf8)
            let controller = FaultController(certificate: fingerprint)
            if CommandLine.arguments.contains("--transient-recovery") {
                guard await controller.configure("load-once") else { exit(1) }
                do { _ = try await bridge.load(scope: scope); print("fault-not-observed"); exit(1) }
                catch let error as TeamsCredentialBridgeError { guard error == .keychain(-25308) else { throw error } }
                let recovered = try await bridge.load(scope: scope)
                guard recovered.data == nil else { exit(1) }
                print("transient-load-failure=recovered-without-restart"); exit(0)
            }
            let existing = try await bridge.load(scope: scope)
            if let staleVersion {
                guard let session = existing.sessionID, existing.data == dummy else { exit(1) }
                do { _ = try await bridge.save(dummy, scope: scope, sessionID: session, expectedVersion: staleVersion); print("stale-accepted"); exit(1) }
                catch let error as TeamsCredentialBridgeError { guard error == .stale else { throw error } }
                guard !(await gate.reached) else { print("stale-pull=true"); exit(1) }
                print("stale-version=rejected-before-pull"); exit(0)
            }
            if CommandLine.arguments.contains("--check-only") {
                guard existing.data == dummy else { print("load=false"); exit(1) }
                print("build=\(buildLabel) load=true"); exit(0)
            }
            if CommandLine.arguments.contains("--load-only") {
                guard existing.data == dummy, let session = existing.sessionID else { print("load=false"); exit(1) }
                _ = try await bridge.revoke(scope: scope, sessionID: session)
                let cleared = try await bridge.load(scope: scope)
                guard cleared.data == nil, cleared.sessionID == nil else { print("clear=false"); exit(1) }
                print("build=\(buildLabel) load=true clear=true"); exit(0)
            }
            guard existing.data == nil, existing.sessionID == nil else { print("slot-not-empty"); exit(1) }
            let begun = try await bridge.begin(scope: scope, expectedVersion: existing.version)
            guard let session = begun.sessionID else { print("begin=false"); exit(1) }
            if testingCancel {
                let pending = Task { try await bridge.save(dummy, scope: scope, sessionID: session, expectedVersion: begun.version) }
                while !(await gate.reached) { await Task.yield() }
                bridge.cancelPending()
                await gate.release()
                do { _ = try await pending.value; print("cancel=false"); exit(1) } catch { }
                let after = try await bridge.load(scope: scope)
                guard after.data == nil else { print("late-save=true"); exit(1) }
                _ = try await bridge.revoke(scope: scope, sessionID: session)
                print("cancel=true late-save=false"); exit(0)
            }
            if CommandLine.arguments.contains("--clear-failure") {
                _ = try await bridge.save(dummy, scope: scope, sessionID: session, expectedVersion: begun.version)
                guard await controller.configure("revoke-once") else { exit(1) }
                do { _ = try await bridge.revoke(scope: scope, sessionID: session); print("fault-not-observed"); exit(1) }
                catch let error as TeamsCredentialBridgeError { guard error == .keychain(-25308) else { throw error } }
                do { _ = try await bridge.load(scope: scope); print("revoked-data-restored"); exit(1) }
                catch let error as TeamsCredentialBridgeError { guard error == .keychain(-25308) else { throw error } }
                _ = try await bridge.revoke(scope: scope, sessionID: session)
                let retried = try await bridge.load(scope: scope)
                guard retried.data == nil, retried.sessionID == nil else { exit(1) }
                print("failed-clear=memory-revoked explicit-retry=true"); exit(0)
            }
            if lostReply {
                let pending = Task { try await bridge.save(dummy, scope: scope, sessionID: session, expectedVersion: begun.version) }
                let observer = try TeamsCredentialBridge(certificate: fingerprint)
                var observed = try await observer.load(scope: scope)
                while observed.data != dummy { try await Task.sleep(for: .milliseconds(30)); observed = try await observer.load(scope: scope) }
                bridge.cancelPending()
                do { _ = try await pending.value; print("cancel=false"); exit(1) }
                catch let error as TeamsCredentialBridgeError { guard error == .outcomeUnknown else { throw error } }
                _ = try await observer.revoke(scope: scope, sessionID: session)
                let cleared = try await observer.load(scope: scope)
                guard cleared.data == nil, cleared.sessionID == nil else { print("revoke=false"); exit(1) }
                let replacement = try await observer.begin(scope: scope, expectedVersion: cleared.version)
                do { _ = try await observer.revoke(scope: scope, sessionID: session); print("old-revoke-accepted"); exit(1) }
                catch let error as TeamsCredentialBridgeError { guard error == .revoked else { throw error } }
                guard let replacementID = replacement.sessionID else { exit(1) }
                do { _ = try await observer.save(dummy, scope: scope, sessionID: session, expectedVersion: replacement.version); print("old-save-accepted"); exit(1) }
                catch let error as TeamsCredentialBridgeError { guard error == .revoked else { throw error } }
                let otherScope = "cccccccc-cccc-cccc-cccc-cccccccccccc:dddddddd-dddd-dddd-dddd-dddddddddddd"
                do { _ = try await observer.save(dummy, scope: otherScope, sessionID: replacementID, expectedVersion: replacement.version); print("cross-account-save-accepted"); exit(1) }
                catch let error as TeamsCredentialBridgeError { guard error == .scopeMismatch else { throw error } }
                do { _ = try await observer.revoke(scope: otherScope, sessionID: replacementID); print("cross-account-revoke-accepted"); exit(1) }
                catch let error as TeamsCredentialBridgeError { guard error == .scopeMismatch else { throw error } }
                _ = try await observer.revoke(scope: scope, sessionID: replacementID)
                print("lost-reply=uncertain revoke=true old-session-and-cross-account-rejected=true"); exit(0)
            }
            let written = try await bridge.save(dummy, scope: scope, sessionID: session, expectedVersion: begun.version)
            let saved = try await bridge.load(scope: scope)
            guard saved.data == dummy else { print("save=false"); exit(1) }
            print("build=\(buildLabel) save=true version=\(written.version)")
            exit(0)
        } catch { print("proof-error=\(error)"); exit(1) }
    }
}
