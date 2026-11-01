#if DEBUG
import AppKit
import Observation
import SwiftUI
import TeamsCore

@MainActor enum TeamsPerformanceFixtureConfiguration {
    static let enabled = Bundle.main.object(forInfoDictionaryKey: "OpenTeamsPerformanceFixtureRoot") != nil || ProcessInfo.processInfo.arguments.contains("--performance-fixture")
    static let defaults = UserDefaults(suiteName: "OpenTeams.performance-fixture." + UUID().uuidString)!
    static let root: URL? = {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "OpenTeamsPerformanceFixtureRoot") as? String else { return nil }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard root.path.hasPrefix(temporary.path + "/"),
              root.lastPathComponent.hasPrefix("openteams-app-e2e-"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.json").path) else { return nil }
        return root
    }()
}

private actor PerformanceFixtureTransport: HTTPTransport {
    private let allowsSend: Bool
    private var sentMessages: [String: [TeamsWebMessage]] = [:]
    private var nextSentID: Int64 = 1_800_000_010_000
    init(allowsSend: Bool) { self.allowsSend = allowsSend }
    func reserveSendIDs(_ messages: [TeamsWebMessage]) {
        for message in messages {
            if let id = Int64(message.id) { nextSentID = max(nextSentID, id) }
        }
    }
    private var newest = 100
    func cachedMessages(count: Int, account: String) -> [TeamsWebMessage] {
        (81...(80 + count)).map { index in
            TeamsWebMessage(id: String(1_800_000_000_000 + index),
                content: "<p><strong>Fictional cached message \(index) · \(account)</strong> Xin chào 👋 <a href=\"https://example.com/fixture\">Reference</a></p><ol><li>First item</li><li><em>Second item</em></li></ol>",
                messageType: "RichText/Html", imDisplayName: "Alex Example", from: .string("8:orgid:" + account),
                originalArrivalTime: String(1_800_000_000_000 + index), version: "1")
        }
    }
    private struct MessageTarget: Hashable {
        let account: String
        let chat: String
        let id: String
    }
    private var deleted: Set<MessageTarget> = []
    private var edits: [MessageTarget: TeamsWebMessage] = [:]
    private var likedAccounts: Set<String> = []

    func append() { newest += 1 }

    private func message(_ index: Int, account: String, chat: String = "fixture-one") -> TeamsWebMessage {
        let id = String(1_800_000_000_000 + index)
        let target = MessageTarget(account: account, chat: chat, id: id)
        let edited = edits[target]
        if deleted.contains(target) {
            return TeamsWebMessage(id: id, content: edited?.content ?? "Fictional message \(index)",
                messageType: edited?.messageType ?? "Text", imDisplayName: "Alex Example",
                from: .string("8:orgid:fixture-a"), originalArrivalTime: id,
                composeTime: "2026-11-01T00:00:00Z", version: edited == nil ? "2" : "3",
                properties: .object(["deletetime": .number(1)]))
        }
        if let edited { return edited }
        var properties: [String: TeamsWebJSONValue] = [:]
        if index == 50, likedAccounts.contains(account) {
            properties["emotions"] = .array([.object([
                "key": .string("like"), "users": .array([.object(["mri": .string("8:orgid:" + account)])])
            ])])
        }
        let content: String
        if index == 99 {
            content = #"""
            <blockquote itemscope="" itemtype="http://schema.skype.com/Reply" itemid="1800000000050"><strong itemprop="mri" itemid="8:orgid:ada">Ada Example</strong><span itemprop="time" itemid="1800000000050"></span><p itemprop="preview">Context-only message 50</p></blockquote><p>Fictional message 99</p>
            """#
        } else {
            content = index == 50 ? "Context-only message 50 · \(account)" : "Fictional message \(index)"
        }
        return TeamsWebMessage(id: id, content: content, messageType: index == 99 ? "RichText/Html" : "Text",
            imDisplayName: index == 50 ? "Ada Example" : "Alex Example", from: .string(index == 50 ? "8:orgid:ada" : "8:orgid:fixture-a"),
            originalArrivalTime: id, composeTime: "2026-11-01T00:00:00Z", version: "1",
            properties: properties.isEmpty ? nil : .object(properties))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.host == "teams.cloud.microsoft" else { throw URLError(.badURL) }
        let account: String
        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer fictional-only-fixture-a": account = "fixture-a"
        case "Bearer fictional-only-fixture-b": account = "fixture-b"
        default: throw URLError(.userAuthenticationRequired)
        }
        let method = request.httpMethod ?? "GET"
        let components = url.pathComponents
        let contextMessagePath = "/api/chatsvc/fixture/v1/users/ME/conversations/fixture-one/messages/"
        let data: Data
        var status = 200
        var headers: [String: String] = [:]
        if method == "GET", url.path.hasSuffix("/chats") {
            let members: [TeamsWebMember] = [.init(mri: "8:orgid:fixture-a", displayName: "Alex Example"), .init(mri: "8:orgid:ada", displayName: "Ada Example")]
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [
                .init(id: "fixture-one", title: "Fictional project", members: members),
                .init(id: "fixture-two", title: "Fictional planning", members: members)
            ]))
        } else if method == "GET", url.path.hasSuffix("/conversationFolders") {
            data = try JSONEncoder().encode(TeamsConversationFolders(conversationFolders: [], conversationFolderOrder: [], isPartialResponse: false))
        } else if method == "GET", url.path == contextMessagePath + "epochTimeStamp/1800000000050" {
            let original = message(50, account: account)
            data = try JSONEncoder().encode(["messages": TeamsWebJSONValue.array([.object([
                "id": .string(original.id), "content": .string(original.content ?? ""),
                "messagetype": .string("Text"), "imdisplayname": .string("Ada Example"),
                "from": .string("8:orgid:ada"), "originalarrivaltime": .string(original.id),
                "composetime": .string("2026-11-01T00:00:00Z"), "version": .string("1"),
                "properties": original.properties ?? .object([:])
            ])])])
        } else if method == "GET", url.path == "/api/csa/fixture/api/v1/chats/fixture-one/messages/1800000000050" {
            data = try JSONEncoder().encode(message(50, account: account))
        } else if (method == "PUT" || method == "DELETE"), url.path == contextMessagePath + "1800000000050/properties",
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "name", value: "emotions")] {
            let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: request.httpBody ?? Data())
            guard case let .object(emotion)? = body["emotions"], emotion["key"]?.stringValue == "like" else { throw URLError(.badServerResponse) }
            if method == "PUT" { likedAccounts.insert(account) }
            else { likedAccounts.remove(account) }
            data = Data("{}".utf8)
        } else if method == "POST", allowsSend,
                  let chatID = components.dropLast().last, ["fixture-one", "fixture-two"].contains(chatID),
                  url.path == "/api/chatsvc/fixture/v1/users/ME/conversations/" + chatID + "/messages" {
            let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: request.httpBody ?? Data())
            guard body["from"]?.stringValue == "8:orgid:" + account,
                  body["conversationid"]?.stringValue == chatID,
                  let content = body["content"]?.stringValue else { throw URLError(.badServerResponse) }
            nextSentID += 1
            let id = String(nextSentID)
            sentMessages[account + ":" + chatID, default: []].append(TeamsWebMessage(id: id, content: content,
                messageType: body["messagetype"]?.stringValue, imDisplayName: account, from: .string("8:orgid:" + account),
                originalArrivalTime: id, composeTime: body["composetime"]?.stringValue,
                properties: body["properties"], clientMessageId: body["clientmessageid"]?.stringValue))
            status = 201
            headers["Location"] = url.absoluteString + "/" + id
            data = try JSONEncoder().encode(["OriginalArrivalTime": id])
        } else if method == "GET", url.path.hasSuffix("/messages"),
                  let chat = components.dropLast().last, ["fixture-one", "fixture-two"].contains(chat) {
            let older = request.value(forHTTPHeaderField: "x-ms-messageToken") == "older"
            var messages = (older ? 61...80 : 81...newest).map { message($0, account: account, chat: chat) }
            if !older, let chatID = components.dropLast().last { messages += sentMessages[account + ":" + chatID] ?? [] }
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: messages, messageToken: older ? nil : "older"))
        } else if let position = components.firstIndex(of: "messages"), components.count == position + 2,
                  let chat = components.prefix(position).last, ["fixture-one", "fixture-two"].contains(chat),
                  let index = Int(components[position + 1]), (61...200).contains(index - 1_800_000_000_000),
                  (method == "GET" && url.path == "/api/csa/fixture/api/v1/chats/\(chat)/messages/\(index)") ||
                  (["PUT", "DELETE"].contains(method) && url.path == "/api/chatsvc/fixture/v1/users/ME/conversations/\(chat)/messages/\(index)") {
            let id = components[position + 1]
            let target = MessageTarget(account: account, chat: chat, id: id)
            if method == "DELETE" { deleted.insert(target) }
            if method == "PUT" {
                let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: request.httpBody ?? Data())
                edits[target] = TeamsWebMessage(id: id, content: body["content"]?.stringValue,
                    messageType: body["messagetype"]?.stringValue, imDisplayName: "Alex Example",
                    from: .string("8:orgid:fixture-a"), originalArrivalTime: id,
                    composeTime: "2026-11-01T00:00:00Z", version: "2", properties: body["properties"])
            }
            data = method == "GET" ? try JSONEncoder().encode(message(index - 1_800_000_000_000, account: account, chat: chat)) : Data("{}".utf8)
        } else if method == "PUT", url.path.hasSuffix("/properties"), !components.contains("messages") {
            data = Data("{}".utf8)
        } else {
            status = 404
            data = Data("{}".utf8)
        }
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

@MainActor @Observable private final class PerformanceFixtureController {
    let store: TeamsReaderStore
    let coordinator: TeamsRefreshCoordinator
    private let transport = PerformanceFixtureTransport(allowsSend: Bundle.main.object(forInfoDictionaryKey: "OpenTeamsFictionalSendEnabled") as? Bool == true)
    private let cacheRoot: URL
    private(set) var busy = false
    private(set) var ready = false

    init(root: URL) {
        cacheRoot = root.appendingPathComponent("ReadCache")
        store = TeamsReaderStore(cacheRoot: root.appendingPathComponent("ReadCache"), transport: transport,
                                 mediaFactory: { _ in throw TeamsMediaError.unavailable })
        coordinator = TeamsRefreshCoordinator(reader: store, defaults: TeamsPerformanceFixtureConfiguration.defaults)
    }

    func connect(_ account: String) async {
        busy = true
        defer { busy = false }
        if let count = Bundle.main.object(forInfoDictionaryKey: "OpenTeamsCachedHistoryCount") as? Int, [200, 2000].contains(count) {
            let cache = TeamsReadCache(root: cacheRoot, accountID: account, tenantID: "fixture-tenant")
            for chatID in ["fixture-one", "fixture-two"] {
                if let history = try? await cache.history(in: chatID) {
                    await transport.reserveSendIDs(history.messages)
                    if history.messages.isEmpty {
                        let messages = await transport.cachedMessages(count: count, account: account)
                        try? await cache.save(.init(messages: messages, messageToken: "older"), in: chatID)
                    }
                }
            }
        }
        await store.connect(session: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!,
            accessToken: "fictional-only-" + account, expiresAt: .distantFuture, accountID: account, tenantID: "fixture-tenant",
            displayName: account, messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!,
                accessToken: "fictional-only-" + account, expiresAt: .distantFuture)))
        ready = true
    }

    func append() async {
        busy = true
        defer { busy = false }
        await transport.append()
        await store.refreshConversation("fixture-one")
    }
}

struct TeamsPerformanceFixtureView: View {
    var body: some View {
        if let root = TeamsPerformanceFixtureConfiguration.root {
            PerformanceFixtureContent(root: root)
        } else {
            Text("Fixture storage is unavailable. Prepare a fresh fixture bundle.").padding()
        }
    }
}

private struct PerformanceFixtureContent: View {
    @ViewState<PerformanceFixtureController> private var controller: PerformanceFixtureController
    @ViewState<TeamsNotificationRouter> private var router = TeamsNotificationRouter()

    init(root: URL) {
        _controller = ViewState(initialValue: PerformanceFixtureController(root: root))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Isolated fixture · \(controller.store.accountID) · \(controller.ready ? "Ready" : "Loading")")
                Button("Account A") { Task { await controller.connect("fixture-a") } }
                Button("Account B") { Task { await controller.connect("fixture-b") } }
                Button("Append and refresh") { Task { await controller.append() } }
                Spacer()
                Button("Quit Fixture") { NSApp.terminate(nil) }
            }
            .padding(8)
            .disabled(controller.busy)
            TeamsReadContentView(store: controller.store, refreshCoordinator: controller.coordinator,
                                 notificationRouter: router, connect: {}, persistSelection: false)
        }
        .frame(minWidth: 1000, minHeight: 650)
        .task { await controller.connect("fixture-a") }
    }
}
#endif
