import Testing
import Foundation
@testable import TeamsChat
@testable import TeamsCore

private actor NotificationCooldownTransport: HTTPTransport {
    private(set) var pageRequests = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.hasSuffix("/messages") {
            return (Data(), HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "1"])!)
        }
        pageRequests += 1
        let continuation = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "continuationToken" } == true
        let page = continuation ? TeamsWebChatPage(items: [.init(id: "destination")]) : TeamsWebChatPage(items: [.init(id: "first")], continuationToken: "next")
        return (try JSONEncoder().encode(page), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor struct TeamsNotificationRouterTests {
    @Test func deferredLookupSurvivesHistoryThrottleAndResumes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = NotificationCooldownTransport()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture")
        await store.connect(session: session)
        #expect(store.hasMoreChats)
        await store.loadConversation("first")
        #expect(store.retryNotBefore != nil && store.chatListError == nil)
        let destination = try #require(TeamsNotificationDestination(accountScope: store.accountScope, chatID: "destination", messageID: "123"))
        let router = TeamsNotificationRouter()
        router.receive(destination, requestID: "cooldown")
        for _ in 0..<25 { #expect(await router.loadNextPage(store: store, destination: destination) == .deferred) }
        #expect(await transport.pageRequests == 1)
        #expect(router.pending == destination && router.error == nil)
        for _ in 0..<200 {
            if store.retryNotBefore == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.retryNotBefore == nil)
        #expect(await router.loadNextPage(store: store, destination: destination) == .attempted)
        #expect(await transport.pageRequests == 2)
        #expect(router.takeIfAvailable(accountScope: store.accountScope, connected: store.connected, containsChat: store.conversation(destination.chatID) != nil, loading: store.isLoadingChats, hasMore: store.hasMoreChats) == destination)
    }
    @Test func notificationRequestHasStableAccountScopedDestination() throws {
        let destination = try #require(TeamsNotificationDestination(accountScope: "tenant:account", chatID: "chat", messageID: "123"))
        let first = TeamsNotifications.request(destination: destination, title: "Fixture")
        let second = TeamsNotifications.request(destination: destination, title: "Fixture")
        #expect(first.identifier == second.identifier)
        #expect(first.content.userInfo["accountScope"] as? String == "tenant:account")
        #expect(first.content.userInfo["chatID"] as? String == "chat")
        #expect(first.content.userInfo["messageID"] as? String == "123")
        #expect(TeamsNotificationDestination(accountScope: "tenant:account", chatID: "..", messageID: "123") == nil)
        #expect(TeamsNotificationDestination(accountScope: "tenant:account", chatID: "chat", messageID: "x") == nil)
    }
    @Test func routingWaitsForRestorationAndRejectsWrongAccountOrMissingChat() throws {
        let destination = try #require(TeamsNotificationDestination(accountScope: "tenant:account", chatID: "chat", messageID: "123"))
        let router = TeamsNotificationRouter()
        router.receive(destination, requestID: "request")
        #expect(router.takeIfAvailable(accountScope: "", connected: false, containsChat: false, loading: true, hasMore: false) == nil)
        #expect(router.pending == destination)
        #expect(router.takeIfAvailable(accountScope: "tenant:cached-other", connected: false, containsChat: false, loading: false, hasMore: false) == nil)
        #expect(router.pending == destination)
        #expect(router.takeIfAvailable(accountScope: "tenant:account", connected: true, containsChat: false, loading: false, hasMore: true) == nil)
        #expect(router.pending == destination)
        #expect(router.takeIfAvailable(accountScope: "tenant:account", connected: true, containsChat: true, loading: false, hasMore: false) == destination)
        router.receive(destination, requestID: "request")
        #expect(router.pending == nil)
        router.receive(destination, requestID: "other")
        #expect(router.takeIfAvailable(accountScope: "tenant:someoneelse", connected: true, containsChat: true, loading: false, hasMore: false) == nil)
        #expect(router.pending == nil && router.error != nil)
        router.receive(destination, requestID: "third")
        #expect(router.takeIfAvailable(accountScope: "tenant:account", connected: true, containsChat: false, loading: false, hasMore: false) == nil)
        #expect(router.pending == nil && router.error != nil)
        router.receive(destination, requestID: "fourth")
        let stale = try #require(router.beginPageSearch())
        router.receive(destination, requestID: "fifth")
        let current = try #require(router.beginPageSearch())
        #expect(!router.endPageSearch(stale))
        #expect(router.endPageSearch(current))
    }
}
