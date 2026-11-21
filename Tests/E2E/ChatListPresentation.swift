import Foundation
import TeamsCore

@main struct ChatListPresentation {
    static func main() {
        let rich = TeamsWebMessage(id: "rich", content: "<p>Hello <b>world</b> &amp; friends</p><p>Next\n line</p>", messageType: "RichText/Html", imDisplayName: "Ada Lovelace", from: .string("8:orgid:ADA"))
        let direct = TeamsWebChat(id: "direct", isOneOnOne: true, lastMessage: rich)
        let group = TeamsWebChat(id: "group", isOneOnOne: false, lastMessage: rich)
        precondition(TeamsChatListPresentation.preview(for: direct, accountID: "other") == "Hello world & friends Next line")
        precondition(TeamsChatListPresentation.preview(for: direct, accountID: "ada") == "You: Hello world & friends Next line")
        precondition(TeamsChatListPresentation.preview(for: group, accountID: "other") == "Ada: Hello world & friends Next line")
        precondition(TeamsChatListPresentation.preview(for: group, accountID: "ada") == "You: Hello world & friends Next line")
        for type in ["ThreadActivity/AddMember", "Control/Typing", "RichText/Media_Card"] {
            let chat = TeamsWebChat(id: "system", lastMessage: .init(id: "system", content: "Hidden", contentType: "Text", messageType: type))
            precondition(TeamsChatListPresentation.preview(for: chat, accountID: "ada") == nil)
        }
        for content in ["", " \n\t ", "<p> </p>"] {
            let chat = TeamsWebChat(id: "empty", lastMessage: .init(id: "empty", content: content, messageType: "RichText/Html"))
            precondition(TeamsChatListPresentation.preview(for: chat, accountID: "ada") == nil)
        }
        precondition(TeamsChatListPresentation.preview(for: .init(id: "missing"), accountID: "ada") == nil)
        let deleted = TeamsWebMessage(id: "deleted", content: "Secret", messageType: "RichText/Html", properties: .object(["deletetime": .string("1800000000000")]))
        precondition(TeamsChatListPresentation.preview(for: .init(id: "deleted", lastMessage: deleted), accountID: "ada") == nil)
        let plain = TeamsWebChat(id: "plain", isOneOnOne: true, lastMessage: .init(id: "plain", content: "Hi\n there", messageType: "Text"))
        precondition(TeamsChatListPresentation.preview(for: plain, accountID: "ada") == "Hi there")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        calendar.locale = locale
        func date(_ day: Int, hour: Int = 14, minute: Int = 5) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let now = date(12, hour: 16)
        func label(_ value: Date?) -> String? {
            TeamsChatListPresentation.timestampLabel(for: value, now: now, calendar: calendar, locale: locale)
        }
        precondition(label(date(12))?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") == "2:05 PM")
        precondition(label(date(11)) == "Yesterday")
        precondition(label(date(10)) == "Tuesday")
        precondition(label(date(6)) == "Friday")
        precondition(label(date(5)) == "11/5")
        precondition(label(date(3)) == "11/3")
        precondition(label(nil) == nil)
        print("CHAT_LIST_PRESENTATION_OK: HTML, sender prefixes, non-text and empty previews, timestamp buckets")
    }
}
