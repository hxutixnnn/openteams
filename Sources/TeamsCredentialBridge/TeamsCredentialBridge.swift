@preconcurrency import Foundation
import Security
import TeamsCredentialIPC

public enum TeamsCredentialBridgeError: Error, Equatable {
    case invalidInput, unavailable, cancelled, stale, scopeMismatch, revoked, outcomeUnknown
    case keychain(Int32)
}

public struct TeamsCredentialSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let data: Data?
    public let version: String
    public let sessionID: String?
    public var description: String { "TeamsCredentialSnapshot(data: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["data": "<redacted>"]) }
}

private final class PullEndpoint: NSObject, TeamsCredentialPull, @unchecked Sendable {
    let connectionID: UUID
    weak var owner: TeamsCredentialBridge?
    init(connectionID: UUID, owner: TeamsCredentialBridge) { self.connectionID = connectionID; self.owner = owner }
    func fetch(intent: String, accountScope: String, sessionID: String, reply: @escaping @Sendable (Data?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, let owner = self.owner else { reply(nil); return }
            reply(await owner.consume(intent: intent, accountScope: accountScope, sessionID: sessionID, connectionID: self.connectionID))
        }
    }
}

/// Authenticated XPC bridge to the pinned credential helper.
@MainActor public final class TeamsCredentialBridge {
    private struct Pull {
        var intent: String
        var scope: String
        var sessionID: String
        var connectionID: UUID
        var generation: UUID
        var data: Data
    }
    private var connection: NSXPCConnection?
    private var endpoint: PullEndpoint?
    private var connectionID = UUID()
    private var generation = UUID()
    private var pendingPull: Pull?
    private var pendingCompletion: ((Result<TeamsCredentialSnapshot, Error>) -> Void)?
    private var saving = false
    private var pulled = false
    private let certificate: String
    private let serviceName: String
    private let beforePull: @Sendable () async -> Void
    private var operationID = UUID()

