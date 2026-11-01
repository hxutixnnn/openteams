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
    private var newest = 100
    private var deleted: Set<String> = []
    private var edits: [String: TeamsWebMessage] = [:]

    func append() { newest += 1 }

    private func message(_ index: Int) -> TeamsWebMessage {
        let id = String(1_800_000_000_000 + index)
        if let edited = edits[id] { return edited }
        return TeamsWebMessage(id: id, content: "Fictional message \(index)", messageType: "Text",
            imDisplayName: "Alex Example", from: .string("8:orgid:fixture-a"),
            originalArrivalTime: id, composeTime: "2026-11-01T00:00:00Z", version: "1",
            properties: deleted.contains(id) ? .object(["deletetime": .number(1)]) : nil)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        let components = url.pathComponents
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
        } else if method == "GET", url.path.hasSuffix("/messages") {
            let older = request.value(forHTTPHeaderField: "x-ms-messageToken") == "older"
            let messages = (older ? 61...80 : 81...newest).map(message)
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: messages, messageToken: older ? nil : "older"))
        } else if let position = components.firstIndex(of: "messages"), components.count == position + 2,
                  let index = Int(components[position + 1]), (1...200).contains(index - 1_800_000_000_000) {
            let id = components[position + 1]
            if method == "DELETE" { deleted.insert(id) }
            if method == "PUT" {
                let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: request.httpBody ?? Data())
                edits[id] = TeamsWebMessage(id: id, content: body["content"]?.stringValue,
                    messageType: body["messagetype"]?.stringValue, imDisplayName: "Alex Example",
                    from: .string("8:orgid:fixture-a"), originalArrivalTime: id,
                    composeTime: "2026-11-01T00:00:00Z", version: "2", properties: body["properties"])
            }
            data = method == "GET" ? try JSONEncoder().encode(message(index - 1_800_000_000_000)) : Data("{}".utf8)
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
            accessToken: "fictional-only", expiresAt: .distantFuture, accountID: account, tenantID: "fixture-tenant",
            displayName: account, messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!,
                accessToken: "fictional-only", expiresAt: .distantFuture)))
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
