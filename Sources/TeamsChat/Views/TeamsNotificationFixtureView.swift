#if DEBUG
import Foundation
import Observation
import SwiftUI
import TeamsCore

private actor NotificationFixtureTransport: HTTPTransport {
    private(set) var chatReads = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let data: Data
        if path.hasSuffix("/conversationFolders") {
            data = try JSONEncoder().encode(TeamsConversationFolders(conversationFolders: [], conversationFolderOrder: [], isPartialResponse: false))
        } else if path.hasSuffix("/messages") {
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "101", content: "Synthetic message", messageType: "Text")]))
        } else {
            chatReads += 1
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture-a", title: "Fixture A"), .init(id: "fixture-b", title: "Fixture B")]))
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Observable final class TeamsNotificationFixtureController {
    private let transport: NotificationFixtureTransport
    private let defaults: UserDefaults
    let store: TeamsReaderStore
    let coordinator: TeamsRefreshCoordinator
    private(set) var readsBeforeReopen = 0
    private(set) var noWindowBeforeReopen = false
    private var started = false
    init() {
        let transport = NotificationFixtureTransport()
        let defaults = UserDefaults(suiteName: "teams-notification-fixture-" + UUID().uuidString)!
        defaults.set(true, forKey: "teamsNotificationsEnabled")
        let store = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("teams-notification-fixture-" + UUID().uuidString), transport: transport)
        self.transport = transport; self.defaults = defaults; self.store = store
        self.coordinator = TeamsRefreshCoordinator(reader: store, defaults: defaults, tickInterval: 2, maintenanceInterval: 5)
    }
    func start() async {
        guard !started else { return }; started = true; coordinator.start()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: "fixture-account", tenantID: "fixture-tenant", displayName: "Fixture")
        await store.connect(session: session)
    }
    func reads() async -> Int { await transport.chatReads }
    func simulateAfterClose(delegate: AppDelegate) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            readsBeforeReopen = await transport.chatReads
            noWindowBeforeReopen = !coordinator.hasWindows
            guard let destination = TeamsNotificationDestination(accountScope: store.accountScope, chatID: "fixture-b", messageID: "101") else { return }
            delegate.deliver(destination, requestID: "fixture-notification")
        }
    }
    func simulateNow(delegate: AppDelegate) {
        guard let destination = TeamsNotificationDestination(accountScope: store.accountScope, chatID: "fixture-b", messageID: "101") else { return }
        delegate.deliver(destination, requestID: UUID().uuidString)
    }
}

struct TeamsNotificationFixtureView: View {
    var controller: TeamsNotificationFixtureController
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @ViewState<Int> private var reads = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Local notification fixture · chat reads: \(reads) · before reopen: \(controller.readsBeforeReopen) · no window: \(controller.noWindowBeforeReopen)")
                Spacer()
                Button("Simulate now") { controller.simulateNow(delegate: appDelegate) }
                Button("Simulate after close") { controller.simulateAfterClose(delegate: appDelegate) }
            }.padding(8)
            TeamsReadContentView(store: controller.store, refreshCoordinator: controller.coordinator, notificationRouter: appDelegate.notificationRouter, connect: {}, persistSelection: false)
        }
        .frame(minWidth: 820, minHeight: 580)
        .onAppear { appDelegate.configure(coordinator: controller.coordinator) { openWindow(id: "chat") } }
        .task {
            await controller.start()
            while !Task.isCancelled {
                reads = await controller.reads()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

struct TeamsAgentRetryFixtureView: View {
    var controller: TeamsNotificationFixtureController
    @ViewState<InspectorTab> private var tab = .people
    @ViewState<String> private var query = ""
    @ViewState<TeamsMessageDestination?> private var jump = nil
    @ViewState<Int> private var attempts = 0
    var body: some View {
        TeamsReadInspector(store: controller.store,
                           chat: .init(id: "fixture-a", title: "Fixture", members: [.init(mri: "8:orgid:fixture", friendlyName: "Fixture Person"), .init(mri: "28:fixture-bot", friendlyName: "Roster Agent"), .init(mri: "8:orgid:agentic", friendlyName: "Fixture Agentic", userIdentityType: "agentic")]),
                           accountScope: controller.store.accountScope, accountRevision: controller.store.accountRevision, tab: $tab, query: $query, jumpToMessage: $jump,
                           loadAgents: { _ in
            attempts += 1
            if attempts == 1 { throw TeamsMediaError.unavailable }
            return [.init(id: "bot", appID: "app", name: "Fixture Agent")]
        })
        .frame(width: 380, height: 600)
        .task { await controller.start() }
    }
}
#endif
