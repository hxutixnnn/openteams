import Foundation
import Security
import TeamsCore
import TeamsCredentialBridge

/// Uses the helper's logical session and revision; never retries an uncertain save.
@MainActor public final class TeamsHelperCredentialAccess: TeamsCredentialAccess {
    private let bridge: TeamsCredentialBridge
    private let defaults: UserDefaults
    private var scope: String?
    private var snapshot: TeamsCredentialSnapshot?
    private var generation = UUID()
    private var uncertain = false
    private var persistedData: Data?
    private let recoveryKey = "teamsCredentialRecoveryScopes"

    public init(bridge: TeamsCredentialBridge, defaults: UserDefaults = .standard) {
        self.bridge = bridge; self.defaults = defaults
        if let saved = defaults.stringArray(forKey: recoveryKey)?.first { scope = saved }
        else if let account = defaults.string(forKey: "teamsAccountID"), let tenant = defaults.string(forKey: "teamsTenantID"),
           UUID(uuidString: account) != nil, UUID(uuidString: tenant) != nil { scope = tenant + ":" + account }
    }

    public func invalidate() { generation = UUID(); bridge.cancelPending() }

    private func map(_ error: Error) -> Error {
        guard let error = error as? TeamsCredentialBridgeError else { return error }
        switch error {
        case .keychain(let status) where status == errSecInteractionNotAllowed || status == errSecAuthFailed:
            return TeamsCredentialError.interactionRequired
        case .outcomeUnknown: return TeamsCredentialError.outcomeUnknown
        default: return error
        }
    }

    public func load(interactive: Bool) async throws -> TeamsCredentials? {
        let candidates = (defaults.stringArray(forKey: recoveryKey) ?? scope.map { [$0] } ?? []).filter { candidate in
            let parts = candidate.split(separator: ":", omittingEmptySubsequences: false)
            return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && UUID(uuidString: String(parts[1])) != nil
        }
        let current = generation
        for candidate in candidates {
            do {
                let loaded = try await bridge.load(scope: candidate)
                guard current == generation else { throw CancellationError() }
                guard let data = loaded.data else { snapshot = loaded; scope = candidate; persistedData = nil; uncertain = false; return nil }
                let credentials = try JSONDecoder().decode(TeamsCredentials.self, from: data)
                let session = try TeamsSessionHandoff.decode(credentials.handoff, at: .distantPast)
                guard session.tenantID + ":" + session.accountID == candidate else { throw TeamsCredentialBridgeError.scopeMismatch }
                snapshot = loaded; scope = candidate; persistedData = data; uncertain = false
                defaults.set([candidate], forKey: recoveryKey)
                return credentials
            } catch TeamsCredentialBridgeError.scopeMismatch { continue }
            catch { throw map(error) }
        }
        if !candidates.isEmpty { throw TeamsCredentialBridgeError.scopeMismatch }
        return nil
    }

