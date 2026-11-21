import Foundation

public enum TeamsChatListPresentation {
    public static func preview(for chat: TeamsWebChat, accountID: String) -> String? {
        guard let message = chat.lastMessage, !TeamsRenderedMessage.isDeleted(message), let content = message.content, !content.isEmpty else { return nil }
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

    public static func timestampLabel(for date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let date else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .named
            formatter.formattingContext = .beginningOfSentence
            return formatter.localizedString(from: DateComponents(day: -1))
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(days == 0 ? "jm" : (2..<7).contains(days) ? "EEEE" : "Md")
        return formatter.string(from: date)
    }
}
