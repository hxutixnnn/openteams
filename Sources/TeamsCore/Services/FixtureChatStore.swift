import Foundation
import Observation

@MainActor @Observable
public final class FixtureChatStore {
    public private(set) var conversations: [Conversation]
    public private(set) var messages: [ChatMessage]
    public private(set) var drafts: [String: String]
    public private(set) var persistenceError: String?
    private let draftURL: URL?
    public var persistsDrafts: Bool { draftURL != nil }

    public init(draftURL: URL? = nil, now: Date = Date()) {
        conversations = ChatFixtures.conversations
        messages = ChatFixtures.messages(now: now)
        self.draftURL = draftURL
        drafts = [:]
        if let draftURL, FileManager.default.fileExists(atPath: draftURL.path) {
            do {
                drafts = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: draftURL))
            } catch {
                persistenceError = "Saved demo drafts could not be read."
            }
        }
    }

    public func conversation(_ id: String?) -> Conversation? {
        conversations.first { $0.id == id }
    }

    public func messages(in conversationID: String) -> [ChatMessage] {
        messages.filter { $0.conversationID == conversationID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func person(_ id: String) -> Person {
        ChatFixtures.people.first { $0.id == id } ?? Person(id: id, name: "Unknown person")
    }

    public func draft(in conversationID: String) -> String { drafts[conversationID] ?? "" }

    public func setDraft(_ text: String, in conversationID: String) {
        if text.isEmpty { drafts.removeValue(forKey: conversationID) }
        else { drafts[conversationID] = text }
        persistDrafts()
    }

    @discardableResult
    public func sendDraft(in conversationID: String) -> ChatMessage? {
        let text = draft(in: conversationID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, conversation(conversationID) != nil else { return nil }
        let message = ChatMessage(conversationID: conversationID, authorID: ChatFixtures.me, text: text)
        messages.append(message)
        setDraft("", in: conversationID)
        return message
    }

    public func markRead(_ conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].unreadCount = 0
    }

    public func toggleFavorite(_ conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].isFavorite.toggle()
    }

    public func toggleReaction(_ emoji: String, messageID: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        if let reaction = messages[index].reactions.firstIndex(where: { $0.emoji == emoji }) {
            let wasMine = messages[index].reactions[reaction].includesMe
            messages[index].reactions[reaction].count += wasMine ? -1 : 1
            messages[index].reactions[reaction].includesMe.toggle()
            if messages[index].reactions[reaction].count == 0 {
                messages[index].reactions.remove(at: reaction)
            }
        } else {
            messages[index].reactions.append(MessageReaction(emoji, count: 1, includesMe: true))
        }
    }

    private func persistDrafts() {
        guard let draftURL else { return }
        do {
            try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(drafts).write(to: draftURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "This draft is available until you quit. It could not be saved on this Mac."
        }
    }
}
