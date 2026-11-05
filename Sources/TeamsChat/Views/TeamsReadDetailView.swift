import SwiftUI
import TeamsCore

struct TeamsMessageDestination: Equatable {
    let messageID: String
    let chatID: String
    let accountScope: String
    let nonce = UUID()
}


struct TeamsReadDetailView: View {
    var store: TeamsReaderStore
    let chat: TeamsWebChat
    var initialLoadComplete = true
    let accountScope: String
    let accountRevision: UUID
    @Binding var selectedChatID: String
    @Binding var jumpToMessage: TeamsMessageDestination?
    let connect: () -> Void
    let focusRequest: UUID
    var loadFilePreview: ((TeamsSharePointAttachment) async throws -> Data)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage("compactMessages") private var compact = false
    @ViewState<String?> private var restoreAnchor: String? = nil
    @ViewState<Int> private var newMessageCount = 0
    @ViewState<Bool> private var positionedInitialMessages = false
    @ViewState<Bool> private var completedInitialLoadPosition = false
    @ViewState<Bool> private var userHasScrolled = false
    @ViewState<UUID> private var scrollIntentRevision = UUID()
    @ViewState<Bool> private var atBottom = true
    @ViewState<Bool> private var timelineReady = false
    @ViewState<String?> private var lastAutomaticReadAttempt = nil
    @ViewState<TeamsMessageEditSession?> private var editingMessage = nil
    @ViewState<String?> private var editOpenError = nil
    @ViewState<UUID> private var editOpenRevision = UUID()
    @ViewState<UUID?> private var closingEditID = nil
    @ViewState<TeamsRenderedMessage?> private var deletingMessage = nil
    @ViewState<String> private var deletingAccount = ""
    @ViewState<Bool> private var showMessageContext = false

    private var messages: [TeamsRenderedMessage] { store.messages(in: chat.id) }
    private var loading: Bool { store.isLoadingConversation(chat.id) }

    var body: some View {
        VStack(spacing: 0) {
            status
            timeline
            footer
        }
        .sheet(item: $editingMessage) { edit in
            TeamsMessageEditSheet(document: Binding(get: { edit.document }, set: { edit.document = $0 }), identity: edit.id.uuidString,
                                  status: edit.status, saving: edit.saving || closingEditID == edit.id, uncertain: edit.uncertain, completed: edit.completed, hasSavedDraft: edit.hasSavedDraft,
                                  reply: try? TeamsChatActionsClient.editableContent(edit.original).reply, members: chat.members ?? [], accountID: store.accountID,
                                  save: { Task { await store.saveMessageEdit(edit) } },
                                  check: { Task { await store.checkMessageEdit(edit) } },
                                  cancel: { closeEdit(edit) },
                                  discard: { discardEdit(edit) })
                .interactiveDismissDisabled(edit.saving || closingEditID == edit.id || (edit.hasSavedDraft && !edit.uncertain && !edit.completed))
        }
        .alert("Cannot edit this message", isPresented: Binding(get: { editOpenError != nil }, set: { if !$0 { editOpenError = nil } })) {
            Button("OK") { editOpenError = nil }
        } message: {
            Text(editOpenError ?? "")
        }
        .alert("Delete this message?", isPresented: Binding(get: { deletingMessage != nil }, set: { if !$0 { deletingMessage = nil } })) {
            Button("Cancel", role: .cancel) { deletingMessage = nil }
            Button("Delete", role: .destructive) {
                if let message = deletingMessage { let account = deletingAccount; Task { await store.messageAction("delete", chatID: chat.id, messageID: message.id, accountScope: account, accountRevision: accountRevision) } }
                deletingMessage = nil
            }
        }
        .sheet(isPresented: $showMessageContext, onDismiss: { store.closeMessageContext() }) {
            TeamsMessageContextView(store: store, chatID: chat.id, close: { showMessageContext = false }, loadFilePreview: loadFilePreview)
        }
        .onChange(of: chat.id) { _, _ in showMessageContext = false; store.closeMessageContext(); editOpenRevision = UUID(); editingMessage = nil; deletingMessage = nil; closingEditID = nil }
        .onChange(of: store.accountScope) { _, _ in showMessageContext = false; store.closeMessageContext(); editOpenRevision = UUID(); editingMessage = nil; deletingMessage = nil; closingEditID = nil }
    }

    @ViewBuilder private var status: some View {
        if let error = store.chatErrors[chat.id] {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer(minLength: 12)
                if store.sessionExpired || !store.connected {
                    Button("Reconnect", action: connect)
                } else {
                    Button("Try Again") { Task { await store.refreshConversation(chat.id) } }.disabled(loading)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: TeamsSurface.cardRadius, style: .continuous))
            .padding(TeamsSurface.inset)
        } else if store.sessionExpired || !store.connected {
            HStack {
                Label("Showing messages saved on this Mac", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reconnect", action: connect).buttonStyle(.borderless)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
        }
        if let warning = store.cacheWarning {
            Text(warning).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 8)
        }
    }

