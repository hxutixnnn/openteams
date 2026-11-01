#if DEBUG
import Foundation
import Observation
import SwiftUI
import TeamsCore

private actor EditFixtureTransport: HTTPTransport {
    var edited: TeamsWebMessage?
    let original: TeamsWebMessage
    let reject: Bool
    init(rich: Bool, structure: Bool, list: Bool, unsupported: Bool, reject: Bool) {
        self.reject = reject
        let content = list ? "<ol><li>One<br>continued</li><li>Two</li><li>Three</li></ol>" : (structure ? "<pre><code>one\nsecond</code></pre><blockquote>Quote<br>Continuation</blockquote><ul><li>First<br>Second</li></ul>" : (rich ? #"<blockquote itemscope itemtype="http://schema.skype.com/Reply" itemid="42"><strong itemprop="mri" itemid="8:orgid:someone">Sam</strong><span itemprop="time" itemid="1000"></span><p itemprop="preview">Earlier fixture</p></blockquote><p>Hello <span itemscope itemtype="http://schema.skype.com/Mention" itemid="0">Ada</span></p><ul><li>First</li></ul>"# : "Original fixture"))
        let mentions = #"[{"itemid":"0","mri":"8:orgid:ada","mentionType":"person","displayName":"Ada"}]"#
        original = TeamsWebMessage(id: "123", content: content, messageType: rich || structure || list ? "RichText/Html" : "Text", from: .string("8:orgid:fixture"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: "1", properties: rich && !structure && !list ? .object(["mentions": .string(mentions)]) : nil, amsReferences: unsupported ? .array([.string("fixture")]) : nil)
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if request.httpMethod == "PUT" {
            if reject { return (Data(), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!) }
            let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: request.httpBody ?? Data())
            edited = TeamsWebMessage(id: "123", content: body["content"]?.stringValue, messageType: body["messagetype"]?.stringValue, from: .string("8:orgid:fixture"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: "2", properties: body["properties"])
            return (Data(), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let result: Data
        if url.path.hasSuffix("/messages/123") {
            result = try JSONEncoder().encode(edited ?? original)
        } else if url.path.hasSuffix("/messages") { result = try JSONEncoder().encode(TeamsWebMessagePage(messages: [original])) }
        else { result = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture", title: "Fixture", members: [.init(mri: "8:orgid:fixture", displayName: "Fixture"), .init(mri: "8:orgid:ada", displayName: "Ada")])])) }
        return (result, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Observable private final class EditFixtureController {
    let store: TeamsReaderStore
    let coordinator: TeamsRefreshCoordinator
    var edit: TeamsMessageEditSession?
    init() {
        let store = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("teams-edit-fixture-" + UUID().uuidString), transport: EditFixtureTransport(rich: ProcessInfo.processInfo.arguments.contains("--rich-edit-fixture") || ProcessInfo.processInfo.arguments.contains("--edit-menu-fixture") || ProcessInfo.processInfo.arguments.contains("--edit-rejected-fixture"), structure: ProcessInfo.processInfo.arguments.contains("--rich-edit-structure-fixture"), list: ProcessInfo.processInfo.arguments.contains("--rich-edit-list-fixture"), unsupported: ProcessInfo.processInfo.arguments.contains("--edit-unsupported-fixture"), reject: ProcessInfo.processInfo.arguments.contains("--edit-rejected-fixture")))
        self.store = store
        coordinator = TeamsRefreshCoordinator(reader: store, defaults: UserDefaults(suiteName: "teams-edit-fixture-" + UUID().uuidString)!)
    }
    func start() async {
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: "fixture", tenantID: "fixture", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!, accessToken: "fixture", expiresAt: .distantFuture))
        await store.connect(session: session); await store.loadConversation("fixture")
        store.composer.setDraft("Untouched new-message draft", in: "fixture")
        edit = try? await store.beginMessageEdit(in: "fixture", messageID: "123", accountScope: store.accountScope)
    }
}

struct TeamsMessageEditFixtureView: View {
    @ViewState<EditFixtureController> private var controller = EditFixtureController()
    @ViewState<TeamsNotificationRouter> private var router = TeamsNotificationRouter()
    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--edit-menu-fixture") || ProcessInfo.processInfo.arguments.contains("--edit-unsupported-fixture") || ProcessInfo.processInfo.arguments.contains("--edit-rejected-fixture") {
                TeamsReadContentView(store: controller.store, refreshCoordinator: controller.coordinator, notificationRouter: router, connect: {}, persistSelection: false)
            } else if let edit = controller.edit {
                VStack {
                Text("New-message draft: \(controller.store.composer.draft(in: "fixture"))").font(.caption)
                if ProcessInfo.processInfo.arguments.contains("--rich-edit-structure-fixture") || ProcessInfo.processInfo.arguments.contains("--rich-edit-list-fixture") {
                    Text("Serialized fixture: \((try? edit.document.serialize().html) ?? "unavailable")").font(.caption)
                }
                TeamsMessageEditSheet(document: Binding(get: { edit.document }, set: { edit.document = $0 }), identity: edit.id.uuidString,
                                      status: edit.status, saving: edit.saving, uncertain: edit.uncertain, completed: edit.completed, hasSavedDraft: edit.hasSavedDraft, reply: try? TeamsChatActionsClient.editableContent(edit.original).reply, members: [.init(mri: "8:orgid:ada", displayName: "Ada")], accountID: "fixture",
                                      save: { Task { await controller.store.saveMessageEdit(edit) } },
                                      check: { Task { await controller.store.checkMessageEdit(edit) } },
                                      cancel: { controller.edit = nil },
                                      discard: { Task { if await controller.store.discardMessageEdit(edit) { controller.edit = nil } } })
                }
            } else { Text("Fixture closed") }
        }
        .frame(minWidth: 600, minHeight: 360)
        .task { await controller.start() }
    }
}
#endif
