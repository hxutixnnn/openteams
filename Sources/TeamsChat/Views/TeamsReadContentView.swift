import AppKit
import SwiftUI
import TeamsCore

struct TeamsReadContentView: View {
    var store: TeamsReaderStore
    let refreshCoordinator: TeamsRefreshCoordinator
    var notificationRouter: TeamsNotificationRouter
    let connect: () -> Void
    var persistSelection = true
    #if DEBUG
    var fixtureStartupConversation: PerformanceFixtureStartupConversation? = nil
    @ViewState<String> private var fixtureStartupAccountScope = ""
    #endif
    var loadFilePreview: ((TeamsSharePointAttachment) async throws -> Data)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("teamsSelectedChat") private var selectedID = ""
    @SceneStorage("teamsSelectionAccount") private var selectionAccount = ""
    @SceneStorage("teamsShowInspector") private var showInspector = false
    @AppStorage("teamsLastSelectedChat") private var lastSelectedChat = ""
    @AppStorage("teamsLastSelectedAccount") private var lastSelectedAccount = ""
    @ViewState<InspectorTab> private var inspectorTab = .people
    @ViewState<String> private var conversationFilter = ""
    @ViewState<String> private var messageQuery = ""
    @ViewState<TeamsMessageDestination?> private var jumpToMessage: TeamsMessageDestination? = nil
    @ViewState<UUID> private var focusRequest = UUID()
    @ViewState<ConversationSearchFocus> private var searchFocus = ConversationSearchFocus()
    @ViewState<NewChatPresentation?> private var newChatPresentation = nil
    @ViewState<NavigationSplitViewVisibility> private var columnVisibility = .all
    @ViewState<UUID> private var windowID = UUID()
    @ViewState<String?> private var loadedConversationKey = nil

