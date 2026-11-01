#if DEBUG
import SwiftUI
import Observation
import TeamsCore

private actor SharedFixtureTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let data: Data
        if url.path.hasSuffix("/AllShared") {
            if ProcessInfo.processInfo.arguments.contains("--shared-error-fixture") || ProcessInfo.processInfo.arguments.contains("--shared-auth-fixture") {
                let status = ProcessInfo.processInfo.arguments.contains("--shared-auth-fixture") ? 401 : 403
                return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            let skip = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "Skip" })?.value.flatMap(Int.init) ?? 0
            let more = skip > 0
            if ProcessInfo.processInfo.arguments.contains("--shared-repeat-fixture"), more {
                let data = Data(#"{"Items":[{"WeblinkData":{"Title":"Reference","WebUrl":"https://example.com/reference"},"TeamsMessageId":"101","ThreadId":"fixture"},{"WeblinkData":{"Title":"Project link","WebUrl":"https://example.com/project"},"TeamsMessageId":"102","ParentMessageId":"999","ThreadId":"fixture"}],"HasMoreItems":true,"Bookmark":"next+/="}"#.utf8)
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let json = more ? #"{"Items":[{"WeblinkData":{"Title":"Project link","WebUrl":"https://example.com/project"},"TeamsMessageId":"102","ParentMessageId":"999","ThreadId":"fixture"}],"HasMoreItems":false}"# : #"{"Items":[{"FileData":{"FileName":"Planning.pdf","FileUrl":"https://example.com/planning.pdf"},"SharedByDisplayName":"Fixture Person","TeamsMessageId":"101","ThreadId":"fixture"},{"WeblinkData":{"Title":"Reference","WebUrl":"https://example.com/reference"},"TeamsMessageId":"101","ThreadId":"fixture"}],"HasMoreItems":true,"Bookmark":"next+/="}"#
            data = Data(json.utf8)
        } else if url.path.contains("epochTimeStamp") {
            data = Data(#"{"messages":[{"id":"102","content":"Child target 102","messagetype":"Text","originalarrivaltime":"1000","sequenceId":102},{"id":"999","content":"Parent context 999","messagetype":"Text","originalarrivaltime":"1000","sequenceId":999}]}"#.utf8)
        } else if url.path.hasSuffix("/messages") {
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "101", content: "Fixture message", messageType: "Text", originalArrivalTime: "1000")]))
        } else { data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture", title: "Shared fixture")])) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor @Observable private final class SharedFixtureController {
    let store: TeamsReaderStore
    let coordinator: TeamsRefreshCoordinator
    init() {
        let store = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("shared-fixture-" + UUID().uuidString), transport: SharedFixtureTransport())
        self.store = store
        coordinator = TeamsRefreshCoordinator(reader: store, defaults: UserDefaults(suiteName: "shared-fixture-" + UUID().uuidString)!)
    }
    func start() async {
        let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        await store.connect(session: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "fixture", expiresAt: .distantFuture), searchSession: .init(accessToken: "fixture", expiresAt: .distantFuture, accountID: account, tenantID: tenant)))
    }
}
struct TeamsSharedFixtureView: View {
    @ViewState<SharedFixtureController> private var controller = SharedFixtureController()
    @ViewState<TeamsNotificationRouter> private var router = TeamsNotificationRouter()
    var body: some View {
        TeamsReadContentView(store: controller.store, refreshCoordinator: controller.coordinator, notificationRouter: router, connect: {}, persistSelection: false)
            .task { await controller.start() }
    }
}
#endif
