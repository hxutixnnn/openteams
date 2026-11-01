import SwiftUI
import TeamsCore

struct TeamsReadInspector: View {
    @Environment(\.displayScale) private var displayScale
    var store: TeamsReaderStore
    let chat: TeamsWebChat
    let accountScope: String
    let accountRevision: UUID
    var isCurrent: () -> Bool = { true }
    var connect: () -> Void = {}
    @Binding var tab: InspectorTab
    @Binding var query: String
    @Binding var jumpToMessage: TeamsMessageDestination?
    var searchFocus = ConversationSearchFocus()
    @ViewState<[TeamsMessageSearchResult]> private var serverResults = []
    @ViewState<String?> private var serverError = nil
    @ViewState<Bool> private var searching = false
    @ViewState<Bool> private var searchedServer = false
    @ViewState<Bool> private var hasMoreServer = false
    @ViewState<Int> private var serverPage = 0
    @ViewState<Int?> private var serverTotal = nil
    @ViewState<UUID> private var searchRevision = UUID()
    @ViewState<[TeamsInstalledAgent]?> private var installedAgents = nil
    @ViewState<Bool> private var agentsLoading = false
    @ViewState<Bool> private var agentsUnavailable = false
    @ViewState<UUID> private var agentsRetry = UUID()
    @ViewState<[TeamsSharedItem]> private var sharedItems = []
    @ViewState<TeamsSharedItem.Kind?> private var sharedKind = nil
    @ViewState<String?> private var sharedError = nil
    @ViewState<Bool> private var sharedLoading = false
    @ViewState<Bool> private var sharedLoaded = false
    @ViewState<Bool> private var sharedHasMore = false
    @ViewState<Int> private var sharedOffset = 0
    @ViewState<Int> private var sharedUnsupported = 0
    @ViewState<TeamsSharedPaginationTracker> private var sharedTracker = .init()
    @ViewState<Bool> private var sharedNeedsReconnect = false
    @ViewState<String?> private var sharedBookmark = nil
    @ViewState<UUID> private var sharedRevision = UUID()
    var loadAgents: ((String) async throws -> [TeamsInstalledAgent])? = nil

