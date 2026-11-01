import Foundation
import TeamsCore

private actor FictionalTransport: HTTPTransport {
    var sends = 0
    let failSend: Bool
    init(failSend: Bool) { self.failSend = failSend }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if request.httpMethod == "POST" {
            sends += 1
            if failSend { return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!) }
            let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                           headerFields: ["Location": url.absoluteString + "/1800000009999"])!
            return (try JSONEncoder().encode(["OriginalArrivalTime": "1800000009999"]), response)
        }
        if url.path.hasSuffix("/chats") {
            let page = TeamsWebChatPage(items: [.init(id: "fixture", title: "Fictional history", isOneOnOne: true)])
            return (try JSONEncoder().encode(page), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if url.path.hasSuffix("/messages") {
            let page = TeamsWebMessagePage(messages: [SendDuringCachedLoad.message(2000)])
            return (try JSONEncoder().encode(page), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        throw URLError(.unsupportedURL)
    }
}

@main struct SendDuringCachedLoad {
    static func message(_ i: Int) -> TeamsWebMessage {
        TeamsWebMessage(id: String(1_800_000_000_000 + i),
            content: "<p><strong>Fictional message \(i)</strong> Xin chào 👋</p><ol><li>First</li><li>Second</li></ol>",
            messageType: "RichText/Html", imDisplayName: "fixture-a", from: .string("8:orgid:fixture-a"),
            originalArrivalTime: String(1_800_000_000_000 + i), version: "1")
    }
    @MainActor static func main() async throws {
        for mode in ["during-conversion", "before-load", "failed-during-conversion"] { try await run(mode) }
        print("SEND_DURING_CACHED_LOAD_OK")
    }

    @MainActor static func run(_ mode: String) async throws {
        let account = "fixture-a", tenant = "fixture-tenant", chat = "fixture"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-send-race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let failSend = mode == "failed-during-conversion"
        let transport = FictionalTransport(failSend: failSend)
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        let messages = (1...2000).map { message($0) }
        try await cache.save(.init(chats: [.init(id: chat, title: "Fictional history", isOneOnOne: true)]))
        try await cache.save(.init(messages: messages, messageToken: "older"), in: chat)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        await store.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!,
                                      accessToken: "fictional", expiresAt: .distantFuture, accountID: account, tenantID: tenant,
                                      displayName: account, messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!,
                                                                            accessToken: "fictional", expiresAt: .distantFuture))
        await store.connect(session: session)
        precondition(store.connected && store.conversation(chat) != nil)
        store.composer.setDraft("Fictional message sent while loading", in: chat)
        var sendTask: Task<String?, Never>?
        var observedBeforeSend = -1
        var loadingBeforeSend = false
        var sendEnabled = false
        store.onCachedLoadTiming = { stage, _, _ in
            guard stage == "cache_read" else { return }
            store.onCachedLoadTiming = nil
            sendTask = Task { @MainActor in
                observedBeforeSend = store.messages(in: chat).count
                loadingBeforeSend = store.isLoadingConversation(chat)
                sendEnabled = store.composer.canSend(in: chat)
                return await store.sendDraft(in: chat)
            }
        }
        if mode == "before-load" {
            store.onCachedLoadTiming = nil
            sendTask = Task { @MainActor in await store.sendDraft(in: chat) }
            _ = await sendTask?.value
        }
        await store.loadConversation(chat)
        let sent = await sendTask?.value
        let saved = try await cache.history(in: chat)
        let rendered = store.messages(in: chat)
        let missing = messages.filter { old in !saved.messages.contains { $0.id == old.id } }.count
        let sends = await transport.sends
        precondition(sends == 1 && missing == 0)
        precondition(saved.messages.count == (failSend ? 2000 : 2001))
        precondition(saved.messageToken == "older" && store.hasOlderMessages(chat))
        precondition(rendered.map(\.id) == saved.messages.map(\.id))
        precondition(!store.isLoadingConversation(chat) && store.cacheWarning == nil)
        for original in messages { precondition(saved.messages.first { $0.id == original.id } == original) }
        if mode != "before-load" { precondition(observedBeforeSend == 0 && loadingBeforeSend && sendEnabled) }
        if failSend {
            precondition(sent == nil && !store.composer.draft(in: chat).isEmpty)
        } else {
            precondition(sent == "1800000009999" && store.composer.draft(in: chat).isEmpty)
            precondition(rendered.last?.id == sent && store.canEditMessage(in: chat, messageID: sent!))
        }
        print("mode=\(mode) fictional_posts=\(sends) saved=\(saved.messages.count) rendered=\(rendered.count) missing_old=\(missing) token=\(saved.messageToken!) loading=\(store.isLoadingConversation(chat))")
        store.disconnect()
    }
}
