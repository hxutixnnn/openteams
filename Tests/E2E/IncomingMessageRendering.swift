import Foundation
import TeamsCore

private actor IncomingTransport: HTTPTransport {
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
struct IncomingMessageRendering {
    private static let account = "fixture-a"
    private static let tenant = "fixture-tenant"
    private static let historyCount = 2_000
    private static let incomingCount = 40

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-incoming-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        let transport = IncomingTransport()
        var expected = (1...historyCount).map { message($0) }
        try await cache.save(.init(messages: expected, messageToken: "older"), in: "fixture")
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
        await store.loadConversation("fixture")
        await store.connect(session: session())
        verify(store, expected)

        var times: [Double] = []
        for index in 1...incomingCount {
            let incoming = message(historyCount + index)
            await transport.setPage(.init(messages: [incoming, expected[expected.count - 1]]))
            let start = ContinuousClock.now
            await store.refreshConversation("fixture")
            times.append(milliseconds(since: start))
            expected.append(incoming)
            precondition(store.chatErrors["fixture"] == nil)
            verify(store, expected)
        }

        let edited = message(historyCount, content: "<p>Edited fictional message</p>", version: "2")
        let deleted = message(historyCount + 1, version: "3", deleted: true)
        await transport.setPage(.init(messages: [edited, deleted]))
        await store.refreshConversation("fixture")
        expected[historyCount - 1] = edited
        expected[historyCount] = deleted
        verify(store, expected)
        precondition(store.messages(in: "fixture")[historyCount - 1].body.text.contains("Edited fictional message"))
        precondition(store.messages(in: "fixture")[historyCount].isDeleted)

        await store.refreshConversation("fixture")
        verify(store, expected)

        let sorted = times.sorted()
        print(String(format: "IncomingMessageRendering passed: refresh with one new message into %d messages median %.2f ms", historyCount, sorted[sorted.count / 2]))
    }

    private static func verify(_ store: TeamsReaderStore, _ expected: [TeamsWebMessage]) {
        precondition(store.messages(in: "fixture") == expected.map {
            TeamsRenderedMessage($0, accountScope: store.accountScope, accountRevision: store.accountRevision, chatID: "fixture")
        }, "Rendered messages differ from a fresh render")
        precondition(store.messageIDs(in: "fixture") == expected.map(\.id))
    }

    private static func message(_ index: Int, content: String? = nil, version: String = "1", deleted: Bool = false) -> TeamsWebMessage {
        .init(id: String(1_800_000_000_000 + index),
              content: content ?? "<p><strong>Fictional message \(index)</strong> Xin chào 👋 <a href=\"https://example.com/fixture\">Reference</a></p><blockquote>Fictional quoted content</blockquote>",
              messageType: "RichText/Html", imDisplayName: account, from: .string("8:orgid:" + account),
              originalArrivalTime: String(1_800_000_000_000 + index), version: version,
              properties: deleted ? .object(["deletetime": .number(1)]) : nil)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    private static func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional",
              expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Fictional account",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fictional", expiresAt: .distantFuture))
    }
}
