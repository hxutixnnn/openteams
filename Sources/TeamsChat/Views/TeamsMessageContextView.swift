import SwiftUI
import TeamsCore

struct TeamsMessageContextView: View {
    var store: TeamsReaderStore
    let chatID: String
    let close: () -> Void
    var loadFilePreview: ((TeamsSharePointAttachment) async throws -> Data)? = nil
    @ViewState<String?> private var visibleMessageID = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Message context").font(.headline)
                    Text("Your conversation stays where you left it.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--timeline-fixture") {
                    Button("Finish fixture image") { NotificationCenter.default.post(name: Notification.Name("TeamsFixtureReleaseImage"), object: nil) }
                }
                #endif
                Button("Return to conversation", action: close)
            }.padding(20)
            Divider()
            if let error = store.contextActionError { Text(error).font(.caption).foregroundStyle(.secondary).padding(8) }
            if store.contextLoading {
                Spacer(); ProgressView("Loading message context…"); Spacer()
            } else if let error = store.contextError {
                Spacer()
                ContentUnavailableView {
                    Label("Context unavailable", systemImage: "text.bubble")
                } description: { Text(error) } actions: {
                    if let target = store.contextTargetID { Button("Try Again") { Task { await store.openMessageContext(in: chatID, targetID: target) } } }
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if store.contextBackwardToken != nil {
                                Button(store.contextBackwardLoading ? "Loading earlier messages…" : (store.contextBackwardError ?? "Load earlier messages")) {
                                    Task { await store.loadContextPage(.backward) }
                                }.disabled(store.contextBackwardLoading)
                            }
                            ForEach(store.contextMessages) { message in
                                let accountScope = store.accountScope
                                let contextScope = store.contextRevision
                                VStack(alignment: .leading, spacing: 4) {
                                    if message.id == store.contextTargetID { Text("Original message").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                                    TeamsMessageRow(message: message, compact: false, grouped: false, accountID: store.accountID,
                                                    canEdit: false, canReact: store.canReact(in: chatID, messageID: message.id),
                                                    mediaRevision: store.mediaRevision, mediaRefreshRevision: store.mediaRefreshRevision,
                                                    loadImage: { try await store.imageData(for: $0, fullSize: $1) },
                                                    loadPhoto: { try await store.profilePhoto(for: $0) },
                                                    replyAuthor: { store.replyAuthor($0, in: chatID) },
                                                    canJumpToMessage: { id in store.contextMessages.contains { $0.id == id } || (store.connected && !id.isEmpty && id.utf8.count <= 32 && id.utf8.allSatisfy { (48...57).contains($0) }) },
                                                    jumpToMessage: { id in
                                                        if store.contextMessages.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) }
                                                        else { Task { guard contextScope == store.contextRevision, accountScope == store.accountScope else { return }; await store.openMessageContext(in: chatID, targetID: id) } }
                                                    },
                                                    action: { action in
                                                        Task { await store.messageAction(action, chatID: chatID, messageID: message.id, accountScope: accountScope, contextScope: contextScope) }
                                                    }, loadFilePreview: loadFilePreview, filePreviewConnected: store.connected,
                                                    filePreviewIdentity: contextScope, contextActionsOnly: true)
                                    if !message.isDeleted {
                                        HStack {
                                            Button("Reply") {
                                                guard accountScope == store.accountScope, contextScope == store.contextRevision, store.contextChatID == chatID else { return }
                                                store.composer.setReply(.init(messageID: message.id, preview: message.body.text, author: message.author.name), in: chatID)
                                                close()
                                            }
                                            Menu("React") {
                                                ForEach([("like", "👍 Like"), ("heart", "❤️ Love"), ("laugh", "😆 Laugh"), ("surprised", "😮 Surprised")], id: \.0) { key, label in
                                                    let mine = message.reactions.contains { $0.key == key && ($0.userIDs.contains(store.accountID) || $0.userIDs.contains("8:orgid:" + store.accountID)) }
                                                    Button(mine ? "Remove \(label)" : label) { Task { await store.messageAction(mine ? "remove:" + key : key, chatID: chatID, messageID: message.id, accountScope: accountScope, contextScope: contextScope) } }
                                                }
                                            }.disabled(!store.canReact(in: chatID, messageID: message.id))
                                            if store.reactionNeedsConfirmation(in: chatID, messageID: message.id) {
                                                Button("Check reaction") { Task { await store.refreshContextReaction(chatID: chatID, messageID: message.id, contextScope: contextScope) } }
                                            }
                                        }.buttonStyle(.borderless).font(.caption)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(message.id == store.contextTargetID ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .id(message.id)
                            }
                            if store.contextForwardToken != nil {
                                Button(store.contextForwardLoading ? "Loading later messages…" : (store.contextForwardError ?? "Load later messages")) {
                                    Task { await store.loadContextPage(.forward) }
                                }.disabled(store.contextForwardLoading)
                            }
                        }.scrollTargetLayout().padding(20)
                    }
                    .scrollPosition(id: $visibleMessageID, anchor: .top)
                    .onChange(of: store.contextLoading) { _, loading in
                        if !loading, let id = store.contextTargetID { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = store.contextTargetID { Task { @MainActor in await Task.yield(); proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .modifier(TeamsInsetPanel())
        .background(TeamsSurface.window)
        .buttonBorderShape(.roundedRectangle(radius: TeamsSurface.controlRadius))
        .frame(minWidth: 540, minHeight: 420)
    }
}
