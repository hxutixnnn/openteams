import Foundation
import Observation
import TeamsCore

private actor StabilityTransport: HTTPTransport {
    private var page = Data("{\"items\":[]}".utf8)
    private let history: Data

    init(history: [TeamsWebMessage]) throws {
        self.history = try JSONEncoder().encode(TeamsWebMessagePage(messages: history))
    }

    func show(_ chats: [TeamsWebChat]) throws { page = try JSONEncoder().encode(TeamsWebChatPage(items: chats)) }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let data: Data
        if request.httpMethod == "PUT" {
            data = Data("{}".utf8)
        } else if url.path.hasSuffix("/chats") {
            data = page
        } else if url.path.hasSuffix("/messages") {
            data = history
        } else if url.path.contains("/conversations/") {
            data = Data("{\"id\":\"\(url.lastPathComponent)\",\"version\":\"1\",\"properties\":{\"consumptionhorizon\":\"1;1;0\",\"consumptionHorizonBookmark\":\"0;1;0\"}}".utf8)
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
struct IdentityListStability {
    private static let chatCount = 1_000
    private static let renders = 2_000

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try StabilityTransport(history: (0..<200).map(message))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        try await transport.show((0..<chatCount).map { chat($0) })
        await store.connect(session: session())
        precondition(store.chats.count == chatCount && store.chatIDs == store.chats.map(\.id))

        let stableIDs = store.chatIDs
        let stableChats = observe { _ = store.chats }
        let stableIDChange = observe { _ = store.chatIDs }
        try await transport.show((0..<chatCount).map { chat($0, title: "Renamed \($0)") })
        await store.refreshChats()
        precondition(stableChats.value && store.chats.first?.title?.hasPrefix("Renamed") == true)
        precondition(!stableIDChange.value && sameStorage(store.chatIDs, stableIDs))

        let removal = observe { _ = store.chatIDs }
        try await transport.show((0..<chatCount).map { chat($0, title: "Renamed \($0)", deleted: $0 == 0) })
        await store.refreshChats()
        precondition(removal.value && store.chatIDs == store.chats.map(\.id) && !store.chatIDs.contains("chat-0"))

        let chatID = store.chatIDs[0]
        await store.loadConversation(chatID)
        let messageIDs = store.messageIDs(in: chatID)
        precondition(messageIDs.count == 200 && messageIDs == store.messages(in: chatID).map(\.id))
        let stableMessageIDs = observe { _ = store.messageIDs(in: chatID) }
        await store.refreshConversation(chatID)
        precondition(!stableMessageIDs.value && sameStorage(store.messageIDs(in: chatID), messageIDs))
        precondition(store.messageIDs(in: "absent").isEmpty)

        let previousMapped = store.chats.map(\.id)
        let previousPublished = store.chatIDs
        let mapped = medianMicroseconds { store.chats.map(\.id) == previousMapped }
        let published = medianMicroseconds { store.chatIDs == previousPublished }
        print(String(format: "IdentityListStability passed: chat ID change check per render with %d chats %.2f us -> %.3f us", chatCount - 1, mapped, published))
    }

    private static func observe(_ read: () -> Void) -> ChangeFlag {
        let flag = ChangeFlag()
        withObservationTracking(read) { flag.mark() }
        return flag
    }

    private static func sameStorage(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.withUnsafeBufferPointer { left in rhs.withUnsafeBufferPointer { left.baseAddress == $0.baseAddress } }
    }

    private static func medianMicroseconds(_ check: () -> Bool) -> Double {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<renders {
            let start = clock.now
            precondition(check())
            let elapsed = start.duration(to: clock.now).components
            samples.append(Double(elapsed.seconds) * 1_000_000 + Double(elapsed.attoseconds) / 1_000_000_000_000)
        }
        return samples.sorted()[samples.count / 2]
    }

    private static func message(_ index: Int) -> TeamsWebMessage {
        let id = String(1_800_000_000_000 + index)
        return .init(id: id, content: "<p>Fictional message \(index)</p>", messageType: "RichText/Html", imDisplayName: "Fixture User", from: .string("8:orgid:other"), originalArrivalTime: id, version: "1")
    }

    private static func chat(_ index: Int, title: String? = nil, deleted: Bool = false) -> TeamsWebChat {
        .init(id: "chat-\(index)", title: title ?? "Fixture \(index)", isOneOnOne: true, isRead: true, isConversationDeleted: deleted, lastMessage: message(index))
    }

    private static func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional", expiresAt: .distantFuture, accountID: "fixture", tenantID: "tenant", displayName: "Fixture",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fictional", expiresAt: .distantFuture))
    }
}
