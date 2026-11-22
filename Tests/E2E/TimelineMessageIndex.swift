import Foundation
import Observation
import TeamsCore

private actor IndexTransport: HTTPTransport {
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

private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.lock(); changed = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return changed }
}

@main @MainActor
struct TimelineMessageIndex {
    private static let account = "fixture-a"
    private static let tenant = "fixture-tenant"
    private static let historyCount = 2_000
    private static let visibleRows = 25
    private static let renders = 2_000

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-timeline-index-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        let transport = IndexTransport()
        var expected = (1...historyCount).map { message($0) }
        try await cache.save(.init(messages: expected, messageToken: "older"), in: "fixture")
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
        await store.loadConversation("fixture")
        check(store)
        await store.connect(session: session())
        check(store)

        let incoming = observe { _ = store.messageIndex(of: expected[0].id, in: "fixture") }
        let appended = message(historyCount + 1)
        await transport.setPage(.init(messages: [appended, expected[expected.count - 1]]))
        await store.refreshConversation("fixture")
        expected.append(appended)
        precondition(incoming.value && store.messageIndex(of: appended.id, in: "fixture") == expected.count - 1)
        check(store)

        let prepend = observe { _ = store.messageIndex(of: expected[0].id, in: "fixture") }
        let older = (-19...0).map { message($0) }
        await transport.setPage(.init(messages: [expected[0]] + older.reversed(), messageToken: "older-1"))
        await store.loadOlderMessages("fixture")
        expected = older + expected
        precondition(store.chatErrors["fixture"] == nil && prepend.value)
        precondition(store.messageIndex(of: message(1).id, in: "fixture") == older.count)
        check(store)

        precondition(store.messageIndex(of: "absent", in: "fixture") == nil)
        precondition(store.messageIndex(of: expected[0].id, in: "other") == nil)

        let messages = store.messages(in: "fixture")
        let rebuilt = medianMicroseconds { Set(messages.map(\.id)).count + Array(messages.enumerated()).count }
        let visible = messages.suffix(visibleRows)
        let indexed = medianMicroseconds { visible.reduce(1) { $0 + (store.messageIndex(of: $1.id, in: "fixture") ?? 0) } }
        print(String(format: "TimelineMessageIndex passed: timeline render with %d messages %.2f us -> %.2f us for %d visible rows", messages.count, rebuilt, indexed, visibleRows))
    }

    private static func check(_ store: TeamsReaderStore) {
        let messages = store.messages(in: "fixture")
        precondition(!messages.isEmpty)
        for (offset, message) in messages.enumerated() {
            precondition(store.messageIndex(of: message.id, in: "fixture") == offset, "Message index differs from timeline order")
        }
    }

    private static func observe(_ read: () -> Void) -> ChangeFlag {
        let flag = ChangeFlag()
        withObservationTracking(read) { flag.mark() }
        return flag
    }

    private static func medianMicroseconds(_ work: () -> Int) -> Double {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<renders {
            let start = clock.now
            precondition(work() > 0)
            let elapsed = start.duration(to: clock.now).components
            samples.append(Double(elapsed.seconds) * 1_000_000 + Double(elapsed.attoseconds) / 1_000_000_000_000)
        }
        return samples.sorted()[samples.count / 2]
    }

    private static func message(_ index: Int, content: String? = nil, version: String = "1", deleted: Bool = false) -> TeamsWebMessage {
        .init(id: String(1_800_000_000_000 + index),
              content: content ?? "<p><strong>Fictional message \(index)</strong> Xin chào 👋 <a href=\"https://example.com/fixture\">Reference</a></p><blockquote>Fictional quoted content</blockquote>",
              messageType: "RichText/Html", imDisplayName: account, from: .string("8:orgid:" + account),
              originalArrivalTime: String(1_800_000_000_000 + index), version: version,
              properties: deleted ? .object(["deletetime": .number(1)]) : nil)
    }

    private static func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional",
              expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Fictional account",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fictional", expiresAt: .distantFuture))
    }
}
