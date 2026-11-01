import SwiftUI
import TeamsCore

struct TeamsReadSidebar: View {
    var store: TeamsReaderStore
    @Binding var selection: String?
    @Binding var filter: String
    let connect: () -> Void
    let newChat: () -> Void
    @ViewState<Bool> private var unreadOnly = false
    @ViewState<Bool> private var draftsOnly = false
    @ViewState<[String: Bool]> private var expandedFolders = [:]

    private var folders: [TeamsConversationFolder] { store.conversationFolders?.orderedChatFolders ?? [] }
    private func itemIDs(_ folder: TeamsConversationFolder) -> [String] {
        folder.chatIDs
    }
    private func matches(_ chat: TeamsWebChat, includeSectionMember: Bool = false) -> Bool {
        (includeSectionMember || chat.hidden != true) && chat.isConversationDeleted != true && (!unreadOnly || chat.isRead == false) &&
        (!draftsOnly || !(store.composer.drafts[chat.id] ?? "").isEmpty || store.composer.replies[chat.id] != nil) &&
        (filter.isEmpty || store.conversationTitle(chat).localizedCaseInsensitiveContains(filter))
    }

    private var chats: [TeamsWebChat] {
        store.chats.filter {
            $0.id != "48:notes" && matches($0)
        }
    }
    private var hasFolderResults: Bool { folders.contains { !folderChats($0).isEmpty } }

