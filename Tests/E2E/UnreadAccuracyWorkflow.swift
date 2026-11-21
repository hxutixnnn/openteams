import Foundation
import TeamsCore

private actor UnreadTransport: HTTPTransport {
    private let original: TeamsWebMessage
    private var preview: TeamsWebMessage
    private var isRead = false
    private var horizon = "1;1;0"
    private var listUnavailable = false

    init(_ original: TeamsWebMessage) {
        self.original = original
        preview = original
    }

    func show(_ message: TeamsWebMessage, isRead: Bool = false) {
        preview = message
        self.isRead = isRead
    }

    func setListUnavailable(_ value: Bool) { listUnavailable = value }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body: Data
        var status = 200
        if request.httpMethod == "PUT" {
            if url.query == "name=consumptionhorizon" {
                let values = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
                horizon = values["consumptionhorizon"]!
            } else {
                precondition(url.query == "name=consumptionHorizonBookmark")
            }
            body = Data()
        } else if url.path.hasSuffix("/chats") {
            status = listUnavailable ? 503 : 200
            body = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat", isOneOnOne: true, isRead: isRead, lastMessage: preview)]))
        } else if url.path.hasSuffix("/messages") {
            body = try JSONEncoder().encode(TeamsWebMessagePage(messages: [original]))
        } else {
            precondition(url.path.hasSuffix("/conversations/chat"))
            body = Data("{\"id\":\"chat\",\"properties\":{\"consumptionhorizon\":\"\(horizon)\"}}".utf8)
        }
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct UnreadAccuracyWorkflow {
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func message(_ id: String, arrival: String? = nil, sender: String = "8:orgid:other") -> TeamsWebMessage {
            .init(id: id, content: id, from: .string(sender), originalArrivalTime: arrival)
        }
        let original = message("100", arrival: "1800000000000")
        let transport = UnreadTransport(original)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional", expiresAt: .distantFuture, accountID: "fixture", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fictional", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        var tracker = TeamsNotificationTracker()
        var notifications: [String] = []
        store.onServerChatSnapshot = { snapshot in
            let updates = tracker.update(chats: snapshot.chats, accountID: "fixture", accountScope: snapshot.accountScope)
            notifications += updates.compactMap { $0.lastMessage?.id }
        }
        await store.connect(session: session)
        await store.loadConversation("chat")
        precondition(store.conversation("chat")?.isRead == false && notifications.isEmpty)

        await transport.setListUnavailable(true)
        await store.markVisibleConversationRead("chat", messageID: original.id)
        precondition(store.conversation("chat")?.isRead == true && store.chatListError != nil)
        await transport.setListUnavailable(false)
        let atHorizon = message("101", arrival: original.originalArrivalTime)
        await transport.show(atHorizon)
        await store.refreshChats()
        precondition(store.conversation("chat")?.isRead == true && notifications.isEmpty)

        let incoming = message("102", arrival: "1800000001000")
        await transport.show(incoming)
        await store.refreshChats()
        precondition(store.conversation("chat")?.isRead == false && notifications == [incoming.id])
        await store.refreshChats()
        precondition(notifications == [incoming.id])

        await transport.show(atHorizon)
        await store.messageAction("unread", chatID: "chat", messageID: original.id)
        precondition(store.conversation("chat")?.isRead == false && notifications == [incoming.id])

        await transport.show(message("own", arrival: "1800000002000", sender: "https://example.invalid/8:ORGID:FIXTURE"))
        await store.refreshChats()
        let alreadyRead = message("read", arrival: "1800000003000")
        await transport.show(alreadyRead, isRead: true)
        await store.refreshChats()
        await transport.show(alreadyRead)
        await store.refreshChats()
        precondition(notifications == [incoming.id])

        await transport.show(message("current", arrival: "1800000005000"))
        await store.refreshChats()
        await transport.show(message("stale", arrival: "1800000004000"))
        await store.refreshChats()
        for id in ["opaque-a", "opaque-b", "opaque-a"] {
            await transport.show(message(id))
            await store.refreshChats()
        }
        precondition(notifications == [incoming.id, "current", "opaque-a", "opaque-b"])
        print("UNREAD_ACCURACY_OK: confirmed read horizon, newer unread messages, explicit unread, own messages and stale or duplicate previews")
    }
}
