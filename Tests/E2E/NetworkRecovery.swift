import Foundation
import TeamsCore

private actor RecoveryTransport: HTTPTransport {
    var failures: Int
    let status: Int?
    let empty: Bool
    var chatRequests = 0
    var holdMessages = false
    var held: CheckedContinuation<Void, Never>?
    init(failures: Int = 0, status: Int? = nil, empty: Bool = false) {
        self.failures = failures; self.status = status; self.empty = empty
    }
    func holdNextMessages() { holdMessages = true }
    func releaseMessages() { held?.resume(); held = nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        var code = 200
        let data: Data
        if url.path.hasSuffix("/chats") {
            chatRequests += 1
            if failures > 0 {
                failures -= 1
                guard let status else { throw URLError(.notConnectedToInternet) }
                code = status
            }
            data = try JSONEncoder().encode(TeamsWebChatPage(items: empty ? [] : [.init(id: "fixture", title: "Recovery", isOneOnOne: true)]))
        } else if url.path.hasSuffix("/messages") {
            let stale = holdMessages
            if stale {
                holdMessages = false
                await withCheckedContinuation { held = $0 }
            }
            let message = TeamsWebMessage(id: stale ? "1800000000001" : "1800000000002", content: stale ? "Stale" : "Fresh", messageType: "Text")
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [message], messageToken: stale ? "oldest" : "older"))
        } else { throw URLError(.unsupportedURL) }
        return (data, HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct NetworkRecovery {
    static func session(_ token: String = "fictional") -> TeamsWebSession {
        TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!,
                        accessToken: token, expiresAt: .distantFuture, accountID: "fixture-a", tenantID: "fixture-tenant",
                        displayName: "Recovery", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!,
                                                               accessToken: token, expiresAt: .distantFuture))
    }
    @MainActor static func main() async throws {
        for (failures, status, empty) in [(0, nil, false), (2, nil, false), (1, nil, true), (1, 408, false), (1, 503, false), (1, 403, false)] as [(Int, Int?, Bool)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-recovery-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = RecoveryTransport(failures: failures, status: status, empty: empty)
            let store = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
            await store.connect(session: session())
            if failures > 0 && status != 403 {
                precondition(store.isReconnecting && store.chatListError != nil)
                let deadline = Date().addingTimeInterval(15)
                while store.isReconnecting && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
                precondition(!store.isReconnecting && store.chatListError == nil)
                let requests = await transport.chatRequests
                precondition(requests == failures + 1)
            } else if status == 403 {
                precondition(!store.isReconnecting && store.chatListError != nil)
                try await Task.sleep(for: .seconds(3))
                let requests = await transport.chatRequests
                precondition(requests == 1)
            }
            if status != 403 { precondition(store.chats.count == (empty ? 0 : 1)) }
            store.disconnect()
            precondition(!store.isReconnecting)
            print("recovery failures=\(failures) status=\(status ?? 200) empty=\(empty) OK")
        }
        try await staleSession()
        print("NETWORK_RECOVERY_OK")
    }
    @MainActor static func staleSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-session-race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecoveryTransport()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        let cache = TeamsReadCache(root: root, accountID: "fixture-a", tenantID: "fixture-tenant")
        await store.connect(session: session())
        for older in [false, true] {
            if older { await store.refreshConversation("fixture") }
            await transport.holdNextMessages()
            let request = Task { @MainActor in
                if older { await store.loadOlderMessages("fixture") } else { await store.refreshConversation("fixture") }
            }
            let deadline = Date().addingTimeInterval(5)
            while await transport.held == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let waiting = await transport.held != nil
            precondition(waiting)
            await store.connect(session: session("renewed"))
            await transport.releaseMessages()
            await request.value
            precondition(!store.messages(in: "fixture").contains { $0.id == "1800000000001" })
            let saved = try await cache.history(in: "fixture")
            precondition(!saved.messages.contains { $0.id == "1800000000001" })
            await store.refreshConversation("fixture")
            precondition(store.messages(in: "fixture").map(\.id) == ["1800000000002"])
            print("stale session older=\(older) rejected OK")
        }
        store.disconnect()
    }
}
