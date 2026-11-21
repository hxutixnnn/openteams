import SwiftUI
import TeamsCore

struct TeamsGlobalMessageResults: View {
    let store: TeamsReaderStore
    let query: String
    let accountRevision: UUID
    let submission: UUID?
    let open: (String, String, UUID) async throws -> Void
    @ViewState<PageRequest?> private var request = nil
    @ViewState<[TeamsMessageSearchResult]> private var results = []
    @ViewState<Int?> private var page = nil
    @ViewState<Bool> private var hasMore = false
    @ViewState<Target?> private var target = nil
    @ViewState<String?> private var searchError = nil
    @ViewState<String?> private var openError = nil

    private var canSubmit: Bool {
        request == nil && target == nil && !store.searchCoolingDown && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section("Teams Messages") {
            Button(request == nil ? "Search Teams Messages" : "Searching…") { submit(page: 0) }
                .disabled(!canSubmit)
            if store.searchCoolingDown { Text("Teams is limiting searches. Try again shortly.").foregroundStyle(.secondary) }
            if let searchError { Text(searchError).foregroundStyle(.secondary) }
            if let openError { Text(openError).foregroundStyle(.secondary) }
            if page != nil && results.isEmpty { Text("No matching messages").foregroundStyle(.secondary) }
            ForEach(results) { result in
                if let chatID = result.chatID, !chatID.isEmpty, chatID != ".", chatID != "..", chatID.utf8.count <= 1024,
                   chatID.rangeOfCharacter(from: .controlCharacters) == nil,
                   let messageID = result.messageID, !messageID.isEmpty, messageID.utf8.count <= 32,
                   messageID.utf8.allSatisfy({ (48...57).contains($0) }) {
                    Button {
                        openError = nil
                        target = .init(chatID: chatID, messageID: messageID)
                    } label: {
                        resultLabel(result)
                    }
                    .buttonStyle(.plain)
                    .disabled(target != nil || request != nil)
                } else {
                    VStack(alignment: .leading) {
                        resultLabel(result)
                        Text("Message location unavailable").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if hasMore, let page { Button("Load more messages") { submit(page: page + 1) }.disabled(!canSubmit) }
        }
        .onChange(of: submission) { _, value in if value != nil { submit(page: 0) } }
        .task(id: request) {
            if let request { await search(request) }
        }
        .task(id: target) {
            if let target { await openResult(target) }
        }
    }

    private func submit(page: Int) {
        guard canSubmit else { return }
        searchError = nil
        openError = nil
        request = .init(page: page)
    }

    private func search(_ request: PageRequest) async {
        defer { if self.request == request { self.request = nil } }
        guard store.accountRevision == accountRevision else { return }
        do {
            let response = try await store.searchServer(query, page: request.page)
            guard !Task.isCancelled, store.accountRevision == accountRevision, self.request == request else { return }
            var seen = Set<String>()
            results = ((request.page == 0 ? [] : results) + response.results).filter { seen.insert($0.id).inserted }
            page = request.page
            hasMore = response.hasMore
        } catch {
            if !Task.isCancelled, !(error is CancellationError), store.accountRevision == accountRevision {
                searchError = error.localizedDescription
            }
        }
    }

    private func openResult(_ target: Target) async {
        defer { if self.target == target { self.target = nil } }
        do {
            try await open(target.chatID, target.messageID, accountRevision)
        } catch {
            if !Task.isCancelled, !(error is CancellationError), store.accountRevision == accountRevision {
                openError = error.localizedDescription
            }
        }
    }

    private func resultLabel(_ result: TeamsMessageSearchResult) -> some View {
        let chat = result.chatID.flatMap { store.conversation($0) }
        return VStack(alignment: .leading, spacing: 3) {
            Text(chat.map { store.conversationTitle($0) } ?? result.conversationTitle ?? "Teams conversation").font(.caption.weight(.semibold))
            if let sender = result.senderName { Text(sender).font(.caption2).foregroundStyle(.secondary) }
            Text(result.preview).font(.caption).lineLimit(3)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct PageRequest: Equatable {
        let page: Int
        let id = UUID()
    }

    private struct Target: Equatable {
        let chatID: String
        let messageID: String
        let id = UUID()
    }
}
