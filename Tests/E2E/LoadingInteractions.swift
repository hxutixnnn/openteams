import Foundation
import TeamsCore

private actor FixtureTransport: HTTPTransport {
    var requests = 0
    var writes = 0
    private var page = TeamsWebMessagePage(messages: [])
    func setPage(_ value: TeamsWebMessagePage) { page = value }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        if request.httpMethod != nil && request.httpMethod != "GET" { writes += 1 }
        let data: Data
        if request.url!.path.hasSuffix("/chats") {
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture", title: "Fictional chat", isOneOnOne: true)]))
        } else if request.url!.path.hasSuffix("/messages") {
            data = try JSONEncoder().encode(page)
        } else {
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct LoadingInteractions {
    static let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    static let tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
    static func report(_ workload: String, count: Int, times: [Double]) throws {
        let sorted = times.sorted()
        let row: [String: Any] = ["workload": workload, "messages": count, "samples_ms": times,
            "median_ms": sorted[sorted.count / 2], "min_ms": sorted.first!, "max_ms": sorted.last!]
        print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
    }
    static func message(_ index: Int, rich: Bool, marker: TeamsWebJSONValue? = nil, key: String = "deletetime") -> TeamsWebMessage {
        let html = "<p><strong>Fictional message \(index)</strong> Xin chào 👋 <a href=\"https://example.com/fixture\">Reference</a></p><ol><li>First item</li><li><em>Second item</em></li></ol><blockquote>Fictional quoted content</blockquote>"
        return TeamsWebMessage(id: String(1_800_000_000_000 + index), content: rich ? html : "Fictional message \(index)",
            messageType: rich ? "RichText/Html" : "Text", imDisplayName: "Alex Example", from: .string("8:orgid:" + account),
            originalArrivalTime: String(1_800_000_000_000 + index), version: "1",
            properties: marker.map { .object([key: $0]) })
    }
    static func session(_ id: String = account) -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional",
              expiresAt: .distantFuture, accountID: id, tenantID: tenant, displayName: "Fictional account",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fictional", expiresAt: .distantFuture))
    }

    @MainActor static func main() async throws {
        for rich in [false, true] {
            for count in [200, 2000] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-load-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let transport = FixtureTransport()
                let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
                let raw = (0..<count).map { message($0, rich: rich) }
                let history = TeamsCachedHistory(messages: raw, messageToken: "older")
                try await cache.save(.init(chats: [.init(id: "fixture", title: "Fictional chat", isOneOnOne: true)]))
                try await cache.save(history, in: "fixture")
                let store = TeamsReaderStore(cacheRoot: root, transport: transport)
                var start = ContinuousClock.now
                await store.restoreAccount(accountID: account, tenantID: tenant, displayName: "Fictional account")
                try report("cached_list_\(rich ? "rich" : "plain")", count: count, times: [elapsed(start)])
                precondition(store.chats.count == 1 && store.messages(in: "fixture").isEmpty)
                start = .now
                await store.loadConversation("fixture")
                try report("cold_cached_conversation_\(rich ? "rich" : "plain")", count: count, times: [elapsed(start)])
                let expected = raw.map { TeamsRenderedMessage($0) }
                precondition(store.messages(in: "fixture") == expected)
                start = .now
                await store.loadConversation("fixture")
                try report("warm_cached_conversation_\(rich ? "rich" : "plain")", count: count, times: [elapsed(start)])
                let initialRequests = await transport.requests
                precondition(initialRequests == 0)
                await store.connect(session: session())
                precondition(store.connected && store.messages(in: "fixture") == expected)
                let viewport = raw.suffix(30).map(\.id)
                var times: [Double] = []
                for sample in -2..<10 {
                    start = .now
                    var enabled = 0
                    for id in viewport {
                        if store.canDelete(in: "fixture", messageID: id) { enabled += 1 }
                        precondition(store.canEditMessage(in: "fixture", messageID: id))
                        precondition(store.canReact(in: "fixture", messageID: id))
                    }
                    let time = elapsed(start)
                    precondition(enabled == viewport.count)
                    if sample >= 0 { times.append(time) }
                }
                try report("viewport30_actions_\(rich ? "rich" : "plain")", count: count, times: times)
                let saved = try await cache.history(in: "fixture")
                precondition(saved.messages == raw)
                let writes = await transport.writes
                precondition(writes == 0)
                store.disconnect()
                precondition(!store.canDelete(in: "fixture", messageID: viewport.last!))
                await store.restoreAccount(accountID: "other-account", tenantID: tenant, displayName: "Other")
                precondition(store.messages(in: "fixture").isEmpty)
                await store.restoreAccount(accountID: account, tenantID: tenant, displayName: "Fictional account")
                await store.loadConversation("fixture")
                precondition(store.messages(in: "fixture") == expected)
            }
        }
        try await verifyMarkers()
        print("E2E_OK")
    }

    @MainActor static func verifyMarkers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-delete-e2e-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FixtureTransport()
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        let markers: [(TeamsWebJSONValue?, Bool)] = [(nil, false), (.number(1), true), (.number(0), false), (.number(-1), false),
            (.string("1"), true), (.string("0"), false), (.string(""), false), (.string("false"), false), (.string("False"), true),
            (.bool(true), true), (.bool(false), false), (.null, false), (.array([]), false), (.object([:]), false)]
        var raw: [TeamsWebMessage] = [], deleted: [Bool] = []
        for key in ["deletetime", "deleteTime"] {
            for rich in [false, true] {
                for (marker, expected) in markers {
                    raw.append(message(raw.count, rich: rich, marker: marker, key: key)); deleted.append(expected)
                }
            }
        }
        try await cache.save(.init(messages: raw, messageToken: "older"), in: "fixture")
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await transport.setPage(.init(messages: [raw[0]], messageToken: "older"))
        await store.connect(session: session())
        await store.loadConversation("fixture")
        precondition(store.messages(in: "fixture").map(\.isDeleted) == deleted)
        for (message, expected) in zip(raw, deleted) {
            precondition(store.canDelete(in: "fixture", messageID: message.id) == !expected)
        }
        precondition(!store.canDelete(in: "fixture", messageID: "missing"))
        store.disconnect()
        let recovered = TeamsReaderStore(cacheRoot: root, transport: transport)
        await recovered.connect(session: session())
        await recovered.loadConversation("fixture")
        precondition(recovered.messages(in: "fixture").map(\.isDeleted) == deleted)
        for (message, expected) in zip(raw, deleted) {
            precondition(recovered.canDelete(in: "fixture", messageID: message.id) == !expected)
        }
        let changed = message(0, rich: true, marker: .number(1))
        let appended = message(raw.count + 10, rich: true)
        await transport.setPage(.init(messages: [changed, appended]))
        await recovered.refreshConversation("fixture")
        precondition(!recovered.canDelete(in: "fixture", messageID: changed.id))
        precondition(!recovered.canReact(in: "fixture", messageID: changed.id))
        precondition(recovered.canDelete(in: "fixture", messageID: appended.id))
        precondition(recovered.canReact(in: "fixture", messageID: appended.id))
        let older = message(-10, rich: true)
        await transport.setPage(.init(messages: [older]))
        await recovered.loadOlderMessages("fixture")
        precondition(recovered.messages(in: "fixture").first?.id == older.id)
        precondition(recovered.canDelete(in: "fixture", messageID: appended.id))
        precondition(recovered.canEditMessage(in: "fixture", messageID: appended.id))
        precondition(recovered.canReact(in: "fixture", messageID: appended.id))
        let intent = TeamsPendingDeletion(original: appended)
        let installed = try await cache.installPendingDeletion(intent, in: "fixture")
        precondition(installed)
        await recovered.loadDeletionStatus(in: "fixture", messageID: appended.id, expectedScope: recovered.accountScope, expectedRevision: recovered.accountRevision)
        precondition(!recovered.canDelete(in: "fixture", messageID: appended.id))
        precondition(!recovered.canEditMessage(in: "fixture", messageID: appended.id))
        let rejected = try await cache.updatePendingDeletion(id: intent.id, in: "fixture", messageID: appended.id, expected: .prepared, stage: .rejected)
        precondition(rejected)
        await recovered.loadDeletionStatus(in: "fixture", messageID: appended.id, expectedScope: recovered.accountScope, expectedRevision: recovered.accountRevision)
        precondition(recovered.canDelete(in: "fixture", messageID: appended.id))
        let saved = try await cache.history(in: "fixture")
        precondition(saved.messages.first?.id == older.id && saved.messages.last?.id == appended.id)
        let changedSaved = saved.messages.first { $0.id == changed.id }
        precondition(changedSaved == changed)
        let writes = await transport.writes
        precondition(writes == 0)
    }
}
