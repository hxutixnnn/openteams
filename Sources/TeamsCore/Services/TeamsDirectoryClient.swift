import Foundation

public struct TeamsDirectorySession: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
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
              components.percentEncodedPath.range(of: "^/api/mt/[a-z0-9]+(?:-[a-z0-9]+)*/?$", options: .regularExpression) != nil else {
            throw TeamsWebClientError.unsafeBaseURL
        }
        guard !accessToken.isEmpty, accessToken.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw TeamsWebClientError.invalidSession
        }
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite, expiresAt > now else {
            throw TeamsWebClientError.expiredSession
        }
    }

    public var description: String { "TeamsDirectorySession(accessToken: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["accessToken": "<redacted>"]) }
}

public struct TeamsDirectoryPerson: Codable, Identifiable, Hashable, Sendable {
    public let mri: String?
    public let objectId: String?
    public let displayName: String?
    public let userPrincipalName: String?
    public let email: String?
    public let type: String?
    public let userType: String?
    public let tenantId: String?

    public var id: String { mri ?? objectId ?? userPrincipalName ?? email ?? "" }
    public var title: String { displayName ?? userPrincipalName ?? email ?? "Teams user" }

    public init(mri: String? = nil, objectId: String? = nil, displayName: String? = nil,
                userPrincipalName: String? = nil, email: String? = nil, type: String? = nil,
                userType: String? = nil, tenantId: String? = nil) {
        self.mri = mri
        self.objectId = objectId
        self.displayName = displayName
        self.userPrincipalName = userPrincipalName
        self.email = email
        self.type = type
        self.userType = userType
        self.tenantId = tenantId
    }
}

public struct TeamsDirectorySearchOptions: Sendable {
    public var includeGuests: Bool
    public var includeBots: Bool

    public init(includeGuests: Bool = true, includeBots: Bool = false) {
        self.includeGuests = includeGuests
        self.includeBots = includeBots
    }
}

public enum TeamsDirectoryError: Error, LocalizedError, Equatable, Sendable {
    case queryTooLong

    public var errorDescription: String? { "The people search is too long. Enter a name or email address." }
}

public struct TeamsDirectoryClient: Sendable {
    private let session: TeamsDirectorySession
    private let transport: any HTTPTransport

    public init(session: TeamsDirectorySession, transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    public func searchUsers(_ query: String, options: TeamsDirectorySearchOptions = .init()) async throws -> [TeamsDirectoryPerson] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard query.utf8.count <= 1_024 else { throw TeamsDirectoryError.queryTooLong }
        try session.validate()
        try Task.checkCancellation()
        var components = URLComponents(url: session.baseURL, resolvingAgainstBaseURL: false)!
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + "/beta/users/searchV2"
        components.queryItems = [
            .init(name: "includeDLs", value: "false"),
            .init(name: "enableGuest", value: String(options.includeGuests)),
            .init(name: "includeBots", value: String(options.includeBots)),
            .init(name: "skypeTeamsInfo", value: "true"),
            .init(name: "source", value: "allTrue")
        ]
        guard let url = components.url else { throw TeamsWebClientError.unsafeBaseURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "clientRequestId")
        request.httpBody = Data(query.utf8)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw TeamsWebClientError.network }
        guard (200..<300).contains(response.statusCode) else {
            throw TeamsWebClientError.http(status: response.statusCode,
                                           retryAfter: TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        }
        struct Result: Decodable { let value: [TeamsDirectoryPerson] }
        guard let result = try? JSONDecoder().decode(Result.self, from: data) else { throw TeamsWebClientError.invalidResponse }
        return result.value.filter { !$0.id.isEmpty }
    }
}
