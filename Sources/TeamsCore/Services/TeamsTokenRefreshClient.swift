import Foundation

public struct TeamsTokenRefreshResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: TimeInterval
    public let scope: String?
    public var description: String { "TeamsTokenRefreshResponse(credentials: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["credentials": "<redacted>"]) }
}

public enum TeamsTokenRefreshError: Error, Equatable, Sendable {
    case invalidInput
    case interactionRequired
    case http(status: Int, retryAfter: TimeInterval?)
    case invalidResponse
    case network
}

public struct TeamsFileTokenRefreshResponse: Sendable, CustomStringConvertible, CustomReflectable {
    public let accessToken: String?
    public let refreshToken: String?
    public let expiresIn: TimeInterval?
    public let scope: String?
    public var description: String { "TeamsFileTokenRefreshResponse(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["credentials": "<redacted>"]) }
}

public struct TeamsTokenRefreshClient: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = TeamsWebURLSessionTransport()) { self.transport = transport }

    public func refresh(tenantID: String, refreshToken: String, resource: String, at now: Date = Date()) async throws -> TeamsTokenRefreshResponse {
        let allowedResources = ["https://chatsvcagg.teams.microsoft.com/.default", "https://ic3.teams.office.com/.default",
                                "https://outlook.office.com//.default", "https://api.spaces.skype.com/.default"]
        guard let tenant = UUID(uuidString: tenantID), !refreshToken.isEmpty, allowedResources.contains(resource) else {
            throw TeamsTokenRefreshError.invalidInput
        }
        return try await exchange(tenant: tenant, refreshToken: refreshToken, resource: resource, at: now)
    }

    public func refreshSharePoint(tenantID: String, refreshToken: String, resource: TeamsSharePointResource, at now: Date = Date()) async throws -> TeamsFileTokenRefreshResponse {
        guard let tenant = UUID(uuidString: tenantID), !refreshToken.isEmpty else { throw TeamsTokenRefreshError.invalidInput }
        let result = try await exchangeRaw(tenant: tenant, refreshToken: refreshToken, resource: resource.origin + "/.default", at: now)
        return TeamsFileTokenRefreshResponse(accessToken: result["access_token"] as? String, refreshToken: result["refresh_token"] as? String,
                                             expiresIn: result["expires_in"] as? Double, scope: result["scope"] as? String)
    }

    private func exchange(tenant: UUID, refreshToken: String, resource: String, at now: Date) async throws -> TeamsTokenRefreshResponse {
        let result = try await exchangeRaw(tenant: tenant, refreshToken: refreshToken, resource: resource, at: now)
        guard let access = result["access_token"] as? String, !access.isEmpty,
              let lifetime = result["expires_in"] as? Double, lifetime.isFinite, lifetime > 0 else {
            throw TeamsTokenRefreshError.invalidResponse
        }
        return TeamsTokenRefreshResponse(accessToken: access, refreshToken: result["refresh_token"] as? String, expiresIn: lifetime, scope: result["scope"] as? String)
    }

    private func exchangeRaw(tenant: UUID, refreshToken: String, resource: String, at now: Date) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(tenant.uuidString.lowercased())/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://teams.cloud.microsoft", forHTTPHeaderField: "Origin")
        request.httpShouldHandleCookies = false
        let fields = [("client_id", "5e3ce6c0-2b1f-4285-8d4b-75ee78787346"),
                      ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("scope", resource)]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw TeamsTokenRefreshError.network }
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if response.statusCode != 200 {
            if ["invalid_grant", "interaction_required", "login_required"].contains(result["error"] as? String ?? "") {
                throw TeamsTokenRefreshError.interactionRequired
            }
            throw TeamsTokenRefreshError.http(status: response.statusCode,
                                               retryAfter: TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), at: now))
        }
        return result
    }
}

public struct TeamsSharePointResource: Hashable, Sendable {
    public let origin: String

    public init?(baseURL: URL, objectURL: URL) {
        func components(_ url: URL) -> URLComponents? {
            guard url.absoluteString.utf8.count <= 8192,
                  let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme?.lowercased() == "https",
                  let host = c.host?.lowercased(), host.hasSuffix(".sharepoint.com"), host != ".sharepoint.com",
                  host.range(of: "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\\.sharepoint\\.com$", options: .regularExpression) != nil,
                  c.port == nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
                  !c.percentEncodedPath.isEmpty else { return nil }
            return c
        }
        guard let base = components(baseURL), let object = components(objectURL),
              base.host?.lowercased() == object.host?.lowercased() else { return nil }
        origin = "https://" + base.host!.lowercased()
    }
}