    private func folderChats(_ folder: TeamsConversationFolder) -> [TeamsWebChat] {
        let ids = itemIDs(folder)
        var result = ids.compactMap { store.conversation($0) }.filter { matches($0, includeSectionMember: true) }
        if folder.sortType == "NameAlphabetical" {
            result.sort { store.conversationTitle($0).localizedStandardCompare(store.conversationTitle($1)) == .orderedAscending }
        } else if folder.sortType == "MostRecent" || folder.sortType == "UnreadThenMostRecent" || folder.sortType == "UnreadOnly" {
            let ranks = Dictionary(store.chats.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            if folder.sortType == "UnreadOnly" { result = result.filter { $0.isRead == false } }
            result.sort { a, b in
                if folder.sortType == "UnreadThenMostRecent", (a.isRead == false) != (b.isRead == false) { return a.isRead == false }
                return (ranks[a.id] ?? Int.max) < (ranks[b.id] ?? Int.max)
            }
        }
        return result
    }

    var body: some View {
        List(selection: $selection) {
            if let selfChat = store.selfChat, !folders.contains(where: { itemIDs($0).contains(selfChat.id) }), matches(selfChat) {
                Section("Personal") { row(selfChat) }
            }
            ForEach(folders) { folder in
                let folderItems = folderChats(folder)
                let unresolved = itemIDs(folder).filter { store.conversation($0) == nil }.count
                if !folderItems.isEmpty || (filter.isEmpty && !unreadOnly && !draftsOnly) {
                    Section(isExpanded: Binding(get: { expandedFolders[folder.id] ?? folder.isExpanded ?? true },
                                                set: { expandedFolders[folder.id] = $0 })) {
                        ForEach(folderItems) { row($0) }
                        if folder.conversationFolderItems.isEmpty { Text("No conversations").font(.caption).foregroundStyle(.secondary) }
                        if unresolved > 0 && filter.isEmpty && !unreadOnly && !draftsOnly {
                            if store.hasMoreChats { Button("Load more chats (\(unresolved) not loaded)") { Task { await store.loadMoreChats() } }.disabled(store.isLoadingChats) }
                            else { Text("\(unresolved) conversations not available").font(.caption).foregroundStyle(.secondary) }
                        }
                    } header: {
                        HStack(spacing: 5) {
                            if let emoji = folder.emojiMetadataId {
                                let symbol = TeamsReactionPresentation.symbol(for: emoji)
                                if symbol != "✦" { Text(symbol).accessibilityHidden(true) }
                            }
                            Text(folder.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? String((folder.name ?? "").prefix(100)) : (folder.folderType == "Favorites" ? "Favorites" : "Section"))
                        }
                    }
                }
            }
            Section("Recent") {
                let assigned = Set(folders.flatMap { itemIDs($0) })
                ForEach(chats.filter { !assigned.contains($0.id) }) { chat in row(chat) }
            }
            if store.hasMoreChats && filter.isEmpty {
                Button {
                    Task { await store.loadMoreChats() }
                } label: {
                    HStack {
                        Text("Load More Chats")
                        Spacer()
                        if store.isLoadingChats { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(store.isLoadingChats || !store.connected)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(TeamsSurface.window)
        .overlay {
            if !filter.isEmpty && chats.isEmpty && !hasFolderResults && !(store.selfChat.map { matches($0) } ?? false) {
                ContentUnavailableView.search(text: filter)
            } else if unreadOnly && filter.isEmpty && chats.isEmpty && !hasFolderResults && store.selfChat?.isRead != false {
                ContentUnavailableView("No unread chats", systemImage: "checkmark.bubble", description: Text("You're all caught up."))
            } else if draftsOnly && filter.isEmpty && chats.isEmpty && !hasFolderResults && !(store.selfChat.map { matches($0) } ?? false) {
                ContentUnavailableView("No local drafts", systemImage: "doc.text", description: Text("Drafts saved on this Mac appear here."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Text("Chat").font(.headline)
                    Spacer()
                    Button(action: newChat) { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(!store.canFindPeople)
                        .help("New chat").accessibilityLabel("New Chat")
                }
                .padding(.horizontal, 16).padding(.top, 10)
                searchField
                HStack {
                    Toggle("Unread", isOn: $unreadOnly)
                        .toggleStyle(TeamsPillToggleStyle())
                    Toggle("Drafts", isOn: $draftsOnly)
                        .toggleStyle(TeamsPillToggleStyle()).help("Drafts saved on this Mac")
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.bottom, 4)
                if let error = store.chatListError, !store.chats.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 6)
                }
                if let warning = store.foldersWarning {
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                }
            }
        }
        .onChange(of: store.accountScope) { _, _ in expandedFolders = [:]; draftsOnly = false }
        .safeAreaInset(edge: .bottom, spacing: 0) { accountFooter }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("", text: $filter, prompt: Text("Find a conversation"))
                .textFieldStyle(.plain).labelsHidden()
                .accessibilityLabel("Find a Teams conversation")
                .onExitCommand { filter = "" }
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear conversation search")
            }
        }
        .padding(8)
        .modifier(TeamsControlSurface())
        .padding(.horizontal, 12).padding(.bottom, 2)
    }

    private var accountFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PersonAvatar(person: Person(id: store.accountID, name: store.accountName.isEmpty ? "Teams" : store.accountName), size: 30, revision: store.mediaRevision, refreshRevision: store.mediaRefreshRevision, loadPhoto: { try await store.profilePhoto(for: $0) })
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.accountName.isEmpty ? "Teams account" : store.accountName)
                        .font(.callout.weight(.medium)).lineLimit(1)
                    Text(store.connected && !store.sessionExpired ? "Connected" :
                         (store.chats.isEmpty ? "Not connected" : "Saved on this Mac"))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            if !store.connected || store.sessionExpired {
                Button(store.sessionExpired ? "Reconnect to Teams" : "Connect to Teams", action: connect)
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
    }

    private func row(_ chat: TeamsWebChat) -> some View {
        let other = chat.members?.first { member in
            let id = member.objectId ?? member.mri?.replacingOccurrences(of: "8:orgid:", with: "") ?? ""
            return member.kind == .person && !id.isEmpty && id.lowercased() != store.accountID.lowercased()
        }
        let avatarID = chat.id == "48:notes" ? store.accountID : (chat.isOneOnOne == true ? (other?.mri ?? other?.objectId ?? chat.id) : chat.id + "-\(chat.members?.hashValue ?? 0)-\(chat.picture?.hashValue ?? 0)-\(chat.threadVersion?.hashValue ?? 0)")
        return HStack(spacing: 8) {
            PersonAvatar(person: Person(id: avatarID, name: store.conversationTitle(chat)), size: 24, revision: store.mediaRevision, refreshRevision: store.mediaRefreshRevision, loadPhoto: { id in
                if chat.id != "48:notes", chat.isOneOnOne != true { return try await store.groupPhoto(for: chat.members ?? [], chatID: chat.id, picture: chat.picture, pictureVersion: chat.threadVersion) }
                return try await store.profilePhoto(for: id)
            })
            VStack(alignment: .leading, spacing: 2) {
                Text(store.conversationTitle(chat))
                    .font(.callout.weight(chat.isRead == false ? .semibold : .regular)).lineLimit(1)
                if let status = store.readStatusMessages[chat.id] ?? store.chatErrors[chat.id] ?? (store.pendingReadChatIDs.contains(chat.id) ? "Read update awaiting confirmation" : nil) {
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if chat.isRead == false {
                Circle().fill(ChatTheme.accent).frame(width: 6, height: 6)
                    .accessibilityLabel("Unread in Teams")
            }
        }
        .padding(.vertical, 1)
        .tag(chat.id)
        .contextMenu {
            Button("Check Read Status") { Task { await store.checkReadStatus(chat.id) } }
                .disabled(!store.connected)
            if store.finishableReadChatIDs.contains(chat.id) {
                Button("Finish Mark as Read") { Task { await store.finishMarkConversationRead(chat.id) } }
                    .disabled(!store.connected)
            }
            if chat.isRead == false {
                Button("Mark as Read") { Task { await store.markConversationRead(chat.id) } }
                    .disabled(!store.connected)
            }
        }
    }

}