    private var results: [TeamsRenderedMessage] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return store.messages(in: chat.id).filter {
            !$0.isDeleted && $0.body.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().tint(.secondary)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(TeamsSurface.border, lineWidth: 1 / max(displayScale, 1)))
            .padding(12)
            if tab == .people { details } else if tab == .search { search } else { shared }
        }
        .task(id: "\(store.accountRevision.uuidString)|\(chat.id)|\(tab == .shared)") {
            sharedRevision = UUID(); sharedItems = []; sharedError = nil; sharedLoaded = false
            sharedHasMore = false; sharedOffset = 0; sharedUnsupported = 0; sharedTracker = .init(); sharedNeedsReconnect = false; sharedBookmark = nil; sharedLoading = false
            if tab == .shared { await loadShared(more: false) }
        }
        .onChange(of: query) { _, _ in resetServerSearch() }
        .onChange(of: store.accountScope) { _, _ in resetServerSearch() }
        .onChange(of: store.connected) { _, connected in if !connected { resetServerSearch() } }
        .onChange(of: chat.id) { _, _ in resetServerSearch() }
        .task(id: "\(store.accountScope)|\(chat.id)|\(store.connected)|\(store.mediaRefreshRevision)|\(agentsRetry)") {
            installedAgents = nil; agentsUnavailable = false
            guard store.connected, chat.isOneOnOne != true else { agentsLoading = false; return }
            agentsLoading = true
            do {
                if let loadAgents { installedAgents = try await loadAgents(chat.id) }
                else { installedAgents = try await store.installedAgents(in: chat.id) }
            }
            catch is CancellationError { }
            catch { if !Task.isCancelled { agentsUnavailable = true } }
            if !Task.isCancelled { agentsLoading = false }
        }
    }

    private var shared: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Shared items", selection: $sharedKind) {
                Text("All").tag(TeamsSharedItem.Kind?.none)
                Text("Files").tag(TeamsSharedItem.Kind?.some(.file))
                Text("Links").tag(TeamsSharedItem.Kind?.some(.link))
            }.pickerStyle(.segmented)
            if let sharedError {
                Text(sharedError).font(.caption).foregroundStyle(.secondary)
                if sharedNeedsReconnect { Button("Reconnect", action: connect) }
                else { Button("Retry") { Task { await loadShared(more: sharedLoaded) } }.disabled(sharedLoading) }
            } else if sharedLoaded && sharedItems.isEmpty && sharedUnsupported == 0 && !sharedHasMore {
                Text("No shared files or links found.").font(.callout).foregroundStyle(.secondary)
            }
            if sharedUnsupported > 0 { Text("Some shared items could not be displayed.").font(.caption).foregroundStyle(.secondary) }
            if sharedLoaded, let kind = sharedKind, !sharedItems.contains(where: { $0.kind == kind }) {
                Text(kind == .file ? "No files in loaded items." : "No links in loaded items.").font(.caption).foregroundStyle(.secondary)
            }
            if sharedLoading { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(sharedItems.filter { sharedKind == nil || $0.kind == sharedKind }) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: item.kind == .file ? "doc" : "link").font(.callout.weight(.medium)).textSelection(.enabled)
                            if let sender = item.sharedBy { Text(sender).font(.caption).foregroundStyle(.secondary) }
                            if item.messageID == nil { Text("Origin message unavailable.").font(.caption).foregroundStyle(.secondary) }
                            else if item.parentMessageID != nil && item.parentMessageID != item.messageID {
                                Text("Thread context may be unavailable.").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                if let url = item.url { Link("Open", destination: url) }
                                if let id = item.messageID {
                                    Button("Show message") {
                                        guard isCurrent(), store.accountScope == accountScope, store.accountRevision == accountRevision else { return }
                                        jumpToMessage = .init(messageID: id, chatID: chat.id, accountScope: accountScope)
                                    }.buttonStyle(.link)
                                }
                            }.font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if sharedHasMore { Button("Load more") { Task { await loadShared(more: true) } }.disabled(sharedLoading) }
                }
            }
        }.padding(12)
    }

    private func loadShared(more: Bool) async {
        guard isCurrent(), !sharedLoading, tab == .shared, accountScope == store.accountScope, accountRevision == store.accountRevision else { return }
        let revision = sharedRevision, account = store.accountScope, accountRevision = store.accountRevision, chatID = chat.id
        let offset = more ? sharedOffset : 0, bookmark = more ? sharedBookmark : nil
        sharedLoading = true; sharedError = nil; sharedNeedsReconnect = false
        do {
            let page = try await store.sharedItems(in: chatID, bookmark: bookmark, offset: offset)
            guard isCurrent(), revision == sharedRevision, account == store.accountScope, accountRevision == store.accountRevision, chatID == chat.id, tab == .shared, !Task.isCancelled else { return }
            guard !page.hasMore || page.rawCount > 0 else { throw TeamsSharedError.invalidResponse }
            if !more { sharedTracker = .init() }
            let unique: [TeamsSharedItem]
            do { unique = try sharedTracker.accept(page) }
            catch { sharedHasMore = false; throw error }
            if more { sharedItems.append(contentsOf: unique) } else { sharedItems = unique }
            sharedUnsupported = (more ? sharedUnsupported : 0) + page.unsupportedCount
            sharedOffset = offset + page.rawCount; sharedBookmark = page.bookmark; sharedHasMore = page.hasMore; sharedLoaded = true
        } catch {
            guard isCurrent(), revision == sharedRevision, account == store.accountScope, accountRevision == store.accountRevision, chatID == chat.id, tab == .shared, !Task.isCancelled else { return }
            sharedError = error.localizedDescription
            if case TeamsSharedError.unavailable = error { sharedNeedsReconnect = true }
            if case TeamsSharedError.http(401, _) = error { sharedNeedsReconnect = true }
        }
        if revision == sharedRevision { sharedLoading = false }
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.conversationTitle(chat)).font(.headline)
                    Text(chat.isOneOnOne == true ? "Direct conversation" : "Group conversation")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    if let members = chat.members, !members.isEmpty {
                        memberSection("Known people", members: members.filter { $0.kind == .person })
                        if chat.isOneOnOne == true {
                            memberSection("Agents", members: members.filter { $0.kind == .agent })
                        } else if let installedAgents {
                            installedAgentSection(installedAgents)
                        } else if agentsLoading {
                            Text("Loading installed agents…").font(.caption).foregroundStyle(.secondary)
                        } else if agentsUnavailable {
                            Text("Installed agents are unavailable.").font(.caption).foregroundStyle(.secondary)
                            Button("Retry") { agentsRetry = UUID() }.controlSize(.small)
                        }
                        memberSection("Agentic users", members: members.filter { $0.kind == .agentic })
                        memberSection("Other participants", members: members.filter { $0.kind == .unknown })
                    } else {
                        Text("Participants").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Participant details are not available.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Messages on this Mac").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(store.messages(in: chat.id).count) messages available to read and search.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Some files and interactive cards may be unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius))
            .overlay(RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius).strokeBorder(TeamsSurface.border, lineWidth: 1 / max(displayScale, 1)))
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    @ViewBuilder private func installedAgentSection(_ agents: [TeamsInstalledAgent]) -> some View {
        if !agents.isEmpty {
            Text("Agents (\(agents.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in
                let person = Person(id: agent.id, name: agent.name)
                HStack(spacing: 8) {
                    PersonAvatar(person: person, size: 28)
                    Text(person.name).font(.callout.weight(.medium))
                }
            }
        }
    }

    @ViewBuilder private func memberSection(_ title: String, members: [TeamsWebMember]) -> some View {
        if !members.isEmpty {
            Text("\(title) (\(members.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(members.enumerated()), id: \.offset) { index, member in
                let rawName = member.preferredDisplayName ?? ""
                let placeholder = member.kind == .agent ? "Agent \(index + 1)" : "Participant \(index + 1)"
                let name = rawName.isEmpty || rawName.range(of: "^Bot-[0-9a-f-]+$", options: [.regularExpression, .caseInsensitive]) != nil ? placeholder : rawName
                let person = Person(id: member.mri ?? member.objectId ?? "member-\(index)", name: name)
                HStack(spacing: 8) {
                    if member.kind == .person {
                        PersonAvatar(person: person, size: 28, revision: store.mediaRevision, refreshRevision: store.mediaRefreshRevision, loadPhoto: { try await store.profilePhoto(for: $0) })
                    } else { PersonAvatar(person: person, size: 28) }
                    Text(person.name).font(.callout.weight(.medium))
                }
            }
        }
    }

    private func resetServerSearch() {
        searchRevision = UUID(); searching = false; searchedServer = false
        serverResults = []; serverError = nil; serverPage = 0; serverTotal = nil; hasMoreServer = false
    }

    private func searchServer(more: Bool = false) {
        guard store.canSearchServer, !searching else { return }
        let term = query, account = store.accountScope, chatID = chat.id, revision = searchRevision
        let page = more ? serverPage + 1 : 0
        searching = true; serverError = nil
        Task {
            do {
                let response = try await store.searchServer(term, in: chatID, page: page)
                guard revision == searchRevision, term == query, account == store.accountScope, store.connected, chatID == chat.id else { return }
                let combined = more ? serverResults + response.results : response.results
                var seen = Set<String>()
                serverResults = combined.filter { seen.insert($0.id).inserted }
                serverPage = page; serverTotal = response.total; hasMoreServer = response.hasMore; searchedServer = true
            } catch {
                guard revision == searchRevision, term == query, account == store.accountScope, store.connected, chatID == chat.id else { return }
                if !(error is CancellationError) { serverError = error.localizedDescription }
            }
            searching = false
        }
    }

    private func resultLabel(_ result: TeamsMessageSearchResult, destination: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.senderName ?? "Teams message").font(.callout.weight(.semibold))
            Text(result.preview).font(.caption).lineLimit(3)
            Text(destination).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConversationSearchField(text: $query, focus: searchFocus, accessibilityName: "Search Teams messages") { searchServer() }
                .frame(height: 24)
            if store.canSearchServer {
                Button(searching ? "Searching…" : "Search Teams") { searchServer() }.disabled(searching || store.searchCoolingDown || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let serverError { Text(serverError).font(.caption).foregroundStyle(.secondary) }
            if searchedServer {
                Text(serverTotal.map { "\($0) server results" } ?? "\(serverResults.count) server results").font(.caption.weight(.medium))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(serverResults) { result in
                            let resultScope = store.accountScope
                            if let messageID = result.messageID, !messageID.isEmpty, messageID.utf8.count <= 32,
                               messageID.utf8.allSatisfy({ (48...57).contains($0) }), result.chatID == nil || result.chatID == chat.id {
                                Button { jumpToMessage = .init(messageID: messageID, chatID: chat.id, accountScope: resultScope) } label: {
                                    resultLabel(result, destination: store.messages(in: chat.id).contains(where: { $0.id == messageID }) ? "Show in conversation" : "Show message context")
                                }.buttonStyle(.plain)
                            } else {
                                resultLabel(result, destination: "Message location unavailable")
                            }
                        }
                        if hasMoreServer { Button("Load more") { searchServer(more: true) }.disabled(searching) }
                    }
                }.frame(maxHeight: 250)
                Divider()
            }
            Text("Downloaded messages on this Mac").font(.caption).foregroundStyle(.secondary)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Find a message", systemImage: "text.magnifyingglass",
                                       description: Text("Search words in this conversation."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Text("\(results.count) results").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(results) { message in
                            let resultScope = store.accountScope
                            Button {
                                jumpToMessage = .init(messageID: message.id, chatID: chat.id, accountScope: resultScope)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.author.name).font(.callout.weight(.semibold))
                                    Text(message.body.text).font(.callout).lineLimit(4).foregroundStyle(.secondary)
                                    Text(message.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.bottom, 18)
    }
}
