import SwiftUI
import TeamsCore

struct ContentView: View {
    var store: FixtureChatStore
    var showcaseDetails = false
    @SceneStorage("selectedConversation") private var selectedID = ""
    @AppStorage("lastConversationID") private var lastConversationID = "design"
    @SceneStorage("showInspector") private var showInspector = false
    @ViewState<InspectorTab> private var inspectorTab = .people
    @ViewState<String> private var conversationFilter = ""
    @ViewState<String> private var messageQuery = ""
    @ViewState<String?> private var jumpToMessage: String? = nil
    @ViewState<UUID> private var focusComposer = UUID()
    @ViewState<ConversationSearchFocus> private var searchFocus = ConversationSearchFocus()

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, selection: Binding(get: { selectedID }, set: { selectedID = $0 ?? "" }), filter: $conversationFilter)
                .navigationTitle("Chats")
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 350)
        } detail: {
            if let conversation = store.conversation(selectedID) {
                ChatDetailView(store: store, conversation: conversation, jumpToMessage: $jumpToMessage,
                               focusComposer: focusComposer)
                    .navigationTitle(conversation.title)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button(action: openSearch) { Label("Find in Conversation", systemImage: "magnifyingglass") }
                                .help("Find in Conversation (⌘F)")
                            Button {
                                inspectorTab = .people
                                showInspector.toggle()
                            } label: { Label("Conversation Details", systemImage: "sidebar.right") }
                            .help("Conversation Details (⌥⌘I)")
                            SettingsLink { Label("Settings", systemImage: "gearshape") }
                                .help("Settings (⌘,)")
                        }
                    }
                    .inspector(isPresented: $showInspector) {
                        ChatInspector(store: store, conversation: conversation, tab: $inspectorTab,
                                      query: $messageQuery, jumpToMessage: $jumpToMessage, searchFocus: searchFocus)
                            .inspectorColumnWidth(min: 260, ideal: 290, max: 380)
                    }
            } else {
                ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Your conversations are in the sidebar."))
            }
        }
        .focusedSceneValue(\.chatActions, ChatWindowActions(
            search: openSearch,
            details: { inspectorTab = .people; showInspector.toggle() },
            compose: { focusComposer = UUID() }
        ))
        .onAppear {
            if showcaseDetails { showInspector = true }
            if store.conversation(selectedID) == nil {
                selectedID = store.conversation(lastConversationID)?.id ?? "design"
            }
        }
        .onChange(of: selectedID, initial: true) { _, id in
            store.markRead(id)
            if store.conversation(id) != nil { lastConversationID = id }
            messageQuery = ""
            jumpToMessage = nil
        }
    }

    private func openSearch() {
        inspectorTab = .search
        showInspector = true
        searchFocus.focus()
    }
}
