import Foundation

public enum TeamsChatListPresentation {
    private static let timestampFormatters = TimestampFormatters()
    private static let previewTexts = PreviewTexts()

    public static func preview(for chat: TeamsWebChat, accountID: String) -> String? {
        guard let message = chat.lastMessage, !TeamsRenderedMessage.isDeleted(message), let content = message.content, !content.isEmpty else { return nil }
        let type = (message.messageType ?? message.contentType ?? "").lowercased()
        guard type == "text" || type == "richtext" || type == "richtext/html" else { return nil }
        let text = previewTexts.text(for: content, isPlainText: type == "text")
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
        return timestampFormatters.string(from: date, now: now, calendar: calendar, locale: locale)
    }
}

private final class PreviewTexts: @unchecked Sendable {
    private struct Key: Hashable {
        let content: String
        let isPlainText: Bool
    }

    private let lock = NSLock()
    private var texts: [Key: String] = [:]

    func text(for content: String, isPlainText: Bool) -> String {
        let key = Key(content: content, isPlainText: isPlainText)
        if let text = lock.withLock({ texts[key] }) { return text }
        let body = TeamsBodyParser.parse(content, messageType: isPlainText ? "Text" : "RichText/Html")
        let text = body.blocks.map(\.text).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        lock.withLock {
            if texts.count >= 2_048 { texts.removeAll(keepingCapacity: true) }
            texts[key] = text
        }
        return text
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

    private struct DayBoundaries {
        let sixDaysAgo: Date
        let yesterday: Date
        let today: Date
        let tomorrow: Date

        init(containing now: Date, calendar: Calendar) {
            let today = calendar.startOfDay(for: now)
            func start(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: today).map(calendar.startOfDay) ?? today }
            self.today = today
            tomorrow = start(1)
            yesterday = start(-1)
            sixDaysAgo = start(-6)
        }

        func contains(_ now: Date) -> Bool { today <= now && now < tomorrow }

        func template(for date: Date) -> String? {
            if today <= date && date < tomorrow { return "jm" }
            if yesterday <= date && date < today { return nil }
            if sixDaysAgo <= date && date < yesterday { return "EEEE" }
            return "Md"
        }
    }

    private let lock = NSLock()
    private var formatters: [Key: Formatter] = [:]
    private var dayBoundaries: [Calendar: DayBoundaries] = [:]
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

    func string(from date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if locale == .autoupdatingCurrent || calendar == .autoupdatingCurrent || calendar.locale == .autoupdatingCurrent || calendar.timeZone == .autoupdatingCurrent {
            let template = DayBoundaries(containing: now, calendar: calendar).template(for: date)
            return makeFormatter(for: Key(template: template, calendar: calendar, locale: locale)).string(from: date)
        }
        lock.lock()
        defer { lock.unlock() }
        let days: DayBoundaries
        if let cached = dayBoundaries[calendar], cached.contains(now) {
            days = cached
        } else {
            days = DayBoundaries(containing: now, calendar: calendar)
            if dayBoundaries.count >= 64 { dayBoundaries.removeAll(keepingCapacity: true) }
            dayBoundaries[calendar] = days
        }
        let key = Key(template: days.template(for: date), calendar: calendar, locale: locale)
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
        dayBoundaries.removeAll(keepingCapacity: true)
    }
}
