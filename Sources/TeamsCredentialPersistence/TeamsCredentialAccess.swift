import Foundation

public struct TeamsCredentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var handoff: Data
    public var refreshToken: String?
    public init(handoff: Data, refreshToken: String?) { self.handoff = handoff; self.refreshToken = refreshToken }
    public var description: String { "TeamsCredentials(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["credentials": "<redacted>"]) }
}

public enum TeamsCredentialError: Error { case interactionRequired, outcomeUnknown }

@MainActor public protocol TeamsCredentialAccess {
    func load(interactive: Bool) async throws -> TeamsCredentials?
    func save(_ credentials: TeamsCredentials) async throws
    func delete() async throws
    func invalidate()
}

public extension TeamsCredentialAccess { func invalidate() {} }
