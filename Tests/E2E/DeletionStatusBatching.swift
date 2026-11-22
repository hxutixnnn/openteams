import Foundation
import TeamsCore

private actor DeletionTransport: HTTPTransport {
    private var page = TeamsWebMessagePage(messages: [])

    func setPage(_ page: TeamsWebMessagePage) { self.page = page }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let data: Data
        if url.path.hasSuffix("/chats") {
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture", title: "Fictional history", isOneOnOne: true)]))
        } else if url.path.hasSuffix("/messages") {
            data = try JSONEncoder().encode(page)
        } else { throw URLError(.unsupportedURL) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@main @MainActor
struct DeletionStatusBatching {
    private static let account = "fixture-a"
    private static let tenant = "fixture-tenant"
    private static let historyCount = 2_000

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-deletion-status-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        let history = (1...historyCount).map { message($0) }
        try await cache.save(.init(messages: history), in: "fixture")
        try await cache.save(.init(messages: history), in: "other")
        let prepared = try await install(history[9], in: "fixture", cache: cache)
        let rejected = try await install(history[19], in: "fixture", cache: cache)
        require(try await cache.updatePendingDeletion(id: rejected.id, in: "fixture", messageID: rejected.original.id, expected: .prepared, stage: .rejected))
        let dispatched = try await install(history[29], in: "fixture", cache: cache)
        require(try await cache.updatePendingDeletion(id: dispatched.id, in: "fixture", messageID: dispatched.original.id, expected: .prepared, stage: .dispatched))
        _ = try await install(history[39], in: "other", cache: cache)

        let store = TeamsReaderStore(cacheRoot: root, transport: DeletionTransport())
        await store.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
        await store.loadConversation("fixture")
        let ids = store.messageIDs(in: "fixture")
        precondition(ids.count == historyCount)

        let clock = ContinuousClock()
        var start = clock.now
        for id in ids { _ = try await cache.pendingDeletion(in: "fixture", messageID: id) }
        let perRow = milliseconds(start.duration(to: clock.now))
        start = clock.now
        await store.loadDeletionStatuses(in: "fixture", messageIDs: ids, expectedScope: store.accountScope, expectedRevision: store.accountRevision)
        let batched = milliseconds(start.duration(to: clock.now))
        try await check(store, cache: cache, ids: ids)
        precondition(store.deletionStage(in: "fixture", messageID: history[9].id) == .prepared)
        precondition(store.deletionStage(in: "fixture", messageID: history[19].id) == .rejected)
        precondition(store.deletionStage(in: "fixture", messageID: history[29].id) == .dispatched)
        precondition(store.deletionStage(in: "fixture", messageID: history[39].id) == nil)
        precondition(!store.canDelete(in: "fixture", messageID: history[9].id))
        precondition(store.chatErrors["fixture"] == nil)

        let added = try await install(history[49], in: "fixture", cache: cache)
        require(try await cache.updatePendingDeletion(id: prepared.id, in: "fixture", messageID: prepared.original.id, expected: .prepared, stage: .rejected))
        await store.loadDeletionStatuses(in: "fixture", messageIDs: [added.original.id], expectedScope: store.accountScope, expectedRevision: store.accountRevision)
        precondition(store.deletionStage(in: "fixture", messageID: added.original.id) == .prepared)
        precondition(store.deletionStage(in: "fixture", messageID: history[9].id) == .prepared)

        require(try await cache.updatePendingDeletion(id: rejected.id, in: "fixture", messageID: rejected.original.id, expected: .rejected, stage: nil))
        await store.loadDeletionStatuses(in: "fixture", messageIDs: ids, expectedScope: store.accountScope, expectedRevision: store.accountRevision)
        try await check(store, cache: cache, ids: ids)
        precondition(store.deletionStage(in: "fixture", messageID: history[9].id) == .rejected)
        precondition(store.deletionStage(in: "fixture", messageID: history[19].id) == nil)

        require(try await cache.updatePendingDeletion(id: added.id, in: "fixture", messageID: added.original.id, expected: .prepared, stage: .rejected))
        await store.loadDeletionStatuses(in: "fixture", messageIDs: ids, expectedScope: "stale", expectedRevision: store.accountRevision)
        await store.loadDeletionStatuses(in: "fixture", messageIDs: ids, expectedScope: store.accountScope, expectedRevision: UUID())
        precondition(store.deletionStage(in: "fixture", messageID: added.original.id) == .prepared)

        print(String(format: "DeletionStatusBatching passed: deletion status for %d messages %.2f ms per row -> %.2f ms batched", ids.count, perRow, batched))
    }

    private static func install(_ message: TeamsWebMessage, in chatID: String, cache: TeamsReadCache) async throws -> TeamsPendingDeletion {
        let intent = TeamsPendingDeletion(original: message)
        require(try await cache.installPendingDeletion(intent, in: chatID))
        return intent
    }

    private static func require(_ condition: Bool) { precondition(condition) }

    private static func check(_ store: TeamsReaderStore, cache: TeamsReadCache, ids: [String]) async throws {
        for id in ids {
            let saved = try await cache.pendingDeletion(in: "fixture", messageID: id)
            precondition(store.deletionStage(in: "fixture", messageID: id) == saved?.stage, "Batched deletion status differs from the saved intent")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }

    private static func message(_ index: Int, content: String? = nil, version: String = "1", deleted: Bool = false) -> TeamsWebMessage {
        .init(id: String(1_800_000_000_000 + index),
              content: content ?? "<p><strong>Fictional message \(index)</strong> Xin chào 👋 <a href=\"https://example.com/fixture\">Reference</a></p><blockquote>Fictional quoted content</blockquote>",
              messageType: "RichText/Html", imDisplayName: account, from: .string("8:orgid:" + account),
              originalArrivalTime: String(1_800_000_000_000 + index), version: version,
              properties: deleted ? .object(["deletetime": .number(1)]) : nil)
    }
}
