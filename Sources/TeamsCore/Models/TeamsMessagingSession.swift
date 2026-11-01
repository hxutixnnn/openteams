import Foundation

public struct TeamsMessagingSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let baseURL: URL
    public let accessToken: String
    public let expiresAt: Date

    public init(baseURL: URL, accessToken: String, expiresAt: Date) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public func validate(at now: Date = Date()) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "teams.cloud.microsoft",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.range(of: "^/api/chatsvc/[a-z0-9]+(?:-[a-z0-9]+)*/?$", options: .regularExpression) != nil else {
            throw TeamsWebClientError.unsafeBaseURL
        }
        guard !accessToken.isEmpty, accessToken.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw TeamsWebClientError.invalidSession
        }
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite, expiresAt > now else {
            throw TeamsWebClientError.expiredSession
        }
    }

    public var description: String { "TeamsMessagingSession(accessToken: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["accessToken": "<redacted>"]) }
}
