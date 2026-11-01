import Foundation
import Testing
@testable import TeamsCore

private actor TokenTransport: HTTPTransport {
    let status: Int
    let body: Data
    let headers: [String: String]
    private(set) var requests: [URLRequest] = []
    init(status: Int, body: String, headers: [String: String] = [:]) {
        self.status = status; self.body = Data(body.utf8); self.headers = headers
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

struct TeamsTokenRefreshTests {
    private let tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let scope = "https://chatsvcagg.teams.microsoft.com/.default"

    @Test func encodesOpaqueCredentialAndReturnsRotation() async throws {
        let transport = TokenTransport(status: 200, body: #"{"access_token":"access","refresh_token":"rotated","expires_in":3600}"#)
        let result = try await TeamsTokenRefreshClient(transport: transport).refresh(tenantID: tenant, refreshToken: "a+b/c=", resource: scope)
        #expect(result.refreshToken == "rotated")
        #expect(result.expiresIn == 3600)
        #expect(!String(reflecting: result).contains("rotated"))
        #expect(!String(describing: Mirror(reflecting: result)).contains("access"))
        let request = try #require(await transport.requests.first)
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("refresh_token=a%2Bb%2Fc%3D"))
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://teams.cloud.microsoft")
        #expect(!request.httpShouldHandleCookies)
        #expect(await transport.requests.count == 1)
    }

    @Test func terminalAndThrottleResponsesAreDistinctAndNotRetried() async throws {
        let terminal = TokenTransport(status: 400, body: #"{"error":"invalid_grant"}"#)
        do { _ = try await TeamsTokenRefreshClient(transport: terminal).refresh(tenantID: tenant, refreshToken: "secret", resource: scope); Issue.record("Expected interaction") }
        catch { #expect(error as? TeamsTokenRefreshError == .interactionRequired) }
        let throttled = TokenTransport(status: 429, body: "{}", headers: ["Retry-After": "300"])
        do { _ = try await TeamsTokenRefreshClient(transport: throttled).refresh(tenantID: tenant, refreshToken: "secret", resource: scope); Issue.record("Expected throttle") }
        catch { #expect(error as? TeamsTokenRefreshError == .http(status: 429, retryAfter: 300)) }
        #expect(await terminal.requests.count == 1)
        #expect(await throttled.requests.count == 1)
    }

    @Test func searchRefreshPreservesResourceTrailingSlash() async throws {
        let transport = TokenTransport(status: 200, body: #"{"access_token":"access","refresh_token":"rotated","expires_in":3600}"#)
        _ = try await TeamsTokenRefreshClient(transport: transport).refresh(tenantID: tenant, refreshToken: "secret", resource: "https://outlook.office.com//.default")
        let request = try #require(await transport.requests.first)
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("https%3A%2F%2Foutlook.office.com%2F%2F.default"))
    }

    @Test func unsafeTenantAndResourceNeverReachTransport() async throws {
        let transport = TokenTransport(status: 200, body: "{}")
        do { _ = try await TeamsTokenRefreshClient(transport: transport).refresh(tenantID: "evil.invalid", refreshToken: "secret", resource: scope); Issue.record("Unsafe tenant") }
        catch { #expect(error as? TeamsTokenRefreshError == .invalidInput) }
        do { _ = try await TeamsTokenRefreshClient(transport: transport).refresh(tenantID: tenant, refreshToken: "secret", resource: "https://evil.invalid/.default"); Issue.record("Unsafe scope") }
        catch { #expect(error as? TeamsTokenRefreshError == .invalidInput) }
        #expect(await transport.requests.isEmpty)
    }
}
