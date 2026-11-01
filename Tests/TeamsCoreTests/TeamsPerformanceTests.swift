import Foundation
import Testing
@testable import TeamsCore

private actor PerformanceFixtureTransport: HTTPTransport {
    private let chats: Data
    private var messages: Data
    private(set) var chatRequests = 0
    private(set) var messageRequests = 0

    init(chat: TeamsWebChat, messages: [TeamsWebMessage]) throws {
        chats = try JSONEncoder().encode(TeamsWebChatPage(items: [chat]))
        self.messages = try JSONEncoder().encode(TeamsWebMessagePage(messages: messages))
    }

    func replaceMessages(_ messages: [TeamsWebMessage]) throws {
        self.messages = try JSONEncoder().encode(TeamsWebMessagePage(messages: messages))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.httpMethod == "GET", let url = request.url else { throw URLError(.badURL) }
        let data: Data
        if url.path.hasSuffix("/messages") { data = messages; messageRequests += 1 }
        else if url.path.hasSuffix("/chats") { data = chats; chatRequests += 1 }
        else { throw URLError(.unsupportedURL) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
struct TeamsPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENTEAMS_PERFORMANCE"] == "1"))
    func cachedTimelineWorkloads() async throws {
        let count = 1_000
        let samples = 5
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let chat = TeamsWebChat(id: "performance-fixture", title: "Fixture conversation", isOneOnOne: true,
                                members: [.init(mri: "8:orgid:fixture", displayName: "Fixture Person")])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let messages = (0..<count).map { index in
            TeamsWebMessage(id: String(1_800_000_000_000 + index),
                            content: "<p>Fixture message \(index): <b>release review</b> with <a href='https://example.com/\(index)'>details</a> and tiếng Việt 👋.</p><blockquote>Earlier discussion</blockquote><ul><li>Check layout</li><li>Check behavior</li></ul>",
                            messageType: "RichText/Html", from: .string("8:orgid:fixture"),
                            originalArrivalTime: formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))),
                            version: "1")
        }
        let overlap = Array(messages.suffix(50))
        var mergeTimes: [Double] = []
        for sample in -1..<samples {
            var history = TeamsCachedHistory(messages: messages)
            let start = ContinuousClock.now
            history.merge(overlap)
            let elapsed = milliseconds(start.duration(to: .now))
            if sample >= 0 { mergeTimes.append(elapsed) }
            #expect(history.messages == messages)
        }
        report("merge_1000_overlap50", mergeTimes)

        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        try await cache.save(.init(chats: [chat]))
        try await cache.save(.init(messages: messages), in: chat.id)
        let transport = try PerformanceFixtureTransport(chat: chat, messages: overlap)
        var coldTimes: [Double] = []
        for sample in -1..<samples {
            let coldStore = TeamsReaderStore(cacheRoot: root, transport: transport)
            await coldStore.restoreAccount(accountID: account, tenantID: tenant, displayName: "Fixture Person")
            let start = ContinuousClock.now
            await coldStore.loadConversation(chat.id)
            let elapsed = milliseconds(start.duration(to: .now))
            if sample >= 0 { coldTimes.append(elapsed) }
            #expect(coldStore.messages(in: chat.id).map(\.id) == messages.map(\.id))
            #expect(coldStore.cacheWarning == nil)
        }
        report("cold_cached_load_1000", coldTimes)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.restoreAccount(accountID: account, tenantID: tenant, displayName: "Fixture Person")
        await store.loadConversation(chat.id)
        await store.connect(session: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!,
                                          accessToken: "fixture-only", expiresAt: .distantFuture,
                                          accountID: account, tenantID: tenant, displayName: "Fixture Person"))
        var listTimes: [Double] = []
        for sample in -1..<samples {
            let start = ContinuousClock.now
            await store.refreshChats()
            let elapsed = milliseconds(start.duration(to: .now))
            if sample >= 0 { listTimes.append(elapsed) }
            #expect(store.chatListError == nil)
        }
        report("unchanged_chat_list_loaded1000", listTimes)

        var refreshTimes: [Double] = []
        for sample in -1..<samples {
            let start = ContinuousClock.now
            await store.refreshConversation(chat.id)
            let elapsed = milliseconds(start.duration(to: .now))
            if sample >= 0 { refreshTimes.append(elapsed) }
            #expect(store.chatErrors[chat.id] == nil)
            #expect(store.messages(in: chat.id).map(\.id) == messages.map(\.id))
        }
        report("unchanged_conversation_1000_overlap50", refreshTimes)

        var editTimes: [Double] = []
        let last = try #require(messages.last)
        for sample in -1..<samples {
            let edited = TeamsWebMessage(id: last.id, content: "<p>Edited fixture \(sample)</p>",
                                         messageType: last.messageType, from: last.from,
                                         originalArrivalTime: last.originalArrivalTime, version: String(sample + 3),
                                         properties: .object(["edittime": .number(1)]))
            try await transport.replaceMessages(Array(overlap.dropLast()) + [edited])
            let start = ContinuousClock.now
            await store.refreshConversation(chat.id)
            let elapsed = milliseconds(start.duration(to: .now))
            if sample >= 0 { editTimes.append(elapsed) }
            #expect(store.chatErrors[chat.id] == nil)
            #expect(store.messages(in: chat.id).last?.body.text == "Edited fixture \(sample)")
            #expect(store.messages(in: chat.id).last?.isEdited == true)
        }
        report("single_edit_1000_overlap50", editTimes)
        #expect(await transport.chatRequests == samples + 2)
        #expect(await transport.messageRequests == 2 * (samples + 1))
        let saved = try await cache.history(in: chat.id)
        #expect(saved.messages.map(\.id) == messages.map(\.id))
        #expect(saved.messages.dropLast() == messages.dropLast())
        #expect(TeamsRenderedMessage(try #require(saved.messages.last)).body.text == "Edited fixture \(samples - 1)")
        #expect(store.cacheWarning == nil)
        store.disconnect()
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func report(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        let line = "PERF \(name) median_ms=\(sorted[sorted.count / 2]) samples_ms=\(values)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
