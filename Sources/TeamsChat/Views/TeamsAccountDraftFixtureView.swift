#if DEBUG
import SwiftUI
import TeamsCore
import Observation

@MainActor @Observable private final class AccountDraftFixture {
    let store = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("teams-account-draft-fixture-" + UUID().uuidString))
    weak var oldEditor: RichComposerTextView?
    var editorRevision = UUID()
    var ready = false
    func start() async {
        await store.restoreAccount(accountID: "a", tenantID: "tenant", displayName: "A")
        store.composer.setDraft("Account A draft", in: "same-chat")
        await store.restoreAccount(accountID: "b", tenantID: "tenant", displayName: "B")
        store.composer.setDraft("Account B draft", in: "same-chat")
        await store.restoreAccount(accountID: "a", tenantID: "tenant", displayName: "A")
        editorRevision = store.accountRevision
        ready = true
    }
    func markOldEditor() {
        guard let editor = oldEditor else { return }
        editor.window?.makeFirstResponder(editor)
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.setMarkedText("-marked-A", selectedRange: NSRange(location: 9, length: 0), replacementRange: editor.selectedRange())
    }
    func forceLatePublication() { oldEditor?.unmarkText(); oldEditor?.didChangeText() }
}

struct TeamsAccountDraftFixtureView: View {
    @ViewState<AccountDraftFixture> private var controller = AccountDraftFixture()
    @ViewState<UUID> private var focus = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account: \(controller.store.accountScope) · current draft: \(controller.store.composer.draft(in: "same-chat"))")
            HStack {
                Button("Mark old editor") { controller.markOldEditor() }
                Button("Switch to B") { Task { await controller.store.restoreAccount(accountID: "b", tenantID: "tenant", displayName: "B") } }
                Button("Force late publication") { controller.forceLatePublication() }
                Button("Switch to A") { Task { await controller.store.restoreAccount(accountID: "a", tenantID: "tenant", displayName: "A") } }
            }
            if controller.ready {
                TeamsComposerView(store: controller.store, chat: .init(id: "same-chat", title: "Fixture"), accountScope: "tenant:a", accountRevision: controller.editorRevision, focusRequest: focus, connect: {}, editorReady: { controller.oldEditor = $0 }, sent: { _ in })
            }
        }.padding(20).frame(minWidth: 700, minHeight: 300)
            .task { await controller.start() }
    }
}
#endif
