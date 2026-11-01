import Foundation

public enum TeamsCredentialProtocolStatus: Int32 {
    case success = 0, invalidRequest = 1, stale = 2, scopeMismatch = 3, revoked = 4, unavailable = 5
}

@objc public protocol TeamsCredentialPull {
    func fetch(intent: String, accountScope: String, sessionID: String, reply: @escaping @Sendable (Data?) -> Void)
}

@objc public protocol TeamsCredentialServiceProtocol {
    func load(accountScope: String, reply: @escaping @Sendable (Data?, String, String?, Int32, Int32) -> Void)
    func begin(accountScope: String, expectedVersion: String, reply: @escaping @Sendable (String, String?, Int32, Int32) -> Void)
    func save(intent: String, accountScope: String, sessionID: String, expectedVersion: String, reply: @escaping @Sendable (String, Int32, Int32) -> Void)
    func revoke(accountScope: String, sessionID: String, reply: @escaping @Sendable (String, Int32, Int32) -> Void)
}

@objc public protocol TeamsCredentialTestServiceProtocol: TeamsCredentialServiceProtocol {
    func configureFault(_ name: String, reply: @escaping @Sendable (Bool) -> Void)
    func disposeTestRecord(reply: @escaping @Sendable (Int32) -> Void)
}
