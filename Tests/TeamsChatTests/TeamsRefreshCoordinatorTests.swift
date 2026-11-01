import Foundation
import Testing
@testable import TeamsChat
@testable import TeamsCore

private actor RefreshFixtureTransport: HTTPTransport {
    private(set) var paths: [String] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        paths.append(path)
        let data: Data
        if path.hasSuffix("/conversationFolders") {
            data = try JSONEncoder().encode(TeamsConversationFolders(conversationFolders: [], conversationFolderOrder: [], isPartialResponse: false))
        } else if path.hasSuffix("/messages") {
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: []))
        } else {
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func counts() -> (Int, Int, Int) {
        (paths.filter { $0.hasSuffix("/chats") }.count, paths.filter { $0.hasSuffix("/conversationFolders") }.count, paths.filter { $0.hasSuffix("/messages") }.count)
    }
}

@MainActor struct TeamsRefreshCoordinatorTests {
    @Test func oneOwnerCoalescesWindowsAndKeepsBackgroundMaintenance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "TeamsRefreshFixture-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = RefreshFixtureTransport()
        let reader = TeamsReaderStore(cacheRoot: root, transport: transport)
        let coordinator = TeamsRefreshCoordinator(reader: reader, defaults: defaults)
        coordinator.start(); coordinator.start()
        defer { coordinator.stop() }
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture")
        await reader.connect(session: session)
        let one = UUID(), two = UUID()
        coordinator.updateWindow(one, chatID: "chat", active: true)
        coordinator.updateWindow(two, chatID: "chat", active: true)
        let now = Date(timeIntervalSince1970: 1_000)
        coordinator.tick(at: now)
        for _ in 0..<100 { let counts = await transport.counts(); if counts.0 >= 2 && counts.1 >= 1 && counts.2 >= 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let first = await transport.counts()
        #expect(first.0 == 2 && first.1 == 1 && first.2 == 1)
        coordinator.removeWindow(one); coordinator.removeWindow(two)
        defaults.set(true, forKey: "teamsNotificationsEnabled")
        coordinator.tick(at: now.addingTimeInterval(60))
        for _ in 0..<100 { if await transport.counts().0 >= 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let background = await transport.counts()
        #expect(background.0 == 3 && background.2 == 1)
    }
}
