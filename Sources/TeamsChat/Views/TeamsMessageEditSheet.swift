import SwiftUI
import TeamsCore

struct TeamsMessageEditSheet: View {
    @Binding var document: TeamsRichDraft
    let identity: String
    let status: String?
    let saving: Bool
    let uncertain: Bool
    let completed: Bool
    let hasSavedDraft: Bool
    let reply: TeamsRichEditImport.Reply?
    let members: [TeamsWebMember]
    let accountID: String
    let save: () -> Void
    let check: () -> Void
    let cancel: () -> Void
    let discard: () -> Void
    @ViewState<TeamsComposerCommand?> private var command = nil
    @ViewState<UUID> private var focusRequest = UUID()
    @ViewState<Bool> private var showLink = false
    @ViewState<String> private var linkText = ""
    @ViewState<TeamsMentionPickerState> private var mentionPicker = TeamsMentionPickerState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit message").font(.headline)
            if let status { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            ReactionFlowLayout(spacing: 8) {
                format("Bold", "bold", .bold)
                format("Italic", "italic", .italic)
                format("Underline", "underline", .underline)
                format("Strikethrough", "strikethrough", .strike)
                format("Code", "chevron.left.forwardslash.chevron.right", .code)
                format("Bulleted list", "list.bullet", .bulletList)
                format("Numbered list", "list.number", .numberedList)
                format("Block quote", "text.quote", .quote)
                format("Increase list indent", "increase.indent", .indent)
                format("Decrease list indent", "decrease.indent", .outdent)
                Button { linkText = ""; showLink = true } label: { Image(systemName: "link") }.help("Add link").accessibilityLabel("Add link")
                Menu("Mention") {
                    ForEach(Array(members.filter { $0.kind == .person && $0.mri != nil && $0.preferredDisplayName != nil }.enumerated()), id: \.offset) { _, member in
                        Button(member.preferredDisplayName ?? "Person") {
                            if let mri = member.mri, let name = member.preferredDisplayName { command = .init(action: .mention(.init(mri: mri, displayName: name))) }
                        }
                    }
                }
            }.buttonStyle(.borderless).disabled(saving || uncertain || completed)
            if let reply {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Replying to \(reply.name)").font(.caption.weight(.semibold))
                    Text(reply.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous))
            }
            TeamsMentionSuggestions(picker: mentionPicker)
            TeamsRichComposer(document: $document, conversationID: identity, focusRequest: focusRequest,
                              command: command, sendOnReturn: false, send: {}, editable: !saving && !uncertain && !completed,
                              members: members, accountID: accountID, mentionPicker: mentionPicker)
                .frame(minHeight: 160)
                .background(TeamsSurface.input, in: RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous))
                .disabled(saving || uncertain || completed)
            HStack {
                if saving { ProgressView().controlSize(.small); Text("Saving…").font(.caption) }
                Spacer()
                if hasSavedDraft && !uncertain { Button("Discard Saved Edit", action: discard).disabled(saving) }
                Button(hasSavedDraft && !uncertain && !completed ? "Save Draft & Close" : (uncertain || completed ? "Close" : "Cancel"), action: cancel).disabled(saving)
                if uncertain { Button("Check Status", action: check).disabled(saving) }
                else if !completed { Button("Save", action: save).buttonStyle(.borderedProminent).disabled(saving || document.contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
        .padding(20)
        .background(TeamsSurface.window)
        .frame(minWidth: 540, minHeight: 320)
        .alert("Add link", isPresented: $showLink) {
            TextField("https://example.com", text: $linkText)
            Button("Cancel", role: .cancel) { }
            Button("Add") {
                if let url = URL(string: linkText), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
                   url.user == nil, url.password == nil, url.absoluteString.rangeOfCharacter(from: .controlCharacters) == nil,
                   (scheme == "mailto" ? !url.path.isEmpty : url.host?.isEmpty == false) { command = .init(action: .link(url)) }
            }
        }
    }

    private func format(_ label: String, _ symbol: String, _ action: TeamsComposerCommand.Action) -> some View {
        Button { command = .init(action: action) } label: { Image(systemName: symbol).frame(width: 28, height: 28) }
            .help(label).accessibilityLabel(label)
    }
}
