import SwiftUI
import TeamsCore

struct SidebarView: View {
    var store: FixtureChatStore
    @Binding var selection: String?
    @ViewState private var filterFocus = ConversationSearchFocus()
    @Binding var filter: String

    private var conversations: [Conversation] {
        store.conversations.filter {
            filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section("Favorites") {
                ForEach(conversations.filter(\.isFavorite)) { row($0) }
            }
            Section("Recent") {
                ForEach(conversations.filter { !$0.isFavorite }) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            ConversationSearchField(text: $filter, focus: filterFocus, accessibilityName: "Find a conversation",
                                    placeholder: "Filter conversations", focusOnAppear: false)
                .frame(height: 28)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        }
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                PersonAvatar(person: store.person(ChatFixtures.me), size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Alex Morgan").font(.callout.weight(.medium))
                    Text("Sample workspace").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "leaf").foregroundStyle(ChatTheme.accent)
                    .help("Demo conversations, stored only on this Mac")
            }
            .padding(14)
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack(spacing: 10) {
            ConversationIcon(conversation: conversation)
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(preview(conversation)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(ChatTheme.accent.opacity(0.15), in: Capsule())
                    .accessibilityLabel("\(conversation.unreadCount) unread messages")
            }
        }
        .padding(.vertical, 6)
        .tag(conversation.id)
        .contextMenu {
            Button(conversation.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                store.toggleFavorite(conversation.id)
            }
        }
    }

    private func preview(_ conversation: Conversation) -> String {
        let draft = store.draft(in: conversation.id)
        if !draft.isEmpty { return "Draft: \(draft)" }
        return store.messages(in: conversation.id).last?.text ?? conversation.subtitle
    }
}