    private func noteTimelineIntent() { userHasScrolled = true; scrollIntentRevision = UUID(); restoreAnchor = nil }

    private func scheduleAutomaticScroll(_ proxy: ScrollViewProxy, to id: String, initial: Bool) {
        let intent = scrollIntentRevision
        Task { @MainActor in
            await Task.yield()
            guard scrollIntentRevision == intent, selectedChatID == chat.id, store.accountScope == accountScope,
                  store.accountRevision == accountRevision, restoreAnchor == nil,
                  initial ? !userHasScrolled : atBottom else { return }
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private var useLegacyObserver: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--timeline-force-legacy-observer") { return true }
        #endif
        if #available(macOS 15, *) { return false }
        return true
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.hasOlderMessages(chat.id) {
                        HStack {
                            Spacer()
                            Button("Load Older Messages") {
                                let anchor = messages.first?.id
                                noteTimelineIntent()
                                let intent = scrollIntentRevision
                                restoreAnchor = anchor
                                Task {
                                    await store.loadOlderMessages(chat.id)
                                    await Task.yield()
                                    if scrollIntentRevision == intent, let anchor, store.accountRevision == accountRevision, selectedChatID == chat.id { proxy.scrollTo(anchor, anchor: .top) }
                                    if restoreAnchor == anchor { restoreAnchor = nil }
                                }
                            }
                            .disabled(loading || !store.connected)
                            Spacer()
                        }
                        .padding(.bottom, 6)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let accountScope = store.accountScope
                        VStack(alignment: .leading, spacing: 0) {
                            if index == 0 || !Calendar.current.isDate(message.createdAt, inSameDayAs: messages[index - 1].createdAt) {
                                dateSeparator(message.createdAt)
                            }
                            TeamsMessageRow(message: message, compact: compact, grouped: isGrouped(at: index), accountID: store.accountID,
                                            canEdit: store.canEditMessage(in: chat.id, messageID: message.id), canReact: store.canReact(in: chat.id, messageID: message.id),
                                            mediaRevision: store.mediaRevision, mediaRefreshRevision: store.mediaRefreshRevision, loadImage: { try await store.imageData(for: $0, fullSize: $1) },
                                            loadPhoto: { try await store.profilePhoto(for: $0) },
                                            replyAuthor: { store.replyAuthor($0, in: chat.id) },
                                            canJumpToMessage: { id in messages.contains(where: { $0.id == id }) || (store.connected && !id.isEmpty && id.utf8.count <= 32 && id.utf8.allSatisfy { (48...57).contains($0) }) },
                                            jumpToMessage: { id in
                                                noteTimelineIntent()
                                                if messages.contains(where: { $0.id == id }) { jumpToMessage = .init(messageID: id, chatID: chat.id, accountScope: accountScope) }
                                                else { showMessageContext = true; Task { guard showMessageContext, selectedChatID == chat.id, accountScope == store.accountScope else { return }; await store.openMessageContext(in: chat.id, targetID: id) } }
                                            }, action: { action in
                                if action == "reply" { store.composer.setReply(.init(messageID: message.id, preview: message.body.text, author: message.author.name), in: chat.id) }
                                else if action == "edit" { openEdit(messageID: message.id, accountScope: accountScope) }
                                else if action == "delete" { deletingAccount = self.accountScope; deletingMessage = message }
                                else if action == "check-delete" { Task { await store.checkDeletion(in: chat.id, messageID: message.id, expectedScope: self.accountScope, expectedRevision: accountRevision) } }
                                else if action == "dismiss-delete" { Task { await store.dismissRejectedDeletion(in: chat.id, messageID: message.id, expectedScope: self.accountScope, expectedRevision: accountRevision) } }
                                else { Task { await store.messageAction(action, chatID: chat.id, messageID: message.id, accountScope: accountScope) } }
                            }, loadFilePreview: loadFilePreview, filePreviewConnected: store.connected, deletionStage: store.deletionStage(in: chat.id, messageID: message.id), deletionMessage: store.deletionMessage(in: chat.id, messageID: message.id), canDelete: store.canDelete(in: chat.id, messageID: message.id))
                        }
                        .id(message.id)
                        .task(id: "\(accountRevision.uuidString):\(chat.id):\(message.id)") {
                            await store.loadDeletionStatus(in: chat.id, messageID: message.id, expectedScope: self.accountScope, expectedRevision: accountRevision)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background {
                    if useLegacyObserver {
                        TeamsLegacyScrollObserver(changed: { value in
                            if atBottom != value { atBottom = value }
                            if value, newMessageCount != 0 { newMessageCount = 0 }
                        }, grewAtBottom: {
                            guard restoreAnchor == nil, let last = messages.last?.id else { return }
                            scheduleAutomaticScroll(proxy, to: last, initial: false)
                        }, userScrolled: { noteTimelineIntent() }, layoutReady: { isBottom, hasScrollableContent in
                            if !timelineReady { timelineReady = true }
                            if atBottom != isBottom { atBottom = isBottom }
                            guard hasScrollableContent, !userHasScrolled, let last = messages.last?.id else { return }
                            if isBottom { if !completedInitialLoadPosition { completedInitialLoadPosition = true } }
                            else { scheduleAutomaticScroll(proxy, to: last, initial: true) }
                        })
                    }
                }
            }
            .modifier(TeamsBottomObserver(enabled: !useLegacyObserver, changed: { value in
                if atBottom != value { atBottom = value }
                if value, newMessageCount != 0 { newMessageCount = 0 }
            }, grewAtBottom: {
                guard restoreAnchor == nil, let last = messages.last?.id else { return }
                scheduleAutomaticScroll(proxy, to: last, initial: false)
            }, userScrolled: { noteTimelineIntent() }, layoutReady: { isBottom, hasScrollableContent in
                if !timelineReady { timelineReady = true }
                if atBottom != isBottom { atBottom = isBottom }
                guard hasScrollableContent, !userHasScrolled, let last = messages.last?.id else { return }
                if isBottom { if !completedInitialLoadPosition { completedInitialLoadPosition = true } }
                else { scheduleAutomaticScroll(proxy, to: last, initial: true) }
            }))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                if atBottom, let last = messages.last?.id {
                    scheduleAutomaticScroll(proxy, to: last, initial: false)
                }
            }
            .task(id: "\(chat.id):\(messages.last?.id ?? ""):\(atBottom):\(loading):\(timelineReady):\(chat.isRead == false):\(initialLoadComplete):\(scenePhase):\(controlActiveState):\(store.pendingReadChatIDs.contains(chat.id))") {
                if store.pendingReadChatIDs.contains(chat.id) { lastAutomaticReadAttempt = nil; return }
                guard initialLoadComplete, scenePhase == .active, controlActiveState == .key, timelineReady, atBottom, !loading, chat.isRead == false, let messageID = messages.last?.id else { return }
                let attempt = "\(messageID):\(store.pendingReadChatIDs.contains(chat.id))"
                guard lastAutomaticReadAttempt != attempt else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, selectedChatID == chat.id, store.accountRevision == accountRevision else { return }
                lastAutomaticReadAttempt = attempt
                await store.retryVisibleConversationRead(chat.id, messageID: messageID)
                if Task.isCancelled, lastAutomaticReadAttempt == attempt { lastAutomaticReadAttempt = nil }
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--timeline-observer-diagnostics") {
                    Text("Fixture observer: bottom \(atBottom) · user \(userHasScrolled)")
                        .font(.caption).padding(4).background(.regularMaterial).allowsHitTesting(false)
                }
                #endif
            }
            .overlay {
                if messages.isEmpty {
                    if loading {
                        ProgressView("Loading messages…")
                    } else if store.chatErrors[chat.id] == nil {
                        ContentUnavailableView("No messages yet", systemImage: "bubble.left",
                                               description: Text("Messages will appear here after the conversation updates."))
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if newMessageCount > 0 {
                    Button {
                        noteTimelineIntent()
                        if let last = messages.last?.id {
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last, anchor: .bottom) }
                        }
                        newMessageCount = 0
                    } label: {
                        Label("\(newMessageCount) new \(newMessageCount == 1 ? "message" : "messages")", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .padding(18)
                }
            }
            .onChange(of: messages.map(\.id), initial: true) { old, new in
                guard !new.isEmpty else { return }
                if let anchor = restoreAnchor {
                    proxy.scrollTo(anchor, anchor: .top)
                } else if !positionedInitialMessages {
                    positionedInitialMessages = true
                    if let last = new.last { scheduleAutomaticScroll(proxy, to: last, initial: true) }
                } else {
                    let update = TeamsTimelineUpdate.decide(previous: old, current: new, atBottom: atBottom)
                    if update.scrollToBottom, let last = new.last {
                            newMessageCount = 0
                            scheduleAutomaticScroll(proxy, to: last, initial: false)
                    } else { newMessageCount += update.newMessageCount }
                }
            }
            .onChange(of: loading) { wasLoading, isLoading in
                guard wasLoading, !isLoading, !completedInitialLoadPosition, !messages.isEmpty else { return }
                guard !userHasScrolled, let last = messages.last?.id else { return }
                scheduleAutomaticScroll(proxy, to: last, initial: true)
            }
            .onChange(of: jumpToMessage) { _, destination in
                guard let destination, destination.chatID == chat.id, destination.accountScope == store.accountScope, store.accountRevision == accountRevision else { return }
                let id = destination.messageID
                noteTimelineIntent()
                if messages.contains(where: { $0.id == id }) { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                else {
                    showMessageContext = true
                    Task { guard showMessageContext, selectedChatID == destination.chatID, store.accountScope == destination.accountScope, store.accountRevision == accountRevision else { return }; await store.openMessageContext(in: chat.id, targetID: id) }
                }
            }
        }
    }

    private func openEdit(messageID: String, accountScope: String) {
        let revision = UUID(), chatID = chat.id
        editOpenRevision = revision
        Task { @MainActor in
            do {
                let edit = try await store.beginMessageEdit(in: chatID, messageID: messageID, accountScope: accountScope)
                guard editOpenRevision == revision, selectedChatID == chatID, store.accountScope == accountScope else { return }
                editingMessage = edit
            } catch is CancellationError { }
            catch {
                guard editOpenRevision == revision, selectedChatID == chatID, store.accountScope == accountScope else { return }
                if error is TeamsRichEditImport.ImportError || (error as? TeamsChatActionError) == .unsupportedMessage {
                    editOpenError = "This message contains content that cannot yet be safely preserved while editing."
                } else if error is TeamsMessageEditError { editOpenError = "The saved edit could not be read on this Mac. Try again." }
                else { editOpenError = "This message could not be opened for editing. Reconnect and try again." }
            }
        }
    }

    private func closeEdit(_ edit: TeamsMessageEditSession) {
        guard closingEditID == nil else { return }
        guard edit.hasSavedDraft, !edit.uncertain, !edit.completed else { editingMessage = nil; return }
        closingEditID = edit.id
        Task { @MainActor in
            let saved = await store.retainMessageEdit(edit)
            if closingEditID == edit.id { closingEditID = nil }
            if saved, editingMessage?.id == edit.id, store.accountScope == edit.accountScope { editingMessage = nil }
        }
    }

    private func discardEdit(_ edit: TeamsMessageEditSession) {
        guard closingEditID == nil else { return }
        closingEditID = edit.id
        Task { @MainActor in
            let discarded = await store.discardMessageEdit(edit)
            if closingEditID == edit.id { closingEditID = nil }
            if discarded, editingMessage?.id == edit.id, store.accountScope == edit.accountScope { editingMessage = nil }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.5)
            TeamsComposerView(store: store, chat: chat, accountScope: accountScope, accountRevision: accountRevision, focusRequest: focusRequest, connect: connect) { id in
                guard store.accountScope == accountScope else { return }
                newMessageCount = 0
                jumpToMessage = .init(messageID: id, chatID: chat.id, accountScope: accountScope)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    private func isGrouped(at index: Int) -> Bool {
        guard index > 0 else { return false }
        let current = messages[index], previous = messages[index - 1]
        return current.author.id == previous.author.id &&
            Calendar.current.isDate(current.createdAt, inSameDayAs: previous.createdAt) &&
            current.createdAt.timeIntervalSince(previous.createdAt) >= 0 &&
            current.createdAt.timeIntervalSince(previous.createdAt) < 300
    }

    private func dateSeparator(_ date: Date) -> some View {
        HStack(spacing: 14) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.vertical, 14)
    }
}

private struct TeamsBottomObserver: ViewModifier {
    let enabled: Bool
    let changed: (Bool) -> Void
    let grewAtBottom: () -> Void
    let userScrolled: () -> Void
    let layoutReady: (Bool, Bool) -> Void
    @ViewState<Bool> private var userScrolling = false

    private struct Metrics: Equatable {
        let offset: CGFloat
        let viewport: CGFloat
        let content: CGFloat
        var atBottom: Bool { offset + viewport >= content - 40 }
    }

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *), enabled {
            content.onScrollPhaseChange { _, phase in
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if userScrolling { userScrolled() }
            }
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(offset: geometry.contentOffset.y, viewport: geometry.containerSize.height, content: geometry.contentSize.height)
            } action: { old, new in
                if new.content > 0 { layoutReady(new.atBottom, new.content > new.viewport + 1) }
                if new.content > old.content + 1 && old.atBottom && !new.atBottom && !userScrolling {
                    grewAtBottom()
                    return
                }
                changed(new.atBottom)
            }
        } else { content }
    }
}
