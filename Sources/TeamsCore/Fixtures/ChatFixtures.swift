import Foundation

public enum ChatFixtures {
    public static let me = "you"
    public static let people: [Person] = [
        Person(id: me, name: "Alex Morgan", role: "You · Product engineering"),
        Person(id: "maya", name: "Maya Chen", role: "Product designer"),
        Person(id: "leo", name: "Leo Martin", role: "Mac engineer"),
        Person(id: "nina", name: "Nina Patel", role: "Product manager"),
        Person(id: "sam", name: "Sam Rivera", role: "Platform engineer"),
        Person(id: "linh", name: "Linh Nguyen", role: "Design engineer")
    ]

    public static let conversations: [Conversation] = [
        Conversation(id: "design", title: "Product Design", subtitle: "A little space for the details.",
                     memberIDs: [me, "maya", "leo", "nina"], symbol: "square.stack.3d.up.fill",
                     colorIndex: 0, isFavorite: true, unreadCount: 2),
        Conversation(id: "maya", title: "Maya Chen", subtitle: "Product designer",
                     memberIDs: [me, "maya"], symbol: "person.fill", colorIndex: 1, isFavorite: true),
        Conversation(id: "platform", title: "Platform", subtitle: "Making the foundation feel effortless.",
                     memberIDs: [me, "sam", "leo"], symbol: "terminal.fill", colorIndex: 2, isFavorite: true),
        Conversation(id: "launch", title: "Launch room", subtitle: "The next release, together.",
                     memberIDs: [me, "nina", "sam", "maya"], symbol: "paperplane.fill", colorIndex: 3, unreadCount: 3),
        Conversation(id: "linh", title: "Linh Nguyen", subtitle: "Design engineer",
                     memberIDs: [me, "linh"], symbol: "person.fill", colorIndex: 4),
        Conversation(id: "weekend", title: "Off the clock", subtitle: "Everything between the work.",
                     memberIDs: [me, "maya", "sam"], symbol: "cup.and.saucer.fill", colorIndex: 5),
        Conversation(id: "notes", title: "Notes to self", subtitle: "A quiet place to think.",
                     memberIDs: [me], symbol: "note.text", colorIndex: 6)
    ]

    public static func messages(now: Date = Date()) -> [ChatMessage] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        func time(_ hours: Double) -> Date { start.addingTimeInterval(hours * 3600) }
        return [
            ChatMessage(id: "d1", conversationID: "design", authorID: "nina",
                        text: "A small goal for this week: make the everyday conversations feel lighter.",
                        createdAt: time(-7)),
            ChatMessage(id: "d2", conversationID: "design", authorID: "maya",
                        text: "Morning! I’ve pulled the chat details into a single inspector. People and shared files are one click away, while the conversation stays in view.",
                        createdAt: time(9.1), reactions: [MessageReaction("🙌", count: 3)]),
            ChatMessage(id: "d3", conversationID: "design", authorID: me,
                        text: "That feels right. Let’s keep the timeline calm and let the details come to us.",
                        createdAt: time(9.15)),
            ChatMessage(id: "d4", conversationID: "design", authorID: "maya",
                        text: "Here’s the latest pass. The notes cover keyboard navigation, compact spacing, and the empty states.",
                        createdAt: time(9.2),
                        attachment: ChatAttachment(id: "brief", name: "Chat experience.pdf",
                                                   detail: "Design notes · 1.8 MB", symbol: "doc.richtext")),
            ChatMessage(id: "d5", conversationID: "design", authorID: "leo",
                        text: "The native composer now keeps undo and text selection intact. I’m checking Vietnamese input and switching between drafts next.",
                        createdAt: time(9.35), reactions: [MessageReaction("👍", count: 2, includesMe: true)]),
            ChatMessage(id: "d6", conversationID: "design", authorID: me,
                        text: "Perfect. Also keep the reading position steady when older messages arrive.",
                        createdAt: time(9.4), quote: QuotedMessage(author: "Leo Martin",
                                                                 text: "The native composer now keeps undo and text selection intact.")),
            ChatMessage(id: "d7", conversationID: "design", authorID: "maya",
                        text: "Yes to all of that. A tool that gets out of the way, but never loses your place.",
                        createdAt: time(9.45), reactions: [MessageReaction("💜", count: 2)])
        ] + [
            ChatMessage(id: "m1", conversationID: "maya", authorID: "maya",
                        text: "I left a few notes on the inspector. The people list should stay simple.", createdAt: time(8.8)),
            ChatMessage(id: "m2", conversationID: "maya", authorID: me,
                        text: "Thanks! I’ll take a look after the morning review.", createdAt: time(8.9)),
            ChatMessage(id: "p1", conversationID: "platform", authorID: "sam",
                        text: "The service boundary is in place. UI models don’t need to know where messages come from.",
                        createdAt: time(8.4), code: "protocol ChatRepository {\n    func messages(in chat: ChatID) async throws -> [Message]\n}"),
            ChatMessage(id: "p2", conversationID: "platform", authorID: "leo",
                        text: "Good call. Fixtures today, verified Graph responses when the tenant app is ready.", createdAt: time(8.5)),
            ChatMessage(id: "l1", conversationID: "launch", authorID: "nina",
                        text: "Our first milestone is a working native shell and a clear Graph access checklist.", createdAt: time(8.1)),
            ChatMessage(id: "l2", conversationID: "launch", authorID: "sam",
                        text: "I’ll keep the API capability notes alongside the build instructions.", createdAt: time(8.2)),
            ChatMessage(id: "l3", conversationID: "launch", authorID: "maya",
                        text: "Let’s review the whole flow once it’s running on a Mac.", createdAt: time(8.3)),
            ChatMessage(id: "ln1", conversationID: "linh", authorID: "linh",
                        text: "Chào buổi sáng! Mình thử nhập tiếng Việt trong khung chat nhé.", createdAt: time(7.9)),
            ChatMessage(id: "w1", conversationID: "weekend", authorID: "sam",
                        text: "Coffee walk after the demo? ☕", createdAt: time(-8)),
            ChatMessage(id: "w2", conversationID: "weekend", authorID: "maya",
                        text: "Absolutely. I know a good spot around the corner.", createdAt: time(-7.9)),
            ChatMessage(id: "n1", conversationID: "notes", authorID: me,
                        text: "Keep the important things close: a conversation, a draft, and a little room to focus.", createdAt: time(-9))
        ]
    }
}
