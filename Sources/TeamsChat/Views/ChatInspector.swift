import SwiftUI
import TeamsCore

enum InspectorTab: String, CaseIterable { case people = "Details", search = "Search", shared = "Shared" }

struct ChatInspector: View {
    var store: FixtureChatStore
    let conversation: Conversation
    @Binding var tab: InspectorTab
    @Binding var query: String
    @Binding var jumpToMessage: String?
    var searchFocus = ConversationSearchFocus()

    private var results: [ChatMessage] {
        store.messages(in: conversation.id).filter { MessageSearch.matches($0, query: query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach([InspectorTab.people, .search], id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(16)
            if tab == .people { people } else { search }
        }
    }

    private var people: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("In this chat").font(.title3.weight(.semibold))
                    Text(conversation.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("PEOPLE · \(conversation.memberIDs.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(conversation.memberIDs, id: \.self) { id in
                        let person = store.person(id)
                        HStack(spacing: 10) {
                            PersonAvatar(person: person, size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(person.name).font(.callout.weight(.medium))
                                Text(person.role).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("SHARED FILES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let files = store.messages(in: conversation.id).compactMap(\.attachment)
                    if files.isEmpty {
                        Text("No shared files in this sample conversation.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(files) { AttachmentCard(attachment: $0) }
                }
                Button(conversation.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                       systemImage: conversation.isFavorite ? "star.slash" : "star") {
                    store.toggleFavorite(conversation.id)
                }
                .buttonStyle(.borderless)
            }
            .modifier(TeamsSectionPanel())
            .padding(12)
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConversationSearchField(text: $query, focus: searchFocus, accessibilityName: "Search this conversation")
                .padding(6)
                .modifier(TeamsControlSurface())
                .frame(height: 32)
            Text("Searches demo messages on this Mac.").font(.caption).foregroundStyle(.secondary)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Find a message", systemImage: "text.magnifyingglass",
                                       description: Text("Search words, filenames, or code."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Text("\(results.count) results").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(results) { message in
                            Button {
                                jumpToMessage = nil
                                Task { @MainActor in jumpToMessage = message.id }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(store.person(message.authorID).name).font(.callout.weight(.semibold))
                                    Text(message.text).font(.callout).lineLimit(4).foregroundStyle(.secondary)
                                    Text(message.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: TeamsSurface.cardRadius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
    }
}
