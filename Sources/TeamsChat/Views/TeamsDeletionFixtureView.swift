#if DEBUG
import SwiftUI
import Observation
import TeamsCore

private actor DeletionFixtureTransport: HTTPTransport {
    private var tombstone = false
    func enableTombstone() { tombstone = true }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if request.httpMethod == "DELETE" { return (Data(), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!) }
        let message = TeamsWebMessage(id: "100", content: "Synthetic deletion target", messageType: "Text", from: .string("8:orgid:fixture"), originalArrivalTime: "1800000000000", version: tombstone ? "2" : "1", properties: tombstone ? .object(["deletetime": .number(1)]) : nil)
        let data: Data
        if url.path.hasSuffix("/messages/100") { data = try JSONEncoder().encode(message) }
        else if url.path.hasSuffix("/messages") { data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [message])) }
        else { data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture", title: "Deletion fixture")])) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor @Observable private final class DeletionFixtureController {
    let transport = DeletionFixtureTransport()
    let store: TeamsReaderStore
    let coordinator: TeamsRefreshCoordinator
    init() {
        let run = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--fixture-run=") }).map { String($0.dropFirst("--fixture-run=".count)) } ?? UUID().uuidString
        let store = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("deletion-fixture-" + run), transport: transport)
        self.store = store
        coordinator = TeamsRefreshCoordinator(reader: store, defaults: UserDefaults(suiteName: "delete-fixture-" + UUID().uuidString)!)
    }
    func start() async {
        await store.connect(session: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: "fixture", tenantID: "fixture", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "fixture", expiresAt: .distantFuture)))
        await store.loadConversation("fixture")
    }
}
struct TeamsDeletionFixtureView: View {
    @ViewState<DeletionFixtureController> private var controller = DeletionFixtureController()
    @ViewState<TeamsNotificationRouter> private var router = TeamsNotificationRouter()
    var body: some View {
        VStack {
            Button("Enable synthetic tombstone") { Task { await controller.transport.enableTombstone() } }
            TeamsReadContentView(store: controller.store, refreshCoordinator: controller.coordinator, notificationRouter: router, connect: {}, persistSelection: false)
        }.task { await controller.start() }
    }
}
#endif
