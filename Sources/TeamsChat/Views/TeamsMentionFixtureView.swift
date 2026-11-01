#if DEBUG
import SwiftUI
import TeamsCore

@MainActor @Observable private final class MentionFixtureEditor {
    weak var editor: RichComposerTextView?
    var marked = false
    func startComposition() {
        guard let editor else { return }
        editor.window?.makeFirstResponder(editor)
        editor.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        marked = editor.hasMarkedText()
    }
    func commitComposition() { editor?.unmarkText(); marked = editor?.hasMarkedText() ?? false }
}

struct TeamsMentionFixtureView: View {
    @ViewState<TeamsRichDraft> private var document = .init(plainText: "")
    @ViewState<TeamsMentionPickerState> private var picker = TeamsMentionPickerState()
    @ViewState<String> private var context = "account:chat-a"
    @ViewState<String> private var account = "self"
    @ViewState<Int> private var sends = 0
    @ViewState<UUID> private var focusRequest = UUID()
    @ViewState<MentionFixtureEditor> private var fixtureEditor = MentionFixtureEditor()
    @ViewState<Bool> private var editable = true
    private let members: [TeamsWebMember] = [
        .init(mri: "8:orgid:self", displayName: "Self"),
        .init(mri: "8:orgid:first", displayName: "Áda Example"),
        .init(mri: "8:orgid:second", displayName: "Áda Example"),
        .init(mri: "8:orgid:third", friendlyName: "Bea Person")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synthetic mention fixture · sends: \(sends) · context: \(context) · marked: \(fixtureEditor.marked) · editable: \(editable)")
            Text("HTML: \((try? document.serialize().html) ?? "invalid")").font(.caption)
            Text("Mentions: \((try? document.serialize().mentionsJSON) ?? "invalid")").font(.caption)
            Button("Switch conversation") { context = context == "account:chat-a" ? "account:chat-b" : "account:chat-a" }
            Button("Switch account") { account = account == "self" ? "other" : "self"; context = account + ":chat-a" }
            HStack {
                Button("Start composition") { fixtureEditor.startComposition() }
                Button("Commit composition") { fixtureEditor.commitComposition() }
                Button("Toggle editable") { editable.toggle() }
                Button("Replace document") { document = .init(blocks: [.init(runs: [.init(text: document.contentText, bold: true)])]) }
            }
            TeamsMentionSuggestions(picker: picker)
            TeamsRichComposer(document: $document, conversationID: context, focusRequest: focusRequest, command: nil,
                              sendOnReturn: true, send: { sends += 1 }, editable: editable, members: members, accountID: account, mentionPicker: picker,
                              editorReady: { fixtureEditor.editor = $0 })
                .frame(minHeight: 160)
                .background(TeamsSurface.input, in: RoundedRectangle(cornerRadius: 8))
        }.padding(20).frame(minWidth: 640, minHeight: 380)
    }
}
#endif