    public func save(_ credentials: TeamsCredentials) async throws {
        guard !uncertain else { throw TeamsCredentialError.outcomeUnknown }
        let identity = try TeamsSessionHandoff.decode(credentials.handoff, at: .distantPast)
        let target = identity.tenantID + ":" + identity.accountID
        let current = generation
        do {
            if snapshot == nil, scope != nil {
                _ = try await load(interactive: false)
                guard current == generation else { throw CancellationError() }
            }
            let candidates = [target] + (scope.map { $0 == target ? [] : [$0] } ?? [])
            defaults.set(candidates, forKey: recoveryKey)
            if let oldScope = scope, oldScope != target {
                let old = try await bridge.load(scope: oldScope)
                guard current == generation else { throw CancellationError() }
                if let oldSession = old.sessionID { _ = try await bridge.revoke(scope: oldScope, sessionID: oldSession) }
                guard current == generation else { throw CancellationError() }
                snapshot = nil; scope = nil; persistedData = nil
            }
            var state: TeamsCredentialSnapshot
            if scope == target, let snapshot { state = snapshot }
            else {
                state = try await bridge.load(scope: target)
                guard current == generation else { throw CancellationError() }
                scope = target; snapshot = state; persistedData = state.data
            }
            if state.sessionID == nil {
                do { state = try await bridge.begin(scope: target, expectedVersion: state.version) }
                catch TeamsCredentialBridgeError.stale {
                    guard current == generation else { throw CancellationError() }
                    let latest = try await bridge.load(scope: target)
                    guard current == generation, latest.data == nil else { throw TeamsCredentialBridgeError.stale }
                    if latest.sessionID != nil { state = latest }
                    else {
                        do { state = try await bridge.begin(scope: target, expectedVersion: latest.version) }
                        catch let error as TeamsCredentialBridgeError {
                            guard current == generation else { throw CancellationError() }
                            switch error {
                            case .unavailable, .cancelled, .outcomeUnknown:
                                uncertain = true; throw TeamsCredentialError.outcomeUnknown
                            default: throw error
                            }
                        }
                    }
                }
                catch let error as TeamsCredentialBridgeError {
                    guard current == generation else { throw CancellationError() }
                    switch error {
                    case .unavailable, .cancelled, .outcomeUnknown:
                        uncertain = true; throw TeamsCredentialError.outcomeUnknown
                    default: throw error
                    }
                }
                guard current == generation else { throw CancellationError() }
                snapshot = state
            }
            guard let sessionID = state.sessionID else { throw TeamsCredentialBridgeError.invalidInput }
            let data = try JSONEncoder().encode(credentials)
            do { state = try await bridge.save(data, scope: target, sessionID: sessionID, expectedVersion: state.version) }
            catch TeamsCredentialBridgeError.stale {
                guard current == generation else { throw CancellationError() }
                let latest = try await bridge.load(scope: target)
                guard current == generation else { throw CancellationError() }
                guard latest.sessionID == sessionID, latest.data == persistedData else { throw TeamsCredentialBridgeError.stale }
                do { state = try await bridge.save(data, scope: target, sessionID: sessionID, expectedVersion: latest.version) }
                catch TeamsCredentialBridgeError.outcomeUnknown {
                    guard current == generation else { throw CancellationError() }
                    uncertain = true; throw TeamsCredentialError.outcomeUnknown
                }
            }
            catch TeamsCredentialBridgeError.outcomeUnknown {
                guard current == generation else { throw CancellationError() }
                uncertain = true; throw TeamsCredentialError.outcomeUnknown
            }
            guard current == generation else { throw CancellationError() }
            snapshot = state; scope = target; persistedData = data
            defaults.set([target], forKey: recoveryKey)
        } catch { throw map(error) }
    }

    public func delete() async throws {
        let candidates = defaults.stringArray(forKey: recoveryKey) ?? scope.map { [$0] } ?? []
        let current = generation
        do {
            var matched = candidates.isEmpty
            if let knownScope = scope, let sessionID = snapshot?.sessionID {
                do { _ = try await bridge.revoke(scope: knownScope, sessionID: sessionID) }
                catch let error as TeamsCredentialBridgeError where error == .scopeMismatch || error == .revoked || error == .stale {
                    guard current == generation else { throw CancellationError() }
                    let latest = try await bridge.load(scope: knownScope)
                    guard current == generation else { throw CancellationError() }
                    guard latest.sessionID == nil, latest.data == nil else { throw error }
                }
                guard current == generation else { throw CancellationError() }
                matched = true
            }
            for candidate in matched ? [] : candidates {
                do {
                    let state = try await bridge.load(scope: candidate)
                    matched = true
                    guard current == generation else { throw CancellationError() }
                    if let sessionID = state.sessionID { _ = try await bridge.revoke(scope: candidate, sessionID: sessionID) }
                    guard current == generation else { throw CancellationError() }
                    break
                } catch TeamsCredentialBridgeError.scopeMismatch { continue }
            }
            guard current == generation else { throw CancellationError() }
            guard matched else { throw TeamsCredentialBridgeError.scopeMismatch }
            snapshot = nil; self.scope = nil; persistedData = nil; uncertain = false
            defaults.removeObject(forKey: recoveryKey)
        } catch { throw map(error) }
    }
}
