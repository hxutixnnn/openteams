import Foundation
import Testing
@testable import TeamsCore

private actor SearchTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let status: Int
    let body: String
    let headers: [String: String]
    let failure: URLError?

    init(status: Int = 200, body: String = #"{"EntitySets":[]}"#,
         headers: [String: String] = [:], failure: URLError? = nil) {
        self.status = status; self.body = body; self.headers = headers; self.failure = failure
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

struct TeamsSearchTests {
    private func session(base: String = "https://substrate.office.com", expiry: Date = .distantFuture,
                         migrated: Bool = false) -> TeamsSearchSession {
        .init(baseURL: URL(string: base)!, accessToken: "outlook-test-secret", expiresAt: expiry,
              accountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", tenantID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
              useMigratedEndpoint: migrated)
    }

    @Test func constructsRecoveredMessageSearchBodyAndScopeWithoutCookies() async throws {
        let transport = SearchTransport()
        let query = #"Xin chào 👋 "quoted" OR clientconversationid:other"#
        _ = try await TeamsSearchClient(session: session(), transport: transport)
            .searchMessages(query: query, in: "48:notes", page: 2, pageSize: 10)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://substrate.office.com/search/api/v2/query")
        #expect(!request.httpShouldHandleCookies)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer outlook-test-secret")
        #expect(request.value(forHTTPHeaderField: "x-anchormailbox") == "OID:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa@bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: #require(request.httpBody))
        guard case let .array(entities)? = body["entityRequests"], case let .object(entity)? = entities.first,
              case let .object(queryBody)? = entity["query"] else { Issue.record("Missing message search body"); return }
        #expect(entity["entityType"] == .string("Message"))
        #expect(entity["contentSources"] == .array([.string("Teams")]))
        #expect(entity["from"] == .number(20))
        #expect(entity["size"] == .number(10))
        #expect(queryBody["displayQueryString"] == .string(query))
        #expect(queryBody["queryString"] == .string(#"clientconversationid:"48:notes" AND "Xin chào 👋 \"quoted\" OR clientconversationid:other" AND NOT (isClientSoftDeleted:TRUE)"#))
    }

    @Test func unscopedAndMigratedQueriesUseTheirExplicitBoundaries() async throws {
        let transport = SearchTransport()
        _ = try await TeamsSearchClient(session: session(base: "https://teams.microsoft.com/", migrated: true), transport: transport)
            .searchMessages(query: "planning")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://teams.microsoft.com/searchservice/api/v2/query")
        #expect(request.value(forHTTPHeaderField: "X-RoutingParameter-SessionKey") == "OID:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa@bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let data = try #require(request.httpBody)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("clientconversationid"))
    }

    @Test func mapsServerResultsWithoutConfusingHitIDsWithMessageIDs() async throws {
        let transport = SearchTransport(body: #"{"EntitySets":[{"EntityType":"Message","ResultSets":[{"Total":2,"MoreResultsAvailable":true,"Results":[{"Id":"ews-hit","ReferenceId":"ref","Source":{"InternetMessageId":9007199254740993,"ClientConversationId":"19:example@thread.v2;messageid=reply","Preview":"Hello <b>world</b> \uE000API\uE001<script>bad()</script>","DateTimeSent":"2026-10-31T08:00:00Z","ConversationTopic":"Project","Sender":{"EmailAddress":{"Name":"Example Person","Address":"example@example.invalid"}},"Extensions":{"SkypeSpaces_ConversationPost_Extension_FromSkypeInternalId":"8:orgid:example"}}},{"Id":"ews-hit","Source":{"Preview":"Duplicate"}}]}]}]}"#)
        let page = try await TeamsSearchClient(session: session(), transport: transport).searchMessages(query: "API")
        #expect(page.total == 2)
        #expect(page.hasMore)
        #expect(page.results.count == 1)
        let result = try #require(page.results.first)
        #expect(result.id == "ews-hit")
        #expect(result.messageID == "9007199254740993")
        #expect(result.chatID == "19:example@thread.v2")
        #expect(result.preview == "Hello world API")
        #expect(result.senderName == "Example Person")
        #expect(result.senderID == "8:orgid:example")
        #expect(result.conversationTitle == "Project")
    }

    @Test func refusesUnsafeDestinationsAndExpiredCredentialsBeforeTransport() async throws {
        let transport = SearchTransport()
        for base in ["http://substrate.office.com", "https://substrate.office.com.attacker.invalid",
                     "https://user@substrate.office.com", "https://substrate.office.com:444",
                     "https://substrate.office.com/other", "https://substrate.office.com?token=secret",
                     "https://teams.cloud.microsoft/api/csa/amer"] {
            do {
                _ = try await TeamsSearchClient(session: session(base: base), transport: transport).searchMessages(query: "hello")
                Issue.record("Unsafe search service accepted")
            } catch { #expect(error as? TeamsSearchError == .unsafeServiceAddress) }
        }
        do {
            _ = try await TeamsSearchClient(session: session(expiry: .distantPast), transport: transport).searchMessages(query: "hello")
            Issue.record("Expired search session accepted")
        } catch { #expect(error as? TeamsSearchError == .expiredSession) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func invalidQueriesAndPagesDoNotIssueRequests() async throws {
        let transport = SearchTransport()
        let client = TeamsSearchClient(session: session(), transport: transport)
        for query in [" \n", String(repeating: "x", count: 4_097)] {
            do { _ = try await client.searchMessages(query: query); Issue.record("Invalid query accepted") }
            catch { #expect(error as? TeamsSearchError == .invalidQuery) }
        }
        for (page, size) in [(-1, 10), (1_001, 10), (0, 0), (0, 51)] {
            do { _ = try await client.searchMessages(query: "hello", page: page, pageSize: size); Issue.record("Invalid page accepted") }
            catch { #expect(error as? TeamsSearchError == .invalidPage) }
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func httpErrorsAreSanitizedAndDoNotRetry() async throws {
        let transport = SearchTransport(status: 429, body: "server-sensitive-content", headers: ["Retry-After": "300"])
        do {
            _ = try await TeamsSearchClient(session: session(), transport: transport).searchMessages(query: "hello")
            Issue.record("Failed search accepted")
        } catch {
            #expect(error as? TeamsSearchError == .http(status: 429, retryAfter: 300))
            #expect(!error.localizedDescription.contains("server-sensitive-content"))
            #expect(!error.localizedDescription.contains("outlook-test-secret"))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func invalidResponsesAndCancellationRemainDistinctFromNoResults() async throws {
        let malformed = SearchTransport(body: #"{"unexpected":true}"#)
        do {
            _ = try await TeamsSearchClient(session: session(), transport: malformed).searchMessages(query: "hello")
            Issue.record("Malformed search response accepted")
        } catch { #expect(error as? TeamsSearchError == .invalidResponse) }
        let cancelled = SearchTransport(failure: URLError(.cancelled))
        do {
            _ = try await TeamsSearchClient(session: session(), transport: cancelled).searchMessages(query: "hello")
            Issue.record("Cancelled search accepted")
        } catch { #expect(error is CancellationError) }
        var diagnostic = ""
        dump(session(), to: &diagnostic)
        #expect(!diagnostic.contains("outlook-test-secret"))
    }
}
