import Foundation
import Testing
@testable import TeamsCore

private actor SharedTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, Data)]
    var hold = false
    var waiting: CheckedContinuation<Void, Never>?
    init(_ responses: [(Int, String)]) { self.responses = responses.map { ($0.0, Data($0.1.utf8)) } }
    func setHold() { hold = true }
    func release() { waiting?.resume(); waiting = nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if hold { await withCheckedContinuation { waiting = $0 } }
        let response = responses.removeFirst()
        return (response.1, HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: response.0 == 429 ? ["Retry-After": "120"] : nil)!)
    }
}

@MainActor struct TeamsSharedIndexTests {
    let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    func search() -> TeamsSearchSession { .init(accessToken: "fixture", expiresAt: .distantFuture, accountID: account, tenantID: tenant) }
    func session(_ id: String? = nil) -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: id ?? account, tenantID: tenant, displayName: "Fixture", searchSession: search())
    }
    @Test func queryPagingAndTypedRows() async throws {
        let transport = SharedTransport([(200, #"{"Items":[{"FileData":{"FileName":"Report","FileUrl":"https://files.example/file"},"TeamsMessageId":"123","ThreadId":"chat"},{"WeblinkData":{"Title":"Site","WebUrl":"https://example.com/page"},"TeamsMessageId":"124","ParentMessageId":"999"}],"HasMoreItems":true,"Bookmark":"next+/="}"#), (200, #"{"Items":[],"HasMoreItems":false}"#)])
        let client = TeamsSharedIndexClient(session: search(), transport: transport)
        let first = try await client.page(chatID: "chat")
        #expect(first.items.map(\.kind) == [.file, .link] && first.items.map(\.messageID) == ["123", "124"])
        #expect(first.items[1].parentMessageID == "999")
        let second = try await client.page(chatID: "chat", bookmark: first.bookmark, offset: first.rawCount)
        #expect(second.items.isEmpty && !second.hasMore)
        let requests = await transport.requests
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.filter { $0.name == "ItemTypes" }.map(\.value) == ["File", "Link"])
        #expect(query.first { $0.name == "Bookmark" }?.value == "next+/=" && query.first { $0.name == "Skip" }?.value == "2")
        #expect(requests[0].value(forHTTPHeaderField: "X-AnchorMailbox") == "Oid:\(account)@\(tenant)")
        #expect(requests.allSatisfy { $0.url?.host == "substrate.office.com" })
    }
    @Test func errorsAreNotEmptyAndUnsafeLinksAreNeverOpened() async throws {
        let transport = SharedTransport([(403, "{}"), (200, #"{"Items":[{"WeblinkData":{"WebUrl":"http://unsafe"}},{"FileData":{"FileName":"Private","FileUrl":"https://user:pass@example.com/x"}}],"HasMoreItems":false}"#)])
        let client = TeamsSharedIndexClient(session: search(), transport: transport)
        do { _ = try await client.page(chatID: "chat"); Issue.record("403 returned as empty") } catch {}
        let page = try await client.page(chatID: "chat")
        #expect(page.items.count == 1 && page.items[0].url == nil)
    }
    @Test func accountReplacementDiscardsDelayedPage() async throws {
        let transport = SharedTransport([(200, #"{"items":[]}"#), (200, #"{"Items":[],"HasMoreItems":false}"#)])
        let store = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport)
        await store.connect(session: session())
        await transport.setHold()
        let task = Task { try await store.sharedItems(in: "chat") }
        while await transport.requests.count < 2 { await Task.yield() }
        await store.restoreAccount(accountID: "cccccccc-cccc-cccc-cccc-cccccccccccc", tenantID: tenant, displayName: "Other")
        await transport.release()
        do { _ = try await task.value; Issue.record("Stale page returned") } catch {}
    }
    @Test func throttleBlocksAnImmediateSecondRequest() async throws {
        let transport = SharedTransport([(200, #"{"items":[]}"#), (429, "{}")])
        let store = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport)
        await store.connect(session: session())
        for _ in 0..<2 { do { _ = try await store.sharedItems(in: "chat") } catch {} }
        #expect(await transport.requests.count == 2 && store.sharedRetryNotBefore != nil)
    }
    @Test func overlapHasStableIdentityWithoutMergingDistinctShares() async throws {
        let transport = SharedTransport([(200, #"{"Items":[{"FileData":{"ImmutableId":"same","FileName":"Doc","FileUrl":"https://example.com/doc"},"TeamsMessageId":"1"}],"HasMoreItems":true,"Bookmark":"same"}"#), (200, #"{"Items":[{"FileData":{"ImmutableId":"same","FileName":"Doc","FileUrl":"https://example.com/doc"},"TeamsMessageId":"1"},{"FileData":{"ImmutableId":"same","FileName":"Doc","FileUrl":"https://example.com/doc"},"TeamsMessageId":"2"}],"HasMoreItems":false}"#)])
        let client = TeamsSharedIndexClient(session: search(), transport: transport)
        let first = try await client.page(chatID: "chat")
        let second = try await client.page(chatID: "chat", bookmark: first.bookmark, offset: 1)
        #expect(first.items[0].id == second.items[0].id && first.items[0].id != second.items[1].id)
        #expect(first.items[0].immutableID == "same")
    }

    @Test func repeatedRawPagesStopEvenWithUnsupportedItems() async throws {
        let mixed = #"{"Items":[{"FileData":{"FileName":"Doc","FileUrl":"https://example.com/doc"},"TeamsMessageId":"1"},{"UnknownData":{"id":"u1"}}],"HasMoreItems":true,"Bookmark":"same"}"#
        let unsupportedOne = #"{"Items":[{"UnknownData":{"id":"u1"}}],"HasMoreItems":true,"Bookmark":"same"}"#
        let unsupportedTwo = #"{"Items":[{"UnknownData":{"id":"u2"}}],"HasMoreItems":true,"Bookmark":"same"}"#
        let transport = SharedTransport([(200, mixed), (200, mixed), (200, unsupportedOne), (200, unsupportedTwo), (200, unsupportedTwo)])
        let client = TeamsSharedIndexClient(session: search(), transport: transport)
        var tracker = TeamsSharedPaginationTracker()
        let first = try await client.page(chatID: "chat")
        #expect(try tracker.accept(first).count == 1 && first.unsupportedCount == 1)
        let repeated = try await client.page(chatID: "chat", bookmark: "same", offset: 2)
        do { _ = try tracker.accept(repeated); Issue.record("Repeated mixed page accepted") } catch {}
        var unsupportedTracker = TeamsSharedPaginationTracker()
        let one = try await client.page(chatID: "chat", offset: 4)
        let two = try await client.page(chatID: "chat", offset: 5)
        #expect(try unsupportedTracker.accept(one).isEmpty && unsupportedTracker.accept(two).isEmpty)
        let again = try await client.page(chatID: "chat", offset: 6)
        do { _ = try unsupportedTracker.accept(again); Issue.record("Repeated unsupported page accepted") } catch {}
    }

}
