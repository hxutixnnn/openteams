import Foundation
import Testing
@testable import TeamsCore

@MainActor
struct FixtureChatStoreTests {
    @Test func draftsAreIsolatedAndSurviveReload() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "drafts.json")
        let store = FixtureChatStore(draftURL: url)
        store.setDraft("Chào bạn 👋", in: "design")
        store.setDraft("A different thought", in: "maya")
        let restored = FixtureChatStore(draftURL: url)
        #expect(restored.draft(in: "design") == "Chào bạn 👋")
        #expect(restored.draft(in: "maya") == "A different thought")
        #expect(restored.draft(in: "notes") == "")
        #expect(restored.persistenceError == nil)
    }

    @Test func sendConsumesOnlySelectedDraftAndPreventsRepeat() {
        let store = FixtureChatStore()
        let count = store.messages(in: "design").count
        store.setDraft("Hello, demo.", in: "design")
        store.setDraft("Keep this", in: "maya")
        let sent = store.sendDraft(in: "design")
        #expect(sent?.text == "Hello, demo.")
        #expect(sent?.authorID == ChatFixtures.me)
        #expect(store.messages(in: "design").count == count + 1)
        #expect(store.draft(in: "design") == "")
        #expect(store.draft(in: "maya") == "Keep this")
        #expect(store.sendDraft(in: "design") == nil)
    }

    @Test func whitespaceDraftAndUnknownConversationDoNotSend() {
        let store = FixtureChatStore()
        store.setDraft(" \n\t", in: "design")
        store.setDraft("Message", in: "unknown")
        #expect(store.sendDraft(in: "design") == nil)
        #expect(store.sendDraft(in: "unknown") == nil)
    }

    @Test func reactionTogglePreservesOtherPeopleCounts() throws {
        let store = FixtureChatStore()
        store.toggleReaction("🙌", messageID: "d2")
        var reaction = try #require(store.messages.first { $0.id == "d2" }?.reactions.first)
        #expect(reaction.count == 4)
        #expect(reaction.includesMe)
        store.toggleReaction("🙌", messageID: "d2")
        reaction = try #require(store.messages.first { $0.id == "d2" }?.reactions.first)
        #expect(reaction.count == 3)
        #expect(!reaction.includesMe)
        store.toggleReaction("😊", messageID: "d2")
        store.toggleReaction("😊", messageID: "d2")
        #expect(!store.messages.first { $0.id == "d2" }!.reactions.contains { $0.emoji == "😊" })
    }

    @Test func searchIncludesQuotedTextFilesAndVietnamese() {
        let message = ChatMessage(conversationID: "demo", authorID: "me", text: "Chào buổi sáng",
                                  quote: QuotedMessage(author: "Person", text: "Architecture review"),
                                  attachment: ChatAttachment(id: "file", name: "Design.pdf", detail: "sample"))
        #expect(MessageSearch.matches(message, query: "chao buoi sang"))
        #expect(MessageSearch.matches(message, query: "ARCHITECTURE"))
        #expect(MessageSearch.matches(message, query: "design.pdf"))
        #expect(!MessageSearch.matches(message, query: "missing"))
    }
}
