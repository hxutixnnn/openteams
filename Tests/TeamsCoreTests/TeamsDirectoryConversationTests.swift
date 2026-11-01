import Foundation
import Testing
@testable import TeamsCore

private actor DirectoryConversationTransport: HTTPTransport {
    struct Reply: Sendable {
        let status: Int
        var body = "{}"
        var headers: [String: String] = [:]
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply] = []) { self.replies = replies }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.timedOut) }
        let reply = replies.removeFirst()
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                                     httpVersion: "HTTP/2", headerFields: reply.headers)!)
    }
}

struct TeamsDirectoryConversationTests {
    private func directory(baseURL: String = "https://teams.cloud.microsoft/api/mt/amer", expired: Bool = false) -> TeamsDirectorySession {
        .init(baseURL: URL(string: baseURL)!, accessToken: "directory-test-token",
              expiresAt: Date().addingTimeInterval(expired ? -60 : 3_600))
    }

    private func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa-test-token",
              expiresAt: Date().addingTimeInterval(3_600), accountID: "self-user", tenantID: "test-tenant",
              displayName: "Test User", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!,
                                                        accessToken: "messaging-test-token", expiresAt: Date().addingTimeInterval(3_600)))
    }

    @Test func directorySearchUsesCapturedRawBodyAndDedicatedAudienceCredential() async throws {
        let transport = DirectoryConversationTransport([
            .init(status: 200, body: #"{"value":[{"mri":"8:orgid:other","objectId":"other","displayName":"Châu Nguyễn"}]}"#)
        ])
        let result = try await TeamsDirectoryClient(session: directory(), transport: transport).searchUsers("Châu Nguyễn + example")
        #expect(result.first?.title == "Châu Nguyễn")
        let requests = await transport.requests
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/mt/amer/beta/users/searchV2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer directory-test-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json;charset=UTF-8")
        #expect(request.httpBody == Data("Châu Nguyễn + example".utf8))
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "source" }?.value == "allTrue")
        #expect(query?.first { $0.name == "includeDLs" }?.value == "false")
    }

    @Test func directoryRejectsWrongOriginsAndExpiredCredentialsBeforeTransport() async throws {
        let transport = DirectoryConversationTransport()
        for base in ["https://attacker.test/api/mt/amer", "https://teams.cloud.microsoft.attacker.test/api/mt/amer",
                     "https://teams.cloud.microsoft/api/csa/amer", "https://teams.cloud.microsoft/api/mt/%2e%2e"] {
            do {
                _ = try await TeamsDirectoryClient(session: directory(baseURL: base), transport: transport).searchUsers("Person")
                Issue.record("Untrusted directory route accepted")
            } catch { #expect(error as? TeamsWebClientError == .unsafeBaseURL) }
        }
        do {
            _ = try await TeamsDirectoryClient(session: directory(expired: true), transport: transport).searchUsers("Person")
            Issue.record("Expired directory session accepted")
        } catch { #expect(error as? TeamsWebClientError == .expiredSession) }
        #expect(await transport.requests.isEmpty)
        #expect(try await TeamsDirectoryClient(session: directory(), transport: transport).searchUsers(" \n").isEmpty)
    }

    @Test func directChatIncludesSelfOnceAndRequestsUniqueRoster() async throws {
        let transport = DirectoryConversationTransport([
            .init(status: 201, headers: ["Location": "/api/chatsvc/amer/v1/threads/19%3Acreated%40thread.v2"])
        ])
        let result = try await TeamsConversationClient(session: session(), transport: transport)
            .createChat(with: [.init(id: "8:orgid:other"), .init(id: "8:orgid:self-user"), .init(id: "8:orgid:other")])
        #expect(result.threadID == "19:created@thread.v2")
        #expect(!result.hasPartialFailures)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/api/chatsvc/amer/v1/threads")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer messaging-test-token")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let members = try #require(body["members"] as? [[String: String]])
        #expect(members.map { $0["id"]! } == ["8:orgid:self-user", "8:orgid:other"])
        let properties = try #require(body["properties"] as? [String: Any])
        #expect(properties["threadType"] as? String == "chat")
        #expect(properties["fixedRoster"] as? Bool == true)
        #expect(properties["uniquerosterthread"] as? Bool == true)
    }

    @Test func groupChatPreservesGuestRolesAndSurfacesPartialCreation() async throws {
        let transport = DirectoryConversationTransport([
            .init(status: 207, body: #"{"policyResults":{"blocked":true}}"#, headers: ["Location": "https://teams.cloud.microsoft/api/chatsvc/amer/v1/threads/19:partial@thread.v2"])
        ])
        let result = try await TeamsConversationClient(session: session(), transport: transport)
            .createChat(with: [.init(id: "8:orgid:member"), .init(id: "8:orgid:guest", role: .guest)], title: " Project 👋 ")
        #expect(result.hasPartialFailures)
        #expect(result.responseBody != nil)
        let request = try #require(await transport.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let properties = try #require(body["properties"] as? [String: Any])
        #expect(properties["topic"] as? String == "Project 👋")
        #expect(properties["fixedRoster"] == nil)
        #expect(properties["uniquerosterthread"] == nil)
        #expect((body["members"] as? [[String: String]])?.last?["role"] == "Guest")
    }

    @Test func uncertainCreationIsNotRetried() async throws {
        for replies: [DirectoryConversationTransport.Reply] in [[], [.init(status: 503)], [.init(status: 201)]] {
            let transport = DirectoryConversationTransport(replies)
            do {
                _ = try await TeamsConversationClient(session: session(), transport: transport).createChat(with: [.init(id: "8:orgid:other")])
                Issue.record("Uncertain creation treated as confirmed")
            } catch { #expect(error as? TeamsConversationError == .creationOutcomeUnknown) }
            #expect(await transport.requests.count == 1)
        }
    }

    @Test func invalidRosterDoesNotCreateAChat() async throws {
        let transport = DirectoryConversationTransport()
        do {
            _ = try await TeamsConversationClient(session: session(), transport: transport).createChat(with: [])
            Issue.record("Empty roster submitted")
        } catch { #expect(error as? TeamsConversationError == .invalidMembers) }
        do {
            _ = try await TeamsConversationClient(session: session(), transport: transport)
                .createChat(with: (0..<200).map { .init(id: "8:orgid:user-\($0)") })
            Issue.record("Oversized initial roster submitted")
        } catch { #expect(error as? TeamsConversationError == .tooManyMembers) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func directorySessionCanPersistWithoutPrintingItsCredential() throws {
        let original = directory()
        let restored = try JSONDecoder().decode(TeamsDirectorySession.self, from: JSONEncoder().encode(original))
        #expect(restored.accessToken == original.accessToken)
        #expect(!String(describing: restored).contains(original.accessToken))
        #expect(!String(reflecting: restored).contains(original.accessToken))
    }
}
