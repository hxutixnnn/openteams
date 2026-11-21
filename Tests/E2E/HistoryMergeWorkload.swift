import Foundation
import TeamsCore

private actor HistoryMergeTransport: HTTPTransport {
    private var page = TeamsWebMessagePage(messages: [])
    private var failing = false
    var writes = 0

    func setPage(_ page: TeamsWebMessagePage, failing: Bool = false) {
        self.page = page
        self.failing = failing
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod != nil && request.httpMethod != "GET" {
            writes += 1
            throw URLError(.unsupportedURL)
        }
        let data: Data
        if request.url!.path.hasSuffix("/chats") {
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture", title: "Fictional history", isOneOnOne: true)]))
        } else if request.url!.path.hasSuffix("/messages") {
            if failing { throw URLError(.notConnectedToInternet) }
            data = try JSONEncoder().encode(page)
        } else { throw URLError(.unsupportedURL) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct HistoryMergeWorkload {
    static let account = "fixture-a"
    static let tenant = "fixture-tenant"

    static func message(_ index: Int, version: String = "1", deleted: Bool = false) -> TeamsWebMessage {
        .init(id: String(1_800_000_000_000 + index),
              content: "<p><strong>Fictional message \(index)</strong> Xin chào 👋 <a href=\"https://example.com/fixture\">Reference</a></p><ol><li>First item</li><li><em>Second item</em></li></ol><blockquote>Fictional quoted content</blockquote>",
              messageType: "RichText/Html", imDisplayName: account, from: .string("8:orgid:" + account),
              originalArrivalTime: String(1_800_000_000_000 + index), version: version,
              properties: deleted ? .object(["deletetime": .number(1)]) : nil)
    }

    static func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional",
              expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Fictional account",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fictional", expiresAt: .distantFuture))
    }

    static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    static func report(_ workload: String, count: Int, times: [Double]) throws {
        let sorted = times.sorted()
        let row: [String: Any] = ["workload": workload, "messages": count, "samples_ms": times,
                                  "median_ms": (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2]
        print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
    }

    @MainActor static func verify(_ store: TeamsReaderStore, cache: TeamsReadCache, expected: [TeamsWebMessage], token: String?) async throws {
        precondition(store.messages(in: "fixture") == expected.map {
            TeamsRenderedMessage($0, accountScope: store.accountScope, accountRevision: store.accountRevision, chatID: "fixture")
        })
        let saved = try await cache.history(in: "fixture")
        precondition(saved.messages == expected && saved.messageToken == token)
        precondition(!store.isLoadingConversation("fixture"))
    }

    @MainActor static func main() async throws {
        for count in [200, 2000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-history-merge-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
            let transport = HistoryMergeTransport()
            var expected = (1...count).map { message($0) }
            try await cache.save(.init(messages: expected, messageToken: "older"), in: "fixture")
            let store = TeamsReaderStore(cacheRoot: root, transport: transport)
            await store.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
            await store.loadConversation("fixture")
            await store.connect(session: session())
            await transport.setPage(.init(messages: [expected.last!], messageToken: "older"))
            var times: [Double] = []
            for sample in -1..<7 {
                let start = ContinuousClock.now
                await store.refreshConversation("fixture")
                let milliseconds = elapsed(start)
                if sample >= 0 { times.append(milliseconds) }
                precondition(store.chatErrors["fixture"] == nil)
                try await verify(store, cache: cache, expected: expected, token: "older")
            }
            try report("refresh_rich", count: count, times: times)
            times = []
            for sample in -1..<7 {
                let older = ((-20 * (sample + 2) + 1)...(-20 * (sample + 1))).map { message($0) }
                let token = "older-\(sample + 2)"
                await transport.setPage(.init(messages: [expected[0]] + older.reversed(), messageToken: token))
                let start = ContinuousClock.now
                await store.loadOlderMessages("fixture")
                let milliseconds = elapsed(start)
                if sample >= 0 { times.append(milliseconds) }
                expected = older + expected
                precondition(store.chatErrors["fixture"] == nil)
                try await verify(store, cache: cache, expected: expected, token: token)
            }
            try report("pagination_rich", count: count, times: times)
            let deleted = message(count, version: "2", deleted: true)
            let appended = message(count + 1)
            await transport.setPage(.init(messages: [message(1, version: "0"), deleted, appended]))
            await store.refreshConversation("fixture")
            expected[expected.count - 1] = deleted
            expected.append(appended)
            try await verify(store, cache: cache, expected: expected, token: "older-8")
            await transport.setPage(.init(messages: [message(count)]))
            await store.refreshConversation("fixture")
            try await verify(store, cache: cache, expected: expected, token: "older-8")
            await transport.setPage(.init(messages: []), failing: true)
            await store.refreshConversation("fixture")
            precondition(store.chatErrors["fixture"] != nil)
            try await verify(store, cache: cache, expected: expected, token: "older-8")
            await store.loadOlderMessages("fixture")
            precondition(store.chatErrors["fixture"] != nil)
            try await verify(store, cache: cache, expected: expected, token: "older-8")
            await transport.setPage(.init(messages: []))
            await store.loadOlderMessages("fixture")
            try await verify(store, cache: cache, expected: expected, token: nil)
            await store.refreshConversation("fixture")
            try await verify(store, cache: cache, expected: expected, token: nil)
            await store.refreshConversation("empty")
            let empty = try await cache.history(in: "empty")
            precondition(empty.messages.isEmpty && store.messages(in: "empty").isEmpty)
            let writes = await transport.writes
            precondition(writes == 0)
            store.disconnect()
            let recovered = TeamsReaderStore(cacheRoot: root, transport: transport)
            await recovered.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
            await recovered.loadConversation("fixture")
            try await verify(recovered, cache: cache, expected: expected, token: nil)
        }
        print("HISTORY_MERGE_OK: refresh, pagination, overlap, stale versions, deletion, append, empty pages, network errors, restart, no HTTP writes")
    }
}
