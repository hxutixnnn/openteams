import Foundation
import Observation
import TeamsCore

private actor LookupTransport: HTTPTransport {
    private var page = Data("{\"items\":[]}".utf8)
    private let known = TeamsWebChat(id: "created", title: "Replacement")
    private var failing = false
    private var horizon = "1;1;0"

    func show(_ chats: [TeamsWebChat], failing: Bool = false) throws {
        page = try JSONEncoder().encode(TeamsWebChatPage(items: chats))
        self.failing = failing
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let data: Data
        if request.httpMethod == "PUT" {
            let values = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            horizon = values["consumptionhorizon"] ?? horizon
            data = Data("{}".utf8)
        } else if url.path.hasSuffix("/chats") {
            if failing { throw URLError(.notConnectedToInternet) }
            data = page
        } else if url.path.hasSuffix("/messages") {
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [ConversationLookup.message(0)]))
        } else if url.path.contains("/conversations/") {
            data = Data("{\"id\":\"\(url.lastPathComponent)\",\"version\":\"1\",\"properties\":{\"consumptionhorizon\":\"\(horizon)\",\"consumptionHorizonBookmark\":\"0;1;0\"}}".utf8)
        } else if url.path.hasSuffix("/created") {
            data = try JSONEncoder().encode(known)
        } else { throw URLError(.unsupportedURL) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class LookupChange: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    func mark() {
        lock.lock()
        defer { lock.unlock() }
        changed = true
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return changed
    }
}

@main struct ConversationLookup {
    static func message(_ index: Int) -> TeamsWebMessage {
        let id = String(1_800_000_000_000 + index)
        return .init(id: id, content: "<p>Fictional message \(index)</p>", messageType: "RichText/Html", imDisplayName: "Fixture User", from: .string("8:orgid:other"), originalArrivalTime: id, version: "1")
    }

    static func chat(_ index: Int, title: String? = nil, deleted: Bool = false) -> TeamsWebChat {
        .init(id: "chat-\(index)", title: title ?? "Fixture \(index)", isOneOnOne: true, isRead: false, isConversationDeleted: deleted, lastMessage: message(index))
    }

