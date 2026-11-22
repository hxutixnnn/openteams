import Foundation
import Observation
import TeamsCore

private actor RankTransport: HTTPTransport {
    private var page = Data("{\"items\":[]}".utf8)

    func show(_ chats: [TeamsWebChat]) throws { page = try JSONEncoder().encode(TeamsWebChatPage(items: chats)) }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let data: Data
        if url.path.hasSuffix("/chats") {
            data = page
        } else if url.path.hasSuffix("/messages") {
            data = Data("{\"messages\":[]}".utf8)
        } else if url.path.contains("/conversations/") {
            data = Data("{\"id\":\"\(url.lastPathComponent)\",\"version\":\"1\",\"properties\":{\"consumptionhorizon\":\"1;1;0\"}}".utf8)
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
struct ChatRankSharing {
    private static let chatCount = 1_000
    private static let renders = 2_000

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RankTransport()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        try await transport.show((0..<chatCount).map { chat($0) })
        await store.connect(session: session())
        precondition(store.chats.count == chatCount)
        check(store)

        let reorder = observe { _ = store.chatRanks }
        precondition(store.chatRanks["chat-0"] == chatCount - 1)
        try await transport.show((0..<chatCount).map { chat($0, newest: $0 == 0) })
        await store.refreshChats()
        precondition(reorder.value && store.chatRanks["chat-0"] == 0)
        check(store)

        let removal = observe { _ = store.chatRanks }
        try await transport.show((0..<chatCount).map { chat($0, newest: $0 == 0, deleted: $0 == 0) })
        await store.refreshChats()
        precondition(removal.value && store.chatRanks["chat-0"] == nil)
        check(store)
        precondition(store.chatRanks["absent"] == nil)

        let rebuilt = medianMicroseconds { reference(store).count }
        let shared = medianMicroseconds { store.chatRanks.count }
        print(String(format: "ChatRankSharing passed: chat rank map per folder render with %d chats %.2f us -> %.3f us", store.chats.count, rebuilt, shared))
    }

    private static func reference(_ store: TeamsReaderStore) -> [String: Int] {
        Dictionary(store.chats.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    private static func check(_ store: TeamsReaderStore) {
        precondition(store.chatRanks == reference(store), "Chat ranks differ from chat order")
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

    private static func chat(_ index: Int, newest: Bool = false, deleted: Bool = false) -> TeamsWebChat {
        let arrival = String(1_800_000_000_000 + (newest ? chatCount : index))
        let message = TeamsWebMessage(id: arrival, content: "<p>Fixture \(index)</p>", messageType: "RichText/Html", originalArrivalTime: arrival)
        return .init(id: "chat-\(index)", title: "Fixture \(index)", isOneOnOne: true, isRead: true, isConversationDeleted: deleted, lastMessage: message)
    }

    private static func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional", expiresAt: .distantFuture, accountID: "fixture", tenantID: "tenant", displayName: "Fixture",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fictional", expiresAt: .distantFuture))
    }
}
