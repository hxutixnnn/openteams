import Foundation
import TeamsCore

@main struct ChatPreviewCaching {
    private static func reference(_ chat: TeamsWebChat, accountID: String) -> String? {
        guard let message = chat.lastMessage, let content = message.content, !content.isEmpty else { return nil }
        let type = (message.messageType ?? message.contentType ?? "").lowercased()
        guard type == "text" || type == "richtext" || type == "richtext/html" else { return nil }
        let body = TeamsBodyParser.parse(content, messageType: type == "text" ? "Text" : "RichText/Html")
        let text = body.blocks.map(\.text).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let sender = (message.senderID ?? "").lowercased()
        let account = accountID.lowercased()
        if !account.isEmpty && (sender == account || sender == "8:orgid:" + account || sender.hasSuffix("/8:orgid:" + account)) {
            return "You: " + text
        }
        if chat.isOneOnOne != true, let name = message.imDisplayName?.split(whereSeparator: { $0.isWhitespace }).first {
            return "\(name): " + text
        }
        return text
    }

    private static func chats() -> [TeamsWebChat] {
        let contents = [
            "<p>Hello <b>world</b> &amp; friends</p><p>Next\n line</p>",
            "<p>Hello <b>world</b> &amp; friends</p><p>Next\n line</p> ",
            "Plain <b>text</b> &amp; tags",
            "   ",
            "<p></p>",
            "<p>Xin chào 👋 <a href=\"https://example.com\">link</a></p><ol><li>one</li><li><em>two</em></li></ol>",
            "<blockquote>quoted</blockquote><p>reply</p>",
            "<div><img src=\"https://example.com/a.png\"></div>"
        ]
        let types: [String?] = ["RichText/Html", "Text", "richtext", "TEXT", "Event/Call", nil]
        let senders = ["8:orgid:ada", "8:orgid:ADA", "https://x/v1/users/ME/contacts/8:orgid:ada", "8:orgid:bob", ""]
        var result: [TeamsWebChat] = []
        for (contentIndex, content) in contents.enumerated() {
            for (typeIndex, type) in types.enumerated() {
                for (senderIndex, sender) in senders.enumerated() {
                    for oneOnOne in [true, false, nil] as [Bool?] {
                        let id = "\(contentIndex)-\(typeIndex)-\(senderIndex)-\(String(describing: oneOnOne))"
                        let message = TeamsWebMessage(id: id, content: content, messageType: type, imDisplayName: senderIndex % 2 == 0 ? "Ada Lovelace" : nil, from: .string(sender))
                        result.append(TeamsWebChat(id: id, isOneOnOne: oneOnOne, lastMessage: message))
                    }
                }
            }
        }
        for index in 0..<3_000 {
            let message = TeamsWebMessage(id: "u\(index)", content: "<p>Update <b>\(index)</b> &amp; notes \(index % 7)</p>", messageType: index % 5 == 0 ? "Text" : "RichText/Html", imDisplayName: "Bob Ray", from: .string("8:orgid:bob"))
            result.append(TeamsWebChat(id: "u\(index)", isOneOnOne: index % 2 == 0, lastMessage: message))
        }
        result.append(TeamsWebChat(id: "missing"))
        return result
    }

    private static func check(_ chats: [TeamsWebChat], expected: [String: [String?]], accounts: [String]) {
        for chat in chats {
            let values = expected[chat.id]!
            for (account, value) in zip(accounts, values) {
                precondition(TeamsChatListPresentation.preview(for: chat, accountID: account) == value, "Preview mismatch for \(chat.id) as \(account)")
            }
        }
    }

    private static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    static func main() async {
        let chats = chats()
        let accounts = ["ada", "ADA", "bob", ""]
        let expected = Dictionary(uniqueKeysWithValues: chats.map { chat in (chat.id, accounts.map { reference(chat, accountID: $0) }) })
        for _ in 0..<3 { check(chats, expected: expected, accounts: accounts) }
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    let slice = chats.indices.filter { $0 % 8 == worker }.map { chats[$0] }
                    check(slice.reversed(), expected: expected, accounts: accounts)
                }
            }
        }
        let visible = Array(chats.suffix(1_000))
        var start = ContinuousClock.now
        for chat in visible { _ = reference(chat, accountID: "ada") }
        let parsed = milliseconds(start)
        for chat in visible { _ = TeamsChatListPresentation.preview(for: chat, accountID: "ada") }
        start = ContinuousClock.now
        for chat in visible { _ = TeamsChatListPresentation.preview(for: chat, accountID: "ada") }
        let repeated = milliseconds(start)
        print("ChatPreviewCaching passed: \(chats.count) chats x \(accounts.count) accounts match the parser, 1000 rows rerender \(String(format: "%.2f", parsed)) -> \(String(format: "%.2f", repeated)) ms")
    }
}
