import Foundation
import TeamsCore

private actor SearchTransport: HTTPTransport {
    struct SearchRequest: Sendable {
        let query: String
        let from: Int
        let size: Int
        let mailbox: String
    }

    private(set) var requests: [SearchRequest] = []
    private var nextStatus = 200
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var horizon = "1;1;0"

    func respond(status: Int = 200, hold: Bool = false) {
        nextStatus = status
        holdNext = hold
    }

    func waitForHeldRequest() async {
        if held == nil { await withCheckedContinuation { waiting = $0 } }
    }

    func release() {
        held?.resume()
        held = nil
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.hasSuffix("/chats") {
            return (Data("{\"items\":[]}".utf8), reply(url))
        }
        if url.path.hasSuffix("/chats/older-chat") {
            return (Data(#"{"id":"older-chat","title":"Older chat","isRead":false}"#.utf8), reply(url))
        }
        if url.path.hasSuffix("/chats/older-chat/messages") {
            let message = TeamsWebMessage(id: "1800000000002", content: "Second match", messageType: "Text", originalArrivalTime: "1800000000002")
            return (try JSONEncoder().encode(TeamsWebMessagePage(messages: [message])), reply(url))
        }
        if url.path.hasSuffix("/conversations/older-chat/properties"), request.httpMethod == "PUT",
           let body = request.httpBody {
            let fields = try JSONDecoder().decode([String: String].self, from: body)
            guard let updated = fields["consumptionhorizon"] else { throw URLError(.unsupportedURL) }
            horizon = updated
            return (Data("{}".utf8), reply(url))
        }
        if url.path.hasSuffix("/conversations/older-chat") {
            let data = try JSONSerialization.data(withJSONObject: ["id": "older-chat", "properties": [
                "consumptionhorizon": horizon, "consumptionHorizonBookmark": "0;1;0"
            ]])
            return (data, reply(url))
        }
        guard request.httpMethod == "POST", url.host == "substrate.office.com", url.path == "/search/api/v2/query",
              let body = request.httpBody,
              let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let entity = (root["entityRequests"] as? [[String: Any]])?.first,
              entity["contentSources"] as? [String] == ["Teams"], entity["entityType"] as? String == "Message",
              let query = (entity["query"] as? [String: Any])?["queryString"] as? String,
              let from = entity["from"] as? Int, let size = entity["size"] as? Int,
              let mailbox = request.value(forHTTPHeaderField: "x-anchormailbox") else { throw URLError(.unsupportedURL) }
        requests.append(.init(query: query, from: from, size: size, mailbox: mailbox))
        let status = nextStatus
        nextStatus = 200
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                held = continuation
                waiting?.resume()
                waiting = nil
            }
        }
        if status == 429 { return (Data(), reply(url, status: status, headers: ["Retry-After": "60"])) }
        let hits: [[String: Any]] = from == 0
            ? [["Id": "hit-a", "Source": ["InternetMessageId": "1800000000001", "ClientThreadId": "newer-chat;messageid=1800000000001", "Preview": "First match"]],
               ["Id": "hit-b", "Source": ["InternetMessageId": 1_800_000_000_002 as Int64, "ClientConversationId": "older-chat", "Preview": "Second match"]]]
            : [["Id": "hit-c", "Source": ["InternetMessageId": "1800000000003", "ClientConversationId": "older-chat", "Preview": "Next page"]]]
        let bodyData = try JSONSerialization.data(withJSONObject: ["EntitySets": [["ResultSets": [
            ["Total": 3, "MoreResultsAvailable": from == 0, "Results": hits]
        ]]]])
        return (bodyData, reply(url))
    }

    private func reply(_ url: URL, status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
}

@main struct GlobalMessageSearch {
    private static let accountA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private static let accountB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private static let tenant = "cccccccc-cccc-cccc-cccc-cccccccccccc"

    private static func session(_ account: String, searchAccount: String? = nil) -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fixture", expiresAt: .distantFuture,
              accountID: account, tenantID: tenant, displayName: "Fixture",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fixture", expiresAt: .distantFuture),
              searchSession: .init(accessToken: "fixture", expiresAt: .distantFuture, accountID: searchAccount ?? account, tenantID: tenant))
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SearchTransport()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session(accountA))
        let first = try await store.searchServer("  budget  ")
        let next = try await store.searchServer("budget", page: 1)
        precondition(first.hasMore && !next.hasMore && first.total == 3 && next.total == 3)
        precondition(first.results.map(\.id) == ["hit-a", "hit-b"] && next.results.map(\.id) == ["hit-c"])
        precondition(first.results.compactMap(\.chatID) == ["newer-chat", "older-chat"])
        precondition(first.results.compactMap(\.messageID) == ["1800000000001", "1800000000002"])
        precondition(next.results.first?.chatID == "older-chat" && next.results.first?.messageID == "1800000000003")
        let initialRequests = await transport.requests
        precondition(initialRequests.map(\.from) == [0, 25] && initialRequests.allSatisfy {
            $0.size == 25 && $0.query == #""budget" AND NOT (isClientSoftDeleted:TRUE)"# && $0.mailbox == "OID:\(accountA)@\(tenant)"
        })
        let scoped = try await store.searchServer("budget", in: "newer-chat")
        let scopedRequest = await transport.requests.last
        precondition(!scoped.results.isEmpty && scopedRequest?.query.hasPrefix(#"clientconversationid:"newer-chat" AND "#) == true)

        precondition(store.conversation("older-chat") == nil)
        let originalRevision = store.accountRevision, originalScope = store.accountScope
        try await store.resolveSearchChat("older-chat", expectedAccount: originalScope, expectedRevision: originalRevision)
        precondition(store.conversation("older-chat")?.title == "Older chat")
        await store.loadConversation("older-chat")
        precondition(store.messages(in: "older-chat").last?.id == "1800000000002")
        let offline = TeamsReaderStore(cacheRoot: root, transport: transport)
        await offline.restoreAccount(accountID: accountA, tenantID: tenant, displayName: "Fixture")
        precondition(!offline.connected && offline.conversation("older-chat")?.title == "Older chat",
                     "Offline restore did not list the chat opened from search")
        await offline.loadConversation("older-chat")
        precondition(offline.messages(in: "older-chat").last?.id == "1800000000002")
        print("SEARCH_CHAT_OFFLINE_OK: restored the chat and its history without a chat-list refresh")

        precondition(store.conversation("older-chat")?.isRead == false && store.conversation("older-chat")?.lastMessage == nil)
        await store.markConversationRead("older-chat")
        let horizon = await transport.horizon
        precondition(horizon.hasPrefix("1800000000002;") && store.readStatusMessages["older-chat"] == "Read update confirmed.")
        precondition(store.serverChatSnapshot?.chats.isEmpty == true)
        precondition(store.conversation("older-chat")?.isRead == true,
                     "Confirmed read did not clear unread state without a chat-list preview")
        print("SEARCH_CHAT_READ_OK: cleared unread state after a confirmed read without a chat-list preview")

        await transport.respond(hold: true)
        let previousAccount = Task { try await store.searchServer("budget") }
        await transport.waitForHeldRequest()
        await store.connect(session: session(accountB))
        await transport.release()
        do { _ = try await previousAccount.value; fatalError("Accepted a result from the previous account") }
        catch is CancellationError {}
        precondition(store.conversation("older-chat") == nil)
        do {
            try await store.resolveSearchChat("older-chat", expectedAccount: originalScope, expectedRevision: originalRevision)
            fatalError("Opened a result from the previous account")
        } catch is CancellationError {}

        await transport.respond(status: 429, hold: true)
        let previousSession = Task { try await store.searchServer("budget") }
        await transport.waitForHeldRequest()
        await store.connect(session: session(accountB))
        await transport.release()
        do { _ = try await previousSession.value; fatalError("Accepted a rate limit from the previous session") }
        catch is CancellationError {}
        precondition(!store.searchCoolingDown)

        await transport.respond(status: 429)
        do { _ = try await store.searchServer("budget"); fatalError("Expected Teams rate limit") }
        catch TeamsSearchError.http(status: 429, retryAfter: _) {}
        precondition(store.searchCoolingDown)
        let throttledCount = await transport.requests.count
        do { _ = try await store.searchServer("budget", in: "newer-chat"); fatalError("Sent a scoped request during cooldown") }
        catch TeamsSearchError.http(status: 429, retryAfter: _) {}
        let finalCount = await transport.requests.count
        precondition(finalCount == throttledCount)

        await store.connect(session: session(accountA, searchAccount: accountB))
        precondition(!store.canSearchServer)
        do { _ = try await store.searchServer("budget"); fatalError("Used another account's search session") }
        catch TeamsSearchError.invalidSession {}
        print("GLOBAL_MESSAGE_SEARCH_OK: unscoped and scoped requests, paging, result IDs, unloaded chats, stale account and session, shared cooldown")
    }
}
