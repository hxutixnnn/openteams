import Foundation
import Observation
import TeamsCore

struct TeamsNotificationDestination: Equatable, Sendable {
    let accountScope: String
    let chatID: String
    let messageID: String

    init?(accountScope: String, chatID: String, messageID: String) {
        guard !accountScope.isEmpty, accountScope.utf8.count <= 256,
              accountScope.rangeOfCharacter(from: .controlCharacters) == nil,
              !chatID.isEmpty, chatID != ".", chatID != "..", chatID.utf8.count <= 1024,
              chatID.rangeOfCharacter(from: .controlCharacters) == nil,
              !messageID.isEmpty, messageID.utf8.count <= 32,
              messageID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        self.accountScope = accountScope; self.chatID = chatID; self.messageID = messageID
    }
}

@MainActor @Observable final class TeamsNotificationRouter {
    private(set) var pending: TeamsNotificationDestination?
    private(set) var ownerWindowID: UUID?
    private(set) var error: String?
    private var handled: Set<String> = []
    private var searchToken: UUID?
    private var pagesRemaining = 0
    func clearError() { error = nil }
    @discardableResult func receive(_ destination: TeamsNotificationDestination, requestID: String, ownerWindowID: UUID? = nil) -> Bool {
        guard !handled.contains(requestID) else { return false }
        if handled.count >= 200 { handled.removeAll() }
        handled.insert(requestID); pending = destination; self.ownerWindowID = ownerWindowID; error = nil; searchToken = nil; pagesRemaining = 20
        return true
    }
    func assignOwner(_ id: UUID?) { guard pending != nil else { return }; ownerWindowID = id }
    func beginPageSearch() -> UUID? {
        guard pending != nil, searchToken == nil else { return nil }
        guard pagesRemaining > 0 else { failPending("The conversation could not be found in the loaded chats."); return nil }
        pagesRemaining -= 1; let token = UUID(); searchToken = token; return token
    }
    func endPageSearch(_ token: UUID, deferred: Bool = false) -> Bool {
        guard searchToken == token else { return false }
        searchToken = nil
        if deferred { pagesRemaining += 1 }
        return true
    }
    func loadNextPage(store: TeamsReaderStore, destination: TeamsNotificationDestination) async -> TeamsChatPageLoadResult? {
        guard let token = beginPageSearch() else { return nil }
        let result = await store.loadMoreChats()
        guard endPageSearch(token, deferred: result == .deferred), pending == destination,
              store.accountScope == destination.accountScope else { return nil }
        return result
    }
    func failPending(_ message: String) { pending = nil; ownerWindowID = nil; searchToken = nil; error = message }
    func takeIfAvailable(accountScope: String, connected: Bool, containsChat: Bool, loading: Bool, hasMore: Bool) -> TeamsNotificationDestination? {
        guard let pending, !accountScope.isEmpty else { return nil }
        guard connected else { return nil }
        guard pending.accountScope == accountScope else { self.pending = nil; ownerWindowID = nil; error = "This notification belongs to another account."; return nil }
        guard !loading else { return nil }
        if containsChat { self.pending = nil; ownerWindowID = nil; error = nil; return pending }
        if !hasMore { self.pending = nil; ownerWindowID = nil; error = "This conversation is no longer available." }
        return nil
    }
}