    public init(certificate: String, serviceName: String = "dev.native.teamschat.credential-service") throws {
        guard certificate.range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil,
              serviceName == "dev.native.teamschat.credential-service" else { throw TeamsCredentialBridgeError.invalidInput }
        self.certificate = certificate; self.serviceName = serviceName; self.beforePull = {}
    }
    init(certificate: String, beforePull: @escaping @Sendable () async -> Void) throws {
        guard certificate.range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil else { throw TeamsCredentialBridgeError.invalidInput }
        self.certificate = certificate; self.serviceName = "dev.native.teamschat.credential-service"; self.beforePull = beforePull
    }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let id = UUID(); connectionID = id
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.setCodeSigningRequirement("identifier \"dev.native.teamschat.credential-service\" and certificate leaf = H\"\(certificate)\"")
        connection.remoteObjectInterface = NSXPCInterface(with: TeamsCredentialServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: TeamsCredentialPull.self)
        let endpoint = PullEndpoint(connectionID: id, owner: self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.invalidated(id) } }
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.invalidated(id) } }
        self.endpoint = endpoint; self.connection = connection
        connection.resume()
        return connection
    }

    fileprivate func consume(intent: String, accountScope: String, sessionID: String, connectionID: UUID) async -> Data? {
        await beforePull()
        guard let pending = pendingPull, pending.intent == intent, pending.scope == accountScope, pending.sessionID == sessionID,
              pending.connectionID == connectionID, pending.connectionID == self.connectionID,
              pending.generation == generation else { return nil }
        pendingPull = nil; pulled = true
        return pending.data
    }

    private func invalidated(_ id: UUID) {
        guard id == connectionID else { return }
        let old = connection
        connection = nil; endpoint = nil; pendingPull = nil; connectionID = UUID(); generation = UUID()
        old?.invalidate()
        finish(.failure(saving && pulled ? TeamsCredentialBridgeError.outcomeUnknown : .unavailable))
    }
    private func finish(_ result: Result<TeamsCredentialSnapshot, Error>) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil; pendingPull = nil; operationID = UUID(); saving = false; pulled = false
        completion(result)
    }
    public func cancelPending() {
        generation = UUID(); pendingPull = nil
        finish(.failure(saving && pulled ? TeamsCredentialBridgeError.outcomeUnknown : .cancelled))
        connection?.invalidate(); connection = nil; endpoint = nil; connectionID = UUID()
    }
    private func validScope(_ scope: String) -> Bool {
        let parts = scope.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { UUID(uuidString: String($0)) != nil }
    }
    public func load(scope: String) async throws -> TeamsCredentialSnapshot {
        guard validScope(scope), pendingCompletion == nil else { throw TeamsCredentialBridgeError.invalidInput }
        return try await perform { proxy, done in
            proxy.load(accountScope: scope) { data, version, session, protocolStatus, securityStatus in done(data, version, session, protocolStatus, securityStatus) }
        }
    }
    public func begin(scope: String, expectedVersion: String) async throws -> TeamsCredentialSnapshot {
        guard validScope(scope), !expectedVersion.isEmpty, pendingCompletion == nil else { throw TeamsCredentialBridgeError.invalidInput }
        return try await perform { proxy, done in
            proxy.begin(accountScope: scope, expectedVersion: expectedVersion) { version, session, protocolStatus, securityStatus in done(nil, version, session, protocolStatus, securityStatus) }
        }
    }
    public func save(_ data: Data, scope: String, sessionID: String, expectedVersion: String) async throws -> TeamsCredentialSnapshot {
        guard validScope(scope), UUID(uuidString: sessionID) != nil, !data.isEmpty, data.count <= 100_000,
              !expectedVersion.isEmpty, pendingCompletion == nil else { throw TeamsCredentialBridgeError.invalidInput }
        let intent = UUID().uuidString
        let current = connect()
        pendingPull = Pull(intent: intent, scope: scope, sessionID: sessionID, connectionID: connectionID, generation: generation, data: data)
        saving = true; pulled = false
        return try await perform(using: current) { proxy, done in
            proxy.save(intent: intent, accountScope: scope, sessionID: sessionID, expectedVersion: expectedVersion) { version, protocolStatus, securityStatus in done(nil, version, sessionID, protocolStatus, securityStatus) }
        }
    }
    public func revoke(scope: String, sessionID: String) async throws -> TeamsCredentialSnapshot {
        guard validScope(scope), UUID(uuidString: sessionID) != nil, pendingCompletion == nil else { throw TeamsCredentialBridgeError.invalidInput }
        return try await perform { proxy, done in
            proxy.revoke(accountScope: scope, sessionID: sessionID) { version, protocolStatus, securityStatus in done(nil, version, nil, protocolStatus, securityStatus) }
        }
    }
    private func protocolError(_ raw: Int32) -> TeamsCredentialBridgeError? {
        guard let value = TeamsCredentialProtocolStatus(rawValue: raw) else { return .invalidInput }
        switch value {
        case .success: return nil
        case .invalidRequest: return .invalidInput
        case .stale: return .stale
        case .scopeMismatch: return .scopeMismatch
        case .revoked: return .revoked
        case .unavailable: return .unavailable
        }
    }
    private func perform(using supplied: NSXPCConnection? = nil,
                         _ invoke: (TeamsCredentialServiceProtocol, @escaping @Sendable (Data?, String, String?, Int32, Int32) -> Void) -> Void) async throws -> TeamsCredentialSnapshot {
        let current = supplied ?? connect()
        let id = connectionID, operation = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingCompletion = { continuation.resume(with: $0) }; operationID = operation
                if Task.isCancelled { cancelPending(); return }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, self.connectionID == id, self.operationID == operation else { return }
                    self.cancelPending()
                }
                guard let proxy = current.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.connectionID == id, self.operationID == operation else { return }
                        self.finish(.failure(self.saving && self.pulled ? TeamsCredentialBridgeError.outcomeUnknown : .unavailable))
                    }
                }) as? TeamsCredentialServiceProtocol else { finish(.failure(TeamsCredentialBridgeError.unavailable)); return }
                invoke(proxy) { [weak self] data, version, sessionID, protocolStatus, securityStatus in
                    Task { @MainActor in
                        guard let self, self.connectionID == id, self.operationID == operation else { return }
                        if let failure = self.protocolError(protocolStatus) { self.finish(.failure(failure)) }
                        else if securityStatus != errSecSuccess { self.finish(.failure(TeamsCredentialBridgeError.keychain(securityStatus))) }
                        else if version.isEmpty || version.count > 128 || (data?.count ?? 0) > 100_000 || (sessionID != nil && UUID(uuidString: sessionID!) == nil) {
                            self.finish(.failure(TeamsCredentialBridgeError.invalidInput))
                        } else { self.finish(.success(TeamsCredentialSnapshot(data: data, version: version, sessionID: sessionID))) }
                    }
                }
            }
        } onCancel: { [weak self] in Task { @MainActor in if self?.operationID == operation { self?.cancelPending() } } }
    }
}
