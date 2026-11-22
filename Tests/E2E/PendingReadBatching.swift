import Foundation
import Observation
import TeamsCore

private actor ReadTransport: HTTPTransport {
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

private final class ChangeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func mark() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main @MainActor
struct PendingReadBatching {
    private static let account = "fixture-a"
    private static let tenant = "fixture-tenant"
    private static let chatCount = 1_000

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-pending-reads-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        let chats = (0..<chatCount).map { TeamsWebChat(id: "chat-\($0)", title: "Fixture \($0)", isOneOnOne: true, isRead: false) }
        try await cache.save(.init(chats: chats))
        let pending = TeamsPendingReadIntent(targetHorizon: 1)
        require(try await cache.installPendingRead(pending, in: chats[10].id))
        let finishable = TeamsPendingReadIntent(targetHorizon: 2)
        require(try await cache.installPendingRead(finishable, in: chats[20].id))
        require(try await cache.advancePendingRead(id: finishable.id, stage: .bookmarkAccepted, in: chats[20].id))
        require(try await cache.installPendingRead(TeamsPendingReadIntent(targetHorizon: 3), in: chats[chatCount - 1].id))

        let clock = ContinuousClock()
        var start = clock.now
        for chat in chats { _ = try await cache.pendingRead(in: chat.id) }
        let perChat = milliseconds(start.duration(to: clock.now))

        let store = TeamsReaderStore(cacheRoot: root, transport: ReadTransport())
        let changes = ChangeCount()
        func track() { withObservationTracking { _ = store.pendingReadChatIDs } onChange: { changes.mark() } }
        start = clock.now
        await store.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
        track()
        while !store.pendingReadChatIDs.contains(chats[chatCount - 1].id) {
            precondition(clock.now - start < .seconds(10), "Pending read scan did not finish")
            try await Task.sleep(for: .milliseconds(1))
            track()
        }
        let restored = milliseconds(start.duration(to: clock.now))
        precondition(store.pendingReadChatIDs == [chats[10].id, chats[20].id, chats[chatCount - 1].id])
        precondition(store.finishableReadChatIDs == [chats[20].id])
        precondition(changes.value <= 1, "Pending read scan published more than once")
        precondition(store.cacheWarning == nil)

        require(try await cache.advancePendingRead(id: pending.id, stage: .bookmarkAccepted, in: chats[10].id))
        require(try await cache.clearPendingRead(id: finishable.id, in: chats[20].id))
        await store.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
        start = clock.now
        while store.pendingReadChatIDs != [chats[10].id, chats[chatCount - 1].id] || store.finishableReadChatIDs != [chats[10].id] {
            precondition(clock.now - start < .seconds(10), "Pending read scan did not pick up changed intents")
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(store.pendingReadChatIDs == [chats[10].id, chats[chatCount - 1].id])
        precondition(store.finishableReadChatIDs == [chats[10].id])

        print(String(format: "PendingReadBatching passed: pending read scan for %d chats %.2f ms per chat lookups, restore complete in %.2f ms", chatCount, perChat, restored))
    }

    private static func require(_ condition: Bool) { precondition(condition) }

    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
