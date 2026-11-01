import Testing
@testable import TeamsCore

struct TeamsNotificationTrackerTests {
    private func chat(_ id: String, message: String, sender: String, unread: Bool = true) -> TeamsWebChat {
        .init(id: id, isRead: !unread, lastMessage: .init(id: message, from: .string(sender)))
    }
    @Test func seedsWithoutAlertsAndNotifiesOnlyNewUnreadOtherPeople() {
        var tracker = TeamsNotificationTracker()
        let other = "8:orgid:other", me = "8:orgid:me"
        #expect(tracker.update(chats: [chat("a", message: "100", sender: other)], accountID: "me", accountScope: "tenant:me").isEmpty)
        let updates = tracker.update(chats: [chat("a", message: "101", sender: other), chat("b", message: "102", sender: me), chat("c", message: "103", sender: other, unread: false)], accountID: "me", accountScope: "tenant:me")
        #expect(updates.map(\.id) == ["a"])
        #expect(tracker.update(chats: [chat("a", message: "99", sender: other)], accountID: "me", accountScope: "tenant:me").isEmpty)
        #expect(tracker.update(chats: [chat("a", message: "101", sender: other)], accountID: "me", accountScope: "tenant:me").isEmpty)
        #expect(tracker.update(chats: [chat("a", message: "200", sender: other)], accountID: "me", accountScope: "other:me").isEmpty)
    }
}
