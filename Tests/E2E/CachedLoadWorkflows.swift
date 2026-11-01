import Foundation
import TeamsCore

private actor CachedLoadTransport: HTTPTransport {
    private var page = TeamsWebMessagePage(messages: [])
    var writes = 0
    func setPage(_ page: TeamsWebMessagePage) { self.page = page }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod != nil && request.httpMethod != "GET" { writes += 1; throw URLError(.unsupportedURL) }
        let data: Data
        if request.url!.path.hasSuffix("/chats") {
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture", title: "Fictional history", isOneOnOne: true)]))
        } else if request.url!.path.hasSuffix("/messages") {
            data = try JSONEncoder().encode(page)
        } else { throw URLError(.unsupportedURL) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct CachedLoadWorkflows {
    static let tenant = "fixture-tenant"
    static func message(_ index: Int, account: String = "fixture-a", deleted: Bool = false) -> TeamsWebMessage {
        .init(id: String(1_800_000_000_000 + index), content: "<p><strong>\(account) message \(index)</strong> Xin chào 👋</p><ol><li>First item</li><li>Second item</li></ol>", messageType: "RichText/Html", imDisplayName: account, from: .string("8:orgid:" + account), originalArrivalTime: String(1_800_000_000_000 + index), version: deleted ? "2" : "1", properties: deleted ? .object(["deletetime": .number(1)]) : nil)
    }
    static func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional", expiresAt: .distantFuture, accountID: "fixture-a", tenantID: tenant, displayName: "Fictional account", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fictional", expiresAt: .distantFuture))
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-cold-workflows-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CachedLoadTransport()
        let a = TeamsReadCache(root: root, accountID: "fixture-a", tenantID: tenant)
        let b = TeamsReadCache(root: root, accountID: "fixture-b", tenantID: tenant)
        let raw = (1...2000).map { message($0) }
        let rawB = (1...200).map { message($0, account: "fixture-b") }
        try await a.save(.init(messages: raw, messageToken: "older"), in: "fixture")
        try await a.save(.init(messages: [message(-1)]), in: "second")
        try await b.save(.init(messages: rawB), in: "fixture")
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.restoreAccount(accountID: "fixture-a", tenantID: tenant, displayName: "A")
        var switchTask: Task<Void, Never>?
        store.onCachedLoadTiming = { stage, _, _ in
            guard stage == "cache_read" else { return }
            store.onCachedLoadTiming = nil
            switchTask = Task { @MainActor in await store.restoreAccount(accountID: "fixture-b", tenantID: tenant, displayName: "B") }
        }
        await store.loadConversation("fixture")
        await switchTask?.value
        precondition(switchTask != nil && store.accountID == "fixture-b" && store.messages(in: "fixture").isEmpty && !store.isLoadingConversation("fixture"))
        await store.loadConversation("fixture")
        precondition(store.messages(in: "fixture").map(\.author.name) == Array(repeating: "fixture-b", count: 200))
        await store.restoreAccount(accountID: "fixture-a", tenantID: tenant, displayName: "A")
        var coldTask: Task<Void, Never>?
        store.onCachedLoadTiming = { stage, _, _ in if stage == "cache_read" { coldTask?.cancel() } }
        coldTask = Task { @MainActor in await store.loadConversation("fixture") }
        await coldTask?.value
        precondition(store.messages(in: "fixture").isEmpty && store.cacheWarning == nil && !store.isLoadingConversation("fixture"))
        store.onCachedLoadTiming = nil
        async let first: Void = store.loadConversation("fixture")
        async let second: Void = store.loadConversation("second")
        _ = await (first, second)
        precondition(store.messages(in: "fixture").map(\.id) == raw.map(\.id))
        precondition(store.messages(in: "second").map(\.id) == [message(-1).id])
        store.disconnect()
        await store.restoreAccount(accountID: "fixture-a", tenantID: tenant, displayName: "A")
        await store.connect(session: session())
        let deleted = message(2000, deleted: true), appended = message(2001)
        await transport.setPage(.init(messages: [deleted, appended], messageToken: "older"))
        var refreshTask: Task<Void, Never>?
        store.onCachedLoadTiming = { stage, _, _ in
            guard stage == "cache_read" else { return }
            store.onCachedLoadTiming = nil
            refreshTask = Task { @MainActor in await store.refreshConversation("fixture") }
        }
        await store.loadConversation("fixture")
        await refreshTask?.value
        precondition(refreshTask != nil && store.messages(in: "fixture").count == 2001)
        precondition(store.messages(in: "fixture").last?.id == appended.id)
        precondition(store.messages(in: "fixture").first { $0.id == deleted.id }?.isDeleted == true)
        precondition(!store.canReact(in: "fixture", messageID: deleted.id))
        precondition(!store.canDelete(in: "fixture", messageID: deleted.id))
        precondition(store.canReact(in: "fixture", messageID: appended.id))
        precondition(store.canEditMessage(in: "fixture", messageID: appended.id))
        await transport.setPage(.init(messages: [message(-2)]))
        await store.loadOlderMessages("fixture")
        precondition(store.messages(in: "fixture").first?.id == message(-2).id)
        precondition(store.messages(in: "fixture").last?.id == appended.id)
        let saved = try await a.history(in: "fixture")
        precondition(saved.messages.first?.id == message(-2).id && saved.messages.last?.id == appended.id)
        let writes = await transport.writes
        precondition(writes == 0)
        store.disconnect()
        print("CACHED_WORKFLOWS_OK: account switch during conversion; cancellation and retry; concurrent conversations; refresh versus cold result; same-ID deletion; append/prepend; scoped disk persistence; no HTTP writes")
    }
}