    private var selectedChat: TeamsWebChat? { store.conversation(selectedID) }
    private var windowKey: String { "\(scenePhase == .active)-\(store.connected)-\(store.accountScope)-\(selectionAccount)-\(selectedID)" }
    #if DEBUG
    private var conversationKey: String { "\(store.accountScope)-\(store.connected)-\(selectedID)" + (fixtureStartupConversation == .planning ? "-" + fixtureStartupAccountScope : "") }
    #else
    private var conversationKey: String { "\(store.accountScope)-\(store.connected)-\(selectedID)" }
    #endif

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TeamsReadSidebar(store: store,
                             selection: Binding(get: { selectedID }, set: { selectedID = $0 ?? "" }),
                             filter: $conversationFilter, connect: connect,
                             newChat: { newChatPresentation = .init(account: store.accountScope, revision: store.accountRevision) })
                .navigationTitle("Chats")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            Group {
                if selectedChat != nil { detail }
                else { detail.frame(maxWidth: .infinity, maxHeight: .infinity).modifier(TeamsInsetPanel()) }
            }
            .toolbar { toolbar }
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .navigationSplitViewStyle(.balanced)
        .background(TeamsSurface.window)
        .buttonBorderShape(.roundedRectangle(radius: TeamsSurface.controlRadius))
        .background(TeamsWindowProbe { window in
            refreshCoordinator.attachWindow(windowID, window: window)
            routePendingNotification()
        })
        .sheet(item: $newChatPresentation) { presentation in
            TeamsNewChatView(store: store, account: presentation.account, accountRevision: presentation.revision,
                             ownsPresentation: { newChatPresentation?.id == presentation.id && store.accountScope == presentation.account && store.accountRevision == presentation.revision }, connect: connect) { id in
                guard newChatPresentation?.id == presentation.id, store.accountScope == presentation.account, store.accountRevision == presentation.revision else { return }
                selectedID = id; newChatPresentation = nil
            }
        }
        .focusedSceneValue(\.chatActions, ChatWindowActions(
            search: openSearch,
            details: { inspectorTab = .people; showInspector.toggle() },
            compose: { focusRequest = UUID() }, canCompose: selectedChat != nil
        ))
        .onChange(of: store.connected) { _, connected in
            if !connected && !store.sessionExpired { newChatPresentation = nil }
            routePendingNotification()
        }
        .onChange(of: notificationRouter.pending, initial: true) { _, _ in routePendingNotification() }
        .onChange(of: notificationRouter.ownerWindowID) { _, _ in routePendingNotification() }
        .onChange(of: store.serverChatSnapshot?.revision) { _, _ in routePendingNotification() }
        .onChange(of: store.hasMoreChats) { _, _ in routePendingNotification() }
        .onChange(of: windowKey, initial: true) { _, _ in
            refreshCoordinator.updateWindow(windowID, chatID: selectionAccount == store.accountScope ? selectedID : "", active: scenePhase == .active && store.connected)
        }
        .onDisappear {
            refreshCoordinator.removeWindow(windowID)
            if notificationRouter.ownerWindowID == windowID {
                notificationRouter.assignOwner(refreshCoordinator.activateNotificationWindow())
            }
        }
        .onChange(of: store.accountRevision) { _, _ in newChatPresentation = nil }
        .onChange(of: store.accountScope) { _, _ in newChatPresentation = nil }
        .onChange(of: store.accountScope, initial: true) { _, accountScope in
            newChatPresentation = nil
            guard !store.accountID.isEmpty else { return }
            #if DEBUG
            if !persistSelection, fixtureStartupConversation == .planning {
                selectedID = ""
                selectionAccount = ""
                fixtureStartupAccountScope = accountScope
            }
            #endif
            if selectionAccount != accountScope {
                selectedID = persistSelection && lastSelectedAccount == accountScope ? lastSelectedChat : ""
                selectionAccount = accountScope
                conversationFilter = ""
                messageQuery = ""
            }
            reconcileSelection()
            routePendingNotification()
        }
        .onChange(of: store.chats.map(\.id)) { _, _ in reconcileSelection(); routePendingNotification() }
        .onChange(of: store.isLoadingChats) { _, loading in if !loading { reconcileSelection(); routePendingNotification() } }
        .onChange(of: store.retryNotBefore) { _, deadline in if deadline == nil { routePendingNotification() } }
        .alert("Notification", isPresented: Binding(get: { notificationRouter.error != nil }, set: { if !$0 { notificationRouter.clearError() } })) {
            Button("OK") { notificationRouter.clearError() }
        } message: { Text(notificationRouter.error ?? "") }
        .onChange(of: selectedID) { _, _ in
            messageQuery = ""
            jumpToMessage = nil
            if persistSelection && selectedChat != nil {
                lastSelectedChat = selectedID
                lastSelectedAccount = store.accountScope
            }
        }
        .onChange(of: conversationKey) { _, _ in loadedConversationKey = nil }
        .task(id: conversationKey) { await loadSelectedConversation() }
    }

    private func loadSelectedConversation() async {
        let key = conversationKey
        loadedConversationKey = nil
        #if DEBUG
        if fixtureStartupConversation == .planning && fixtureStartupAccountScope != store.accountScope { return }
        #endif
        guard !selectedID.isEmpty, !store.accountID.isEmpty else { return }
        await store.loadConversation(selectedID)
        if !Task.isCancelled, key == conversationKey { loadedConversationKey = key }
    }

    @ViewBuilder private var detail: some View {
        if let chat = selectedChat {
            TeamsConversationLayout(showInspector: $showInspector) {
                TeamsReadDetailView(store: store, chat: chat, initialLoadComplete: loadedConversationKey == conversationKey, accountScope: store.accountScope, accountRevision: store.accountRevision, selectedChatID: $selectedID, jumpToMessage: $jumpToMessage, connect: connect, focusRequest: focusRequest, loadFilePreview: loadFilePreview)
                    .id(store.accountRevision.uuidString + ":" + chat.id)
            } inspector: {
                TeamsReadInspector(store: store, chat: chat, accountScope: store.accountScope, accountRevision: store.accountRevision, isCurrent: { selectedID == chat.id }, connect: connect, tab: $inspectorTab,
                                   query: $messageQuery, jumpToMessage: $jumpToMessage, searchFocus: searchFocus)
            }
            .navigationTitle(store.conversationTitle(chat))
        } else if store.isLoadingChats && store.chats.isEmpty {
            ProgressView("Loading chats…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.chats.isEmpty && !store.connected {
            ContentUnavailableView {
                Label("Connect to Teams", systemImage: "person.crop.circle.badge.checkmark")
            } description: {
                Text("Sign in with your Teams account to read and reply to your chats on this Mac.")
            } actions: {
                Button("Connect to Teams", action: connect).buttonStyle(.borderedProminent)
            }
        } else if let error = store.chatListError, store.chats.isEmpty {
            ContentUnavailableView {
                Label("Chats could not load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                if store.sessionExpired {
                    Button("Reconnect to Teams", action: connect)
                } else {
                    Button("Try Again") { Task { await store.refreshChats() } }
                }
            }
        } else {
            ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Your conversations are in the sidebar."))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: openSearch) { Label("Find in Conversation", systemImage: "magnifyingglass") }
                .disabled(selectedChat == nil)
                .help("Find in Conversation (⌘F)")
            Button {
                inspectorTab = .people
                showInspector.toggle()
            } label: { Label("Conversation Details", systemImage: "sidebar.right") }
                .disabled(selectedChat == nil)
                .help("Conversation Details (⌥⌘I)")
            Menu {
                Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r").disabled(!store.connected || store.isLoadingChats)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            } label: { Label("More", systemImage: "ellipsis") }
                .help("More options")
        }
    }

    private func openSearch() {
        guard selectedChat != nil else { return }
        inspectorTab = .search
        showInspector = true
        searchFocus.focus()
    }

    private func reconcileSelection() {
        guard !store.isLoadingChats else { return }
        #if DEBUG
        if !persistSelection, let fixtureStartupConversation, selectedChat == nil,
           let first = fixtureStartupConversation.initialChat(in: store.chats) {
            selectedID = first.id
            return
        }
        #endif
        if selectedChat == nil, let first = store.chats.first(where: { $0.hidden != true && $0.isConversationDeleted != true }) {
            selectedID = first.id
        }
    }

    private func refresh() async {
        let chatID = selectedID
        await store.refreshChats()
        await store.refreshConversationFolders()
        guard !Task.isCancelled, !chatID.isEmpty else { return }
        await store.refreshConversation(chatID)
    }

    private func routePendingNotification() {
        guard let pending = notificationRouter.pending else { return }
        if notificationRouter.ownerWindowID == nil {
            guard let owner = refreshCoordinator.activateNotificationWindow() else { return }
            notificationRouter.assignOwner(owner)
        }
        guard notificationRouter.ownerWindowID == windowID else { return }
        let contains = store.conversation(pending.chatID) != nil
        guard let destination = notificationRouter.takeIfAvailable(accountScope: store.accountID.isEmpty ? "" : store.accountScope,
                                                                    connected: store.connected, containsChat: contains,
                                                                    loading: store.isLoadingChats || store.serverChatSnapshot == nil, hasMore: store.hasMoreChats) else {
            guard notificationRouter.pending == pending, store.connected, store.accountScope == pending.accountScope,
                  !contains, !store.isLoadingChats, store.serverChatSnapshot != nil, store.hasMoreChats else { return }
            Task { @MainActor in
                guard let result = await notificationRouter.loadNextPage(store: store, destination: pending), result == .attempted else { return }
                if store.chatListError != nil { notificationRouter.failPending("Could not find the conversation. Try opening it from Chat.") }
                else { routePendingNotification() }
            }
            return
        }
        selectionAccount = destination.accountScope
        selectedID = destination.chatID
    }
}


private struct NewChatPresentation: Identifiable {
    let id = UUID()
    let account: String
    let revision: UUID
}
