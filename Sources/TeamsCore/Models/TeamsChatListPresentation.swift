import Foundation

public enum TeamsChatListPresentation {
    private static let timestampFormatters = TimestampFormatters()

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
        let template = days == 1 ? nil : days == 0 ? "jm" : (2..<7).contains(days) ? "EEEE" : "Md"
        return timestampFormatters.string(from: date, template: template, calendar: calendar, locale: locale)
    }
}

private final class TimestampFormatters: @unchecked Sendable {
    private struct Key: Hashable {
        let template: String?
        let calendar: Calendar
        let locale: Locale
    }

    private enum Formatter {
        case date(DateFormatter)
        case relative(RelativeDateTimeFormatter)

        func string(from date: Date) -> String {
            switch self {
            case .date(let formatter): return formatter.string(from: date)
            case .relative(let formatter): return formatter.localizedString(from: DateComponents(day: -1))
            }
        }
    }

    private let lock = NSLock()
    private var formatters: [Key: Formatter] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.removeAll()
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func string(from date: Date, template: String?, calendar: Calendar, locale: Locale) -> String {
        let key = Key(template: template, calendar: calendar, locale: locale)
        if locale == .autoupdatingCurrent || calendar == .autoupdatingCurrent || calendar.locale == .autoupdatingCurrent || calendar.timeZone == .autoupdatingCurrent {
            return makeFormatter(for: key).string(from: date)
        }
        lock.lock()
        defer { lock.unlock() }
        if let formatter = formatters[key] { return formatter.string(from: date) }
        let formatter = makeFormatter(for: key)
        if formatters.count >= 64 { formatters.removeAll(keepingCapacity: true) }
        formatters[key] = formatter
        return formatter.string(from: date)
    }

    private func makeFormatter(for key: Key) -> Formatter {
        if let template = key.template {
            let formatter = DateFormatter()
            formatter.locale = key.locale
            formatter.calendar = key.calendar
            formatter.timeZone = key.calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return .date(formatter)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = key.locale
        formatter.calendar = key.calendar
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .beginningOfSentence
        return .relative(formatter)
    }

    private func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        formatters.removeAll(keepingCapacity: true)
    }
}
