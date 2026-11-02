import Foundation
import TeamsCore

private actor FictionalTransport: HTTPTransport {
    var requests = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        throw URLError(.notConnectedToInternet)
    }
}

@main struct CachedConversationLoading {
    static let account = "fixture-a"
    static let tenant = "fixture-tenant"
    static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
    static func message(_ index: Int, rich: Bool, account: String = account) -> TeamsWebMessage {
        .init(id: String(1_800_000_000_000 + index),
              content: rich ? "<p><strong>Fictional message \(index)</strong> Xin chào 👋 <a href=\"https://example.com/fixture\">Reference</a></p><ol><li>First item</li><li><em>Second item</em></li></ol><blockquote>Fictional quoted content</blockquote>" : "Fictional message \(index)",
              messageType: rich ? "RichText/Html" : "Text", imDisplayName: account,
              from: .string("8:orgid:" + account), originalArrivalTime: String(1_800_000_000_000 + index), version: "1")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-cached-load-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FictionalTransport()
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        try await cache.save(.init(chats: [.init(id: "fixture", title: "Fictional history")]))
        for rich in [false, true] {
            for count in [200, 2000] {
                let raw = (1...count).map { message($0, rich: rich) }
                try await cache.save(.init(messages: raw, messageToken: "older"), in: "fixture")
                let store = TeamsReaderStore(cacheRoot: root, transport: transport)
                await store.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
                var stages: [String: Double] = [:]
                var mainStages: [String: Bool] = [:]
                store.onCachedLoadTiming = { name, ms, main in stages[name] = ms; mainStages[name] = main }
                let start = ContinuousClock.now
                await store.loadConversation("fixture")
                let total = elapsed(start)
                precondition(store.messages(in: "fixture") == raw.map { TeamsRenderedMessage($0, accountScope: tenant + ":" + account, accountRevision: store.accountRevision, chatID: "fixture") })
                precondition(store.hasOlderMessages("fixture"))
                let saved = try await cache.history(in: "fixture")
                precondition(saved.messages == raw)
                let warmStart = ContinuousClock.now
                await store.loadConversation("fixture")
                let warm = elapsed(warmStart)
                let row: [String: Any] = ["count": count, "rich": rich, "total_ms": total, "warm_ms": warm, "stages_ms": stages, "stages_on_main_thread": mainStages]
                print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            }
        }
        let requests = await transport.requests
        precondition(requests == 0)
        print("CACHED_LOADING_OK")
    }
}
