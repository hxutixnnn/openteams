#if DEBUG
import AppKit
import Observation
import SwiftUI
import TeamsCore

@MainActor enum TeamsPerformanceFixtureConfiguration {
    static let enabled = Bundle.main.object(forInfoDictionaryKey: "OpenTeamsPerformanceFixtureRoot") != nil || ProcessInfo.processInfo.arguments.contains("--performance-fixture")
    static let defaults = UserDefaults(suiteName: "OpenTeams.performance-fixture." + UUID().uuidString)!
    static let appearance = TeamsPerformanceFixtureAppearanceState()
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

@MainActor @Observable final class TeamsPerformanceFixtureAppearanceState {
    var selection = "System"
    var colorScheme: ColorScheme? { selection == "Dark" ? .dark : selection == "Light" ? .light : nil }
}

struct TeamsPerformanceFixtureAppearance: ViewModifier {
    @Bindable private var appearance = TeamsPerformanceFixtureConfiguration.appearance

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}

private actor PerformanceFixtureTransport: HTTPTransport {
    private var newest = 100
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
        } else if method == "GET", url.path.hasSuffix("/messages"),
                  let chat = components.dropLast().last, ["fixture-one", "fixture-two"].contains(chat) {
            let older = request.value(forHTTPHeaderField: "x-ms-messageToken") == "older"
            let messages = (older ? 61...80 : 81...newest).map { message($0, account: account, chat: chat) }
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
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Observable private final class PerformanceFixtureController {
    let store: TeamsReaderStore
    let coordinator: TeamsRefreshCoordinator
    private let transport = PerformanceFixtureTransport()
    private(set) var busy = false
    private(set) var ready = false

    init(root: URL) {
        store = TeamsReaderStore(cacheRoot: root.appendingPathComponent("ReadCache"), transport: transport,
                                 mediaFactory: { _ in throw TeamsMediaError.unavailable })
        coordinator = TeamsRefreshCoordinator(reader: store, defaults: TeamsPerformanceFixtureConfiguration.defaults)
    }

    func connect(_ account: String) async {
        busy = true
        defer { busy = false }
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
    @ViewState<FixtureChatStore> private var sampleStore = FixtureChatStore(draftURL: nil)
    @ViewState<Bool> private var sampleWorkspace = false
    @ViewState<Bool> private var inlineImage = false
    @Bindable private var appearance = TeamsPerformanceFixtureConfiguration.appearance

    init(root: URL) {
        _controller = ViewState(initialValue: PerformanceFixtureController(root: root))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Isolated fixture · \(controller.store.accountID) · \(controller.ready ? "Ready" : "Loading")").lineLimit(1)
                Button("Account A") { Task { await controller.connect("fixture-a") } }
                Button("Account B") { Task { await controller.connect("fixture-b") } }
                Button("Append and refresh") { Task { await controller.append() } }
                Spacer()
                Button("Quit Fixture") { NSApp.terminate(nil) }
            }
            .padding(8)
            .disabled(controller.busy)
            HStack {
                Toggle("Sample Workspace", isOn: $sampleWorkspace).toggleStyle(TeamsPillToggleStyle())
                Toggle("Inline image", isOn: $inlineImage).toggleStyle(TeamsPillToggleStyle())
                Picker("Appearance", selection: $appearance.selection) {
                    ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
                }.frame(width: 180)
                Spacer()
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            if inlineImage {
                RoundedInlineImageFixtureView(revision: controller.store.mediaRevision)
            } else if sampleWorkspace {
                ContentView(store: sampleStore)
            } else {
                TeamsReadContentView(store: controller.store, refreshCoordinator: controller.coordinator,
                                     notificationRouter: router, connect: {}, persistSelection: false)
            }
        }
        .tint(ChatTheme.accent)
        .background(TeamsSurface.window)
        .frame(minWidth: 820, minHeight: 580)
        .task { await controller.connect("fixture-a") }
    }
}

private struct RoundedInlineImageFixtureView: View {
    let revision: UUID
    @ViewState<Bool> private var fullSizeRequested = false
    private let imageURL = URL(string: "https://us-api.asm.skype.com/v1/objects/rounded-fixture/views/imgo")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fictional inline image").font(.headline)
            Text(fullSizeRequested ? "Full-size requested" : "Thumbnail only").font(.caption)
            let message = TeamsWebMessage(id: "rounded-image", content: #"<p>Fictional image preview</p><img src="https://us-api.asm.skype.com/v1/objects/rounded-fixture/views/imgo" width="400" height="100" alt="Rounded fixture image">"#, messageType: "RichText/Html", imDisplayName: "Alex Example")
            TeamsMessageRow(message: TeamsRenderedMessage(message, accountScope: "rounded-fixture", accountRevision: revision, chatID: "image"), compact: false, grouped: false,
                accountID: "fixture-a", canEdit: false, canReact: false,
                mediaRevision: revision, mediaRefreshRevision: revision,
                loadImage: { image, fullSize in
                    guard image.url == imageURL else { throw TeamsMediaError.unsafeURL }
                    try Task.checkCancellation()
                    if fullSize { fullSizeRequested = true }
                    return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAZAAAABkCAIAAAAnqfEgAAABl0lEQVR4nO3YwQ3CMBAAwYCoDZpIBaGeVBCaSHc0wCMCS2iVmb+te63OvtyXbQIouP57AICjBAvIECwgQ7CADMECMgQLyBAsIEOwgAzBAjIEC8gQLCBDsIAMwQIyBAvIECwgQ7CADMECMgQLyBAsIOP2y+F9ncdNApzF4/n67qANC8gQLCBDsIBz/GENeZQCZ7CP+PK2YQEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAxm3URfs6j7oK4CMbFpAhWECGYAEZl/uy/XsGgENsWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABU8Ub1voLHfGLJMoAAAAASUVORK5CYII=")!
                }, loadPhoto: { _ in throw TeamsMediaError.unavailable },
                replyAuthor: { _ in "Alex Example" }, canJumpToMessage: { _ in false }, jumpToMessage: { _ in }, action: { _ in }, canDelete: false)
            Spacer()
        }
        .padding(20)
        .modifier(TeamsInsetPanel())
        .onChange(of: revision) { _, _ in fullSizeRequested = false }
    }
}
#endif