    static func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional", expiresAt: .distantFuture, accountID: "fixture", tenantID: "tenant", displayName: "Fixture",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fictional", expiresAt: .distantFuture))
    }

    @MainActor static func verify(_ store: TeamsReaderStore, ids: [String]) {
        for id in ids + store.chats.map(\.id) + ["48:notes", "absent", ""] {
            let expected = id == "48:notes" ? store.selfChat : store.chats.first { $0.id == id }
            precondition(store.conversation(id) == expected, "Lookup mismatch for \(id)")
        }
    }

    @MainActor static func equivalence(root: URL) async throws {
        let transport = LookupTransport()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let cache = TeamsReadCache(root: root, accountID: "fixture", tenantID: "tenant")
        let ids = ["duplicate", "chat-0", "chat-1", "chat-2", "chat-3", "created", "other", "é", "e\u{301}", "Case", "case"]
        verify(store, ids: ids)
        precondition(store.conversation("48:notes") == nil)
        let duplicates: [TeamsWebChat] = [.init(id: "duplicate", title: "First"), chat(0), .init(id: "duplicate", title: "Last"), .init(id: "48:notes", title: "Not the self chat"), .init(id: "", title: "Empty ID"), .init(id: "é", title: "Composed"), .init(id: "e\u{301}", title: "Decomposed"), .init(id: "Case"), .init(id: "case")]
        for values in [duplicates, Array(duplicates.reversed()), [.init(id: "duplicate", title: "Replaced")], []] {
            try await cache.save(.init(chats: values))
            await store.restoreAccount(accountID: "fixture", tenantID: "tenant", displayName: "Fixture")
            precondition(store.chats == values)
            verify(store, ids: ids)
        }
        try await transport.show([chat(0), chat(1), chat(2)])
        await store.connect(session: session())
        precondition(store.chats.count == 3 && store.chatListError == nil)
        verify(store, ids: ids)
        let hit = LookupChange(), miss = LookupChange()
        withObservationTracking { _ = store.conversation("chat-0") } onChange: { hit.mark() }
        withObservationTracking { _ = store.conversation("chat-3") } onChange: { miss.mark() }
        try await transport.show([chat(0, title: "Updated"), chat(1, deleted: true), chat(3)])
        await store.refreshChats()
        precondition(hit.value && miss.value)
        precondition(store.conversation("chat-0")?.title == "Updated" && store.conversation("chat-1") == nil)
        precondition(store.chats.map(\.id) == ["chat-3", "chat-2", "chat-0"])
        verify(store, ids: ids)
        await store.loadConversation("chat-0")
        await store.markVisibleConversationRead("chat-0", messageID: message(0).id)
        precondition(store.conversation("chat-0")?.isRead == true)
        verify(store, ids: ids)
        let operation = UUID()
        let reviewData = try JSONSerialization.data(withJSONObject: ["operationID": operation.uuidString, "state": "known", "threadID": "created", "status": 201, "title": "Created fixture"])
        let review = try JSONDecoder().decode(TeamsReaderStore.CreationReview.self, from: reviewData)
        let saved = try await cache.updateCreationReview(expectedID: nil, review: review)
        precondition(saved)
        await store.restoreAccount(accountID: "fixture", tenantID: "tenant", displayName: "Renamed")
        store.ensureKnownCreationVisible()
        store.ensureKnownCreationVisible()
        precondition(store.chats.first?.id == "created" && store.chats.filter { $0.id == "created" }.count == 1)
        verify(store, ids: ids)
        await store.connect(session: session())
        try await store.refreshKnownCreation("created", expectedAccount: store.accountScope, expectedRevision: store.accountRevision)
        precondition(store.chats.first?.id == "created" && store.conversation("created")?.title == "Replacement")
        verify(store, ids: ids)
        let before = store.chats
        try await transport.show([], failing: true)
        await store.refreshChats()
        precondition(store.chatListError != nil && store.chats == before)
        verify(store, ids: ids)
        store.disconnect()
        verify(store, ids: ids)
        let otherCache = TeamsReadCache(root: root, accountID: "other", tenantID: "other-tenant")
        try await otherCache.save(.init(chats: [.init(id: "other", title: "Other account"), .init(id: "chat-0", title: "Other version")]))
        await store.restoreAccount(accountID: "other", tenantID: "other-tenant", displayName: "Other")
        precondition(store.chats.count == 2 && store.conversation("chat-0")?.title == "Other version")
        verify(store, ids: ids)
        let unchanged = store.chats
        await store.restoreAccount(accountID: "", tenantID: "", displayName: "Ignored")
        precondition(store.chats == unchanged)
        await store.restoreAccount(accountID: "empty", tenantID: "tenant", displayName: "Empty")
        precondition(store.chats.isEmpty && store.conversation("48:notes")?.title == "Empty (You)")
        verify(store, ids: ids)
        print("CONVERSATION_LOOKUP_EQUIVALENCE_OK: empty, first duplicates, Unicode IDs, missing, notes, restore, replace, insert, remove, reorder, element mutation, account switch, observation hit and miss, network error")
    }

    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }

    static func report(_ name: String, milliseconds: Double, sink: Int, samples: [Double]? = nil) throws {
        var row: [String: Any] = ["name": name, "count": 1000, "ms": milliseconds, "sink": sink]
        if let samples { row["samples_ms"] = samples }
        print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
    }

    @MainActor static func benchmark(root: URL) async throws {
        let chats = (0..<1000).map { chat($0) }
        var refreshes: [Double] = []
        var populated: TeamsReaderStore?
        for sample in -1..<9 {
            let transport = LookupTransport()
            try await transport.show([])
            let store = TeamsReaderStore(cacheRoot: root.appendingPathComponent(String(sample)), transport: transport)
            await store.connect(session: session())
            precondition(store.chats.isEmpty && store.chatListError == nil)
            try await transport.show(chats)
            let start = ContinuousClock.now
            await store.refreshChats()
            let refresh = milliseconds(start)
            precondition(store.chatListError == nil && store.chats.count == 1000)
            if sample >= 0 { refreshes.append(refresh) }
            if sample == 8 { populated = store } else { store.disconnect() }
        }
        let store = populated!
        try report("full_refresh", milliseconds: refreshes.sorted()[refreshes.count / 2], sink: store.chats.count, samples: refreshes)
        let ids = store.chats.map(\.id)
        for (name, keys) in [("lookup_sweep", ids), ("lookup_first", Array(repeating: ids.first!, count: 1000)), ("lookup_last", Array(repeating: ids.last!, count: 1000)), ("lookup_missing", Array(repeating: "absent", count: 1000))] {
            let start = ContinuousClock.now
            var sink = 0
            for id in keys { sink += store.conversation(id)?.title?.utf8.count ?? 0 }
            let elapsed = milliseconds(start)
            precondition(name == "lookup_missing" ? sink == 0 : sink > 0)
            try report(name, milliseconds: elapsed, sink: sink)
        }
        verify(store, ids: ids)
        store.disconnect()
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-conversation-lookup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        if !CommandLine.arguments.contains("--benchmark") { try await equivalence(root: root.appendingPathComponent("equivalence")) }
        try await benchmark(root: root.appendingPathComponent("benchmark"))
        print("CONVERSATION_LOOKUP_OK")
    }
}
