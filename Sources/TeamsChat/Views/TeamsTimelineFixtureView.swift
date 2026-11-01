#if DEBUG
import Foundation
import Observation
import SwiftUI
import TeamsCore

private actor TimelineFixtureTransport: HTTPTransport {
    private var newest = 130
    private var readHorizon = "1;1;0"
    private var readBookmark = "0;2;0"
    private var held: CheckedContinuation<Void, Never>?
    private var holdInitial = ProcessInfo.processInfo.arguments.contains("--timeline-fixture-cached")
    func appendMessage() { newest += 1 }
    func releaseInitial() { holdInitial = false; held?.resume(); held = nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let payload: Data
        if request.httpMethod == "PUT", request.url?.path.hasSuffix("/conversations/fixture/properties") == true {
            let object = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String]
            if let value = object?["consumptionhorizon"] { readHorizon = value }
            if let value = object?["consumptionHorizonBookmark"] { readBookmark = value }
            payload = Data("{}".utf8)
        } else if request.url?.path.contains("/epochTimeStamp/") == true {
            let direction = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "direction" }?.value
            let rich = #"<p><strong>Fixture original 25</strong> <span itemtype="http://schema.skype.com/Mention">Fixture Person</span></p><ol><li><p>First</p><ul><li><p>Nested</p></li></ul></li><li><p>Second</p></li></ol><img src="https://us-api.asm.skype.com/v1/objects/fixture/views/imgo" width="400" height="100" alt="Fixture image">"#
            let range = direction == "BACKWARD" ? 1...10 : (direction == "FORWARD" ? 40...60 : 10...50)
            let items: [[String: Any]] = range.map { id in
                var item: [String: Any] = ["id": String(id), "imdisplayname": "Fixture author", "sequenceId": id]
                item["content"] = id == 25 ? rich : "Fixture context message \(id)"
                item["messagetype"] = id == 25 ? "RichText/Html" : "Text"
                if id == 24 {
                    item["content"] = #"<blockquote itemtype="http://schema.skype.com/Reply" itemid="23"><strong itemprop="mri" itemid="8:orgid:fixture">Fixture author</strong><p itemprop="preview">Fixture quoted message</p></blockquote><p>Fixture file</p>"#
                    item["messagetype"] = "RichText/Html"
                    item["properties"] = ["files": #"[{"title":"Fixture plan.pdf","openUrl":"https://example.com/fixture.pdf"}]"#]
                }
                return item
            }
            let metadata: [String: String] = direction == "BACKWARD" ? [:] : (direction == "FORWARD" ? [:] : ["backwardLink": "https://fixture.invalid/epochTimeStamp/10", "forwardLink": "https://fixture.invalid/epochTimeStamp/50"])
            payload = try JSONSerialization.data(withJSONObject: ["messages": items, "_metadata": metadata])
        } else if request.url?.path.hasSuffix("/conversations/fixture") == true {
            payload = try JSONSerialization.data(withJSONObject: ["id": "fixture", "properties": ["consumptionhorizon": readHorizon, "consumptionHorizonBookmark": readBookmark]])
        } else if request.url?.path.hasSuffix("/messages") == true {
            if holdInitial { await withCheckedContinuation { held = $0 } }
            let older = request.value(forHTTPHeaderField: "x-ms-messageToken") == "older"
            let range = older ? 90...99 : 100...newest
            let messages = range.map { id in
                let content = id == 125 ? #"<blockquote itemtype="http://schema.skype.com/Reply" itemid="124"><strong itemprop="mri" itemid="8:orgid:fixture">Fixture author</strong><span itemprop="time" itemid="1800000000000"></span><p itemprop="preview">A longer fixture quote that can be expanded for a local layout check. This deliberately contains enough text to wrap across multiple lines in the window, so expansion changes the height of the reply card while the user is reading older messages in the conversation.</p></blockquote><p>Fixture reply 125</p>"# : (id == 126 ? #"<blockquote itemtype="http://schema.skype.com/Reply" itemid="25"><strong itemprop="mri" itemid="8:orgid:fixture">Fixture author</strong><p itemprop="preview">Fixture original 25</p></blockquote><p>Fixture remote reply 126</p>"# : (id == 110 ? #"<p>Fixture image 110</p><img src="https://us-api.asm.skype.com/v1/objects/fixture/views/imgo" width="400" height="100" alt="Fixture image">"# : "Fixture message \(id)"))
                return TeamsWebMessage(id: String(id), content: content, messageType: (id == 125 || id == 126 || id == 110) ? "RichText/Html" : "Text", imDisplayName: "Fixture author", originalArrivalTime: String(1_800_000_000_000 + id * 1_000), version: "1")
            }
            payload = try JSONEncoder().encode(TeamsWebMessagePage(messages: messages, messageToken: older ? nil : "older"))
        } else { payload = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture", title: "Timeline fixture")])) }
        return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor TimelineFixtureMedia: TeamsMediaFetching {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func releaseImage() { released = true; pending.forEach { $0.resume() }; pending.removeAll() }
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let isAuth = request.url?.host == "teams.microsoft.com"
        if isAuth {
            let token = fixtureToken(["skypeid": "orgid:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "tid": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "exp": 4_000_000_000])
            data = try JSONSerialization.data(withJSONObject: ["tokens": ["skypeToken": token, "expiresIn": 3600], "regionGtms": ["ams": "https://us-api.asm.skype.com"]])
        } else {
            if !released { await withCheckedContinuation { pending.append($0) } }
            data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAZAAAABkCAIAAAAnqfEgAAABl0lEQVR4nO3YwQ3CMBAAwYCoDZpIBaGeVBCaSHc0wCMCS2iVmb+te63OvtyXbQIouP57AICjBAvIECwgQ7CADMECMgQLyBAsIEOwgAzBAjIEC8gQLCBDsIAMwQIyBAvIECwgQ7CADMECMgQLyBAsIOP2y+F9ncdNApzF4/n67qANC8gQLCBDsIBz/GENeZQCZ7CP+PK2YQEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAxm3URfs6j7oK4CMbFpAhWECGYAEZl/uy/XsGgENsWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABU8Ub1voLHfGLJMoAAAAASUVORK5CYII=")!
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": isAuth ? "application/json" : "image/png"])!)
    }
}

private func fixtureToken(_ claims: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()
    return "e30." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
}

@MainActor @Observable private final class TimelineFixtureController {
    let transport: TimelineFixtureTransport
    let media: TimelineFixtureMedia
    let store: TeamsReaderStore
    let root: URL
    init() {
        let transport = TimelineFixtureTransport()
        let media = TimelineFixtureMedia()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("teams-timeline-fixture-" + UUID().uuidString)
        self.transport = transport; self.media = media; self.root = root
        store = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { try TeamsMediaClient(session: $0, transport: media) })
    }
    func start() async {
        let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let token = fixtureToken(["aud": "https://api.spaces.skype.com", "oid": account, "tid": tenant, "exp": 4_000_000_000])
        let directory = TeamsDirectorySession(baseURL: URL(string: "https://teams.cloud.microsoft/api/mt/fixture")!, accessToken: token, expiresAt: .distantFuture)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fixture", expiresAt: .distantFuture,
                                      accountID: account, tenantID: tenant, displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fixture", expiresAt: .distantFuture), directory: directory)
        if ProcessInfo.processInfo.arguments.contains("--read-status-fixture") {
            let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
            let intent = TeamsPendingReadIntent(targetHorizon: 1_800_000_000_000)
            _ = try? await cache.installPendingRead(intent, in: "fixture")
            if ProcessInfo.processInfo.arguments.contains("--read-status-partial-fixture") {
                _ = try? await cache.advancePendingRead(id: intent.id, stage: .bookmarkAccepted, in: "fixture")
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--timeline-fixture-cached") {
            let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
            let messages = (100...130).map { TeamsWebMessage(id: String($0), content: "Cached fixture message \($0)", messageType: "Text", imDisplayName: "Fixture author", originalArrivalTime: String(1_800_000_000_000 + $0 * 1_000), version: "1") }
            try? await cache.save(TeamsCachedHistory(messages: messages), in: "fixture")
        }
        await store.connect(session: session)
        await store.loadConversation("fixture")
    }
    func append() async { await transport.appendMessage(); await store.refreshConversation("fixture") }
}

struct TeamsTimelineFixtureView: View {
    @ViewState<TimelineFixtureController> private var controller = TimelineFixtureController()
    @ViewState<TeamsMessageDestination?> private var jump: TeamsMessageDestination? = nil
    @ViewState<UUID> private var timelineID = UUID()
    @ViewState<String?> private var sidebarSelection: String? = "fixture"
    @ViewState<String> private var sidebarFilter = ""
    @ViewState<Bool> private var autoReleased = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Local timeline fixture").font(.headline)
                if autoReleased { Text("Refresh released on scroll").font(.caption) }
                Spacer()
                Button("Insert incoming message") { Task { await controller.append() } }
                Button("Finish fixture image") { Task { await controller.media.releaseImage() } }
                Button("Reopen timeline") { timelineID = UUID() }
                if ProcessInfo.processInfo.arguments.contains("--timeline-observer-diagnostics") {
                    Button("Resize fixture") { NSApp.keyWindow?.setContentSize(NSSize(width: 900, height: 650)) }
                    Button("Focus timeline") { NotificationCenter.default.post(name: Notification.Name("TeamsFixtureFocusTimeline"), object: nil) }
                }
                if ProcessInfo.processInfo.arguments.contains("--timeline-fixture-cached") {
                    Button("Finish fixture refresh") { Task { await controller.transport.releaseInitial() } }
                }
            }.padding(10)
            HStack(spacing: 0) {
                if ProcessInfo.processInfo.arguments.contains("--read-status-fixture") {
                    TeamsReadSidebar(store: controller.store, selection: $sidebarSelection, filter: $sidebarFilter, connect: {}, newChat: {})
                        .frame(width: 280)
                }
                TeamsReadDetailView(store: controller.store, chat: .init(id: "fixture", title: "Timeline fixture", members: [.init(mri: "8:orgid:cccccccc-cccc-cccc-cccc-cccccccccccc", displayName: "Fixture Person")]), accountScope: controller.store.accountScope, accountRevision: controller.store.accountRevision, selectedChatID: .constant("fixture"), jumpToMessage: $jump, connect: {}, focusRequest: UUID())
                    .id(timelineID)
                if ProcessInfo.processInfo.arguments.contains("--timeline-observer-diagnostics") {
                    ScrollView { VStack { ForEach(0..<30) { Text("Inspector fixture \($0)") } } }.frame(width: 160)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 580)
        .task { await controller.start() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TeamsFixtureReleaseImage"))) { _ in Task { await controller.media.releaseImage() } }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TeamsFixtureReleaseRefreshOnScroll"))) { _ in
            guard !autoReleased else { return }; autoReleased = true
            Task { await controller.transport.releaseInitial() }
        }
    }
}
#endif
