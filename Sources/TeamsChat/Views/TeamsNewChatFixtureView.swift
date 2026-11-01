#if DEBUG
import SwiftUI
import TeamsCore
import Observation

private actor NewChatFixtureTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.hasSuffix("/searchV2") {
            let body = Data(#"{"value":[{"mri":"8:orgid:ada","displayName":"Ada Fixture"},{"mri":"8:orgid:bob","displayName":"Bob Fixture"}]}"#.utf8)
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if url.path.hasSuffix("/v1/threads") && request.httpMethod == "POST" {
            if ProcessInfo.processInfo.arguments.contains("--new-chat-auth-fixture") {
                return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            if !ProcessInfo.processInfo.arguments.contains("--new-chat-restart-fixture") && !ProcessInfo.processInfo.arguments.contains("--new-chat-success-fixture") { try? await Task.sleep(for: .seconds(15)) }
            let status = ProcessInfo.processInfo.arguments.contains("--new-chat-success-fixture") ? 201 : 207
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Location": "https://teams.cloud.microsoft/v1/threads/19%3Afixture%40thread.v2"])!)
        }
        let body = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "existing", title: "Existing fixture")]))
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Observable private final class NewChatFixtureController {
    let store: TeamsReaderStore
    let coordinator: TeamsRefreshCoordinator
    let account: String
    init() {
        let identifier = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--fixture-run=") }).map { String($0.dropFirst("--fixture-run=".count)) } ?? UUID().uuidString.lowercased()
        account = identifier
        let store = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("teams-new-chat-" + identifier), transport: NewChatFixtureTransport())
        self.store = store
        coordinator = TeamsRefreshCoordinator(reader: store, defaults: UserDefaults(suiteName: "teams-new-chat-" + UUID().uuidString)!)
    }
    func start() async {
        await store.connect(session: TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: account, tenantID: "fixture", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "fixture", expiresAt: .distantFuture), directory: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/mt/amer")!, accessToken: "fixture", expiresAt: .distantFuture)))
    }
}

struct TeamsNewChatFixtureView: View {
    @ViewState<NewChatFixtureController> private var controller = NewChatFixtureController()
    @ViewState<TeamsNotificationRouter> private var router = TeamsNotificationRouter()
    var body: some View {
        TeamsReadContentView(store: controller.store, refreshCoordinator: controller.coordinator, notificationRouter: router, connect: {}, persistSelection: false)
            .task { await controller.start() }
    }
}
#endif
