import AppKit
import SwiftUI
import TeamsCore

struct TeamsComposerView: View {
    var store: TeamsReaderStore
    let chat: TeamsWebChat
    let accountScope: String
    let accountRevision: UUID
    let focusRequest: UUID
    let connect: () -> Void
    var editorReady: ((RichComposerTextView) -> Void)? = nil
    let sent: (String) -> Void
    @AppStorage("sendTeamsOnReturn") private var sendOnReturn = false
    @ViewState<Bool> private var confirmReturnToDraft = false
    @ViewState<CGFloat> private var editorWidth = 300
    @ViewState<Bool> private var showFormatting = false
    @ViewState<TeamsComposerCommand?> private var formatCommand = nil
    @ViewState<Bool> private var showLink = false
    @ViewState<String> private var linkText = ""
    @ViewState<TeamsMentionPickerState> private var mentionPicker = TeamsMentionPickerState()

    private var composer: TeamsComposeStore { store.composer }
    private var draft: Binding<String> {
        Binding(get: { store.accountScope == accountScope && store.accountRevision == accountRevision ? composer.draft(in: chat.id) : "" }, set: { if store.accountScope == accountScope && store.accountRevision == accountRevision { composer.setDraft($0, in: chat.id) } })
    }
    private var richDocument: Binding<TeamsRichDraft> {
        Binding(get: { store.accountScope == accountScope && store.accountRevision == accountRevision ? (composer.richDrafts[chat.id] ?? TeamsRichDraft(plainText: composer.draft(in: chat.id))) : TeamsRichDraft(plainText: "") },
                set: { if store.accountScope == accountScope && store.accountRevision == accountRevision { composer.setRichDraft($0, in: chat.id) } })
    }
    private var unavailableChat: Bool { chat.isDisabled == true || chat.isConversationDeleted == true }
    private var validLink: URL? {
        guard let url = URL(string: linkText), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
              url.user == nil, url.password == nil, url.absoluteString.rangeOfCharacter(from: .controlCharacters) == nil,
              (scheme == "mailto" ? !url.path.isEmpty : url.host?.isEmpty == false) else { return nil }
        return url
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                if let pending = composer.outgoing[chat.id], pending.phase == .uncertain {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Delivery not confirmed", systemImage: "exclamationmark.circle")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                        Text("Check the latest messages before sending again. Your draft is saved.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(pending.text).font(.caption).lineLimit(3).textSelection(.enabled)
                        HStack {
                            Button("Check Delivery") { Task { await store.refreshConversation(chat.id) } }
                                .disabled(!store.connected || store.loadingChatIDs.contains(chat.id))
                            Button("Allow Another Send…") { confirmReturnToDraft = true }
                        }
                        .controlSize(.small)
                    }
                } else if let error = composer.errors[chat.id] {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    if showFormatting {
                        HStack(spacing: 8) {
                            formatButton("Bold", systemImage: "bold", action: .bold)
                            formatButton("Italic", systemImage: "italic", action: .italic)
                            formatButton("Underline", systemImage: "underline", action: .underline)
                            formatButton("Strikethrough", systemImage: "strikethrough", action: .strike)
                            formatButton("Code", systemImage: "chevron.left.forwardslash.chevron.right", action: .code)
                            formatButton("Bulleted list", systemImage: "list.bullet", action: .bulletList)
                            formatButton("Numbered list", systemImage: "list.number", action: .numberedList)
                            formatButton("Block quote", systemImage: "text.quote", action: .quote)
                            formatButton("Increase list indent", systemImage: "increase.indent", action: .indent)
                            formatButton("Decrease list indent", systemImage: "decrease.indent", action: .outdent)
                            Button { linkText = ""; showLink = true } label: { Image(systemName: "link") }.help("Add link").accessibilityLabel("Add link")
                            Menu("Mention") {
                                ForEach(Array((chat.members ?? []).filter { $0.kind == .person && $0.mri != nil && $0.preferredDisplayName != nil }.enumerated()), id: \.offset) { _, member in
                                    Button(member.preferredDisplayName ?? "Person") {
                                        if let mri = member.mri, let name = member.preferredDisplayName { formatCommand = .init(action: .mention(.init(mri: mri, displayName: name))) }
                                    }
                                }
                            }.help("Mention a conversation participant")
                            Spacer()
                        }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.top, 10)
                    }
                    if let reply = composer.replies[chat.id] {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Replying to \(reply.author)").font(.caption.weight(.semibold))
                                Text(reply.preview).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { composer.setReply(nil, in: chat.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).accessibilityLabel("Cancel reply")
                        }
                        .padding(8)
                        .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous))
                        .padding([.horizontal, .top], 8)
                    }
                    TeamsMentionSuggestions(picker: mentionPicker).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    ZStack(alignment: .topLeading) {
                        TeamsRichComposer(document: richDocument, conversationID: accountScope + ":" + accountRevision.uuidString + ":" + chat.id,
                                          focusRequest: focusRequest, command: formatCommand, sendOnReturn: sendOnReturn, send: send,
                                          members: chat.members ?? [], accountID: store.accountID, mentionPicker: mentionPicker, editorReady: editorReady)
                        if draft.wrappedValue.isEmpty {
                            Text("Write a message…")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                                .padding(.leading, 12).padding(.top, 11).allowsHitTesting(false)
                        }
                    }
                    .frame(height: NativeComposer.measuredHeight(text: draft.wrappedValue, width: editorWidth))
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ComposerWidthKey.self, value: geometry.size.width)
                    })
                    .onPreferenceChange(ComposerWidthKey.self) { if $0 > 0 { editorWidth = $0 } }
                    HStack(spacing: 8) {
                        Button { showFormatting.toggle() } label: { Image(systemName: "textformat") }
                            .buttonStyle(.borderless).help(showFormatting ? "Hide formatting" : "Show formatting").accessibilityLabel(showFormatting ? "Hide formatting" : "Show formatting")
                        Button { NSApp.orderFrontCharacterPalette(nil) } label: { Image(systemName: "face.smiling") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Emoji & Symbols").accessibilityLabel("Emoji and Symbols")
                        ViewThatFits(in: .horizontal) {
                            Text(sendOnReturn ? "Return to send · Shift Return for a new line" : "⌘ Return to send")
                                .font(.caption).foregroundStyle(.secondary).fixedSize()
                            EmptyView()
                        }.layoutPriority(-1)
                        Spacer(minLength: 4)
                        if composer.outgoing[chat.id]?.phase == .sending {
                            ProgressView().controlSize(.small)
                            Text("Sending…").font(.caption).foregroundStyle(.secondary)
                        } else if composer.preparing.contains(chat.id) {
                            ProgressView().controlSize(.small)
                            Text("Preparing reply…").font(.caption).foregroundStyle(.secondary)
                        }
                        Button(action: send) {
                            ViewThatFits(in: .horizontal) {
                                Label("Send", systemImage: "arrow.up").font(.callout.weight(.medium)).fixedSize()
                                Image(systemName: "arrow.up").accessibilityLabel("Send")
                            }
                        }
                            .buttonStyle(.borderedProminent).controlSize(.small).layoutPriority(1)
                            .disabled(unavailableChat || !composer.canSend(in: chat.id, at: context.date))
                            .help("Send to this Teams conversation (⌘ Return)")
                    }
                    .padding(.horizontal, 12).padding(.bottom, 10)
                }
                .background(TeamsSurface.input, in: RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous).strokeBorder(TeamsSurface.border, lineWidth: TeamsSurface.borderWidth))
                if unavailableChat || composer.connectionIssue(at: context.date) != nil || composer.persistenceError != nil {
                  HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if unavailableChat {
                        Text("This conversation is closed for sending.")
                    } else if let issue = composer.connectionIssue(at: context.date) {
                        Text(issue)
                        if composer.retryNotBefore == nil {
                            Button("Reconnect", action: connect).buttonStyle(.borderless)
                        }
                    } else if let error = composer.persistenceError {
                        Text(error)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .alert("Allow another send?", isPresented: $confirmReturnToDraft) {
            Button("Cancel", role: .cancel) {}
            Button("Allow Sending") { composer.acknowledgeUncertainDelivery(in: chat.id) }
        } message: {
            Text("Teams may already have received the earlier message. Sending it again could create a duplicate. Your current draft will stay.")
        }
        .alert("Add link", isPresented: $showLink) {
            TextField("https://example.com", text: $linkText)
            Button("Cancel", role: .cancel) { }
            Button("Apply") {
                if let url = validLink { formatCommand = .init(action: .link(url)) }
            }.disabled(validLink == nil)
        } message: { Text("Select text first, then enter an HTTP, HTTPS, or email link.") }
    }

    private func formatButton(_ label: String, systemImage: String, action: TeamsComposerCommand.Action) -> some View {
        Button { formatCommand = .init(action: action) } label: { Image(systemName: systemImage) }
            .help(label).accessibilityLabel(label)
    }

    private func send() {
        guard store.accountScope == accountScope && store.accountRevision == accountRevision, !unavailableChat, composer.canSend(in: chat.id) else { return }
        Task {
            guard store.accountScope == accountScope && store.accountRevision == accountRevision else { return }
            if let id = await store.sendDraft(in: chat.id), store.accountScope == accountScope && store.accountRevision == accountRevision { sent(id) }
        }
    }
}

private struct ComposerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
