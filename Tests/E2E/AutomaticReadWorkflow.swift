import Foundation
import TeamsCore

private actor ReadTransport: HTTPTransport {
    var bookmark = false
    var wrote = false
    var puts: [URLRequest] = []
    var stateRequests: [Date] = []
    var failures = 0
    var failRequest: Int?
    func setBookmark(_ value: Bool) { bookmark = value }
    func failStates(_ count: Int) { failures = count }
    func failStateRequest(_ index: Int) { failRequest = index }
    func reset() { wrote = false; puts = []; stateRequests = []; failures = 0; failRequest = nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.httpMethod == "PUT" {
            puts.append(request)
            wrote = true
            data = Data()
        } else if request.url!.path.hasSuffix("/chats") {
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat", isOneOnOne: true, isRead: false)]))
        } else if request.url!.path.hasSuffix("/messages") {
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "1800000000000", content: "Visible", originalArrivalTime: "1800000000000")]))
        } else {
            stateRequests.append(Date())
            if failRequest == stateRequests.count {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
            }
            if failures > 0 {
                failures -= 1
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
            }
            let horizon = wrote ? "1800000000000;3;1800000000000" : "1;1;0"
            let marker = bookmark ? "9;2;0" : "0;2;0"
            data = Data("{\"id\":\"chat\",\"properties\":{\"consumptionhorizon\":\"\(horizon)\",\"consumptionHorizonBookmark\":\"\(marker)\"}}".utf8)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct AutomaticReadWorkflow {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReadTransport()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional", expiresAt: .distantFuture, accountID: "fixture", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fictional", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        await store.loadConversation("chat")
        precondition(store.messages(in: "chat").last?.id == "1800000000000")
        await store.markVisibleConversationRead("chat", messageID: "older")
        let firstPuts = await transport.puts
        precondition(firstPuts.isEmpty)
        await transport.setBookmark(true)
        await store.markVisibleConversationRead("chat", messageID: "1800000000000")
        let bookmarkedPuts = await transport.puts
        precondition(bookmarkedPuts.isEmpty)
        precondition(store.chatErrors["chat"] == nil && store.readStatusMessages["chat"] == nil)
        await transport.setBookmark(false)
        await store.markVisibleConversationRead("chat", messageID: "1800000000000")
        let puts = await transport.puts
        precondition(puts.count == 1 && puts[0].url?.query?.contains("consumptionhorizon") == true)
        precondition(store.chatErrors["chat"] == nil && store.readStatusMessages["chat"] == nil)
        let cache = TeamsReadCache(root: root, accountID: "fixture", tenantID: "tenant")
        let pending = try await cache.pendingRead(in: "chat")
        precondition(pending == nil)
        await transport.reset()
        await store.retryVisibleConversationRead("chat", messageID: "1800000000000")
        let cleanRequests = await transport.stateRequests
        let cleanPuts = await transport.puts
        precondition(cleanRequests.count == 2 && cleanPuts.count == 1)
        await transport.reset()
        await transport.failStates(1)
        await store.retryVisibleConversationRead("chat", messageID: "1800000000000")
        let recoveredPuts = await transport.puts
        let recoveredRequests = await transport.stateRequests
        precondition(recoveredPuts.count == 1 && recoveredRequests.count == 3)
        precondition(recoveredRequests[1].timeIntervalSince(recoveredRequests[0]) >= 1.9)
        await transport.reset()
        await transport.failStates(3)
        await store.retryVisibleConversationRead("chat", messageID: "1800000000000")
        let failedRequests = await transport.stateRequests
        precondition(failedRequests.count == 3 && failedRequests[2].timeIntervalSince(failedRequests[0]) >= 3.8)
        await transport.reset()
        await transport.failStateRequest(2)
        await store.retryVisibleConversationRead("chat", messageID: "1800000000000")
        let unconfirmedRequests = await transport.stateRequests
        let unconfirmedPuts = await transport.puts
        let unconfirmedPending = try await cache.pendingRead(in: "chat")
        precondition(unconfirmedRequests.count == 2 && unconfirmedPuts.count == 1 && unconfirmedPending != nil)
        await store.retryVisibleConversationRead("chat", messageID: "1800000000000")
        let blockedRequests = await transport.stateRequests
        let blockedPuts = await transport.puts
        precondition(blockedRequests.count == 2 && blockedPuts.count == 1)
        await store.checkReadStatus("chat")
        let resolvedPending = try await cache.pendingRead(in: "chat")
        precondition(resolvedPending == nil)
        await transport.reset()
        let manual = TeamsPendingReadIntent(targetHorizon: 1, bookmarkRequired: false)
        let installed = try await cache.installPendingRead(manual, in: "chat")
        precondition(installed)
        await store.retryVisibleConversationRead("chat", messageID: "1800000000000")
        let pendingPuts = await transport.puts
        let pendingRequests = await transport.stateRequests
        precondition(pendingPuts.isEmpty && pendingRequests.isEmpty)
        await store.checkReadStatus("chat")
        let cleared = try await cache.pendingRead(in: "chat")
        precondition(cleared == nil)
        await store.retryVisibleConversationRead("chat", messageID: "1800000000000")
        let manualRecoveryPuts = await transport.puts
        precondition(manualRecoveryPuts.count == 1)
        print("AUTOMATIC_READ_OK: boundary, bookmark, quiet update, bounded transient retry, pending manual recovery")
    }
}
