import Foundation
import TeamsCore

@main struct TimestampLabelLoading {
    private struct Sample: Sendable {
        let date: Date?
        let now: Date
        let calendar: Calendar
        let locale: Locale
        let expected: [UInt8]?

        init(date: Date?, now: Date, calendar: Calendar, locale: Locale) {
            self.date = date
            self.now = now
            self.calendar = calendar
            self.locale = locale
            expected = reference(date, now: now, calendar: calendar, locale: locale).map { Array($0.utf8) }
        }

        func check() {
            let actual = TeamsChatListPresentation.timestampLabel(for: date, now: now, calendar: calendar, locale: locale)
            precondition(actual.map { Array($0.utf8) } == expected, "Timestamp mismatch: \(locale.identifier), \(calendar.identifier), \(calendar.timeZone.identifier), \(String(describing: date))")
        }
    }

    private static func reference(_ date: Date?, now: Date, calendar: Calendar, locale: Locale) -> String? {
        guard let date else { return nil }
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let age = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        if age == 1 {
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
        let template: String
        switch age {
        case 0: template = "jm"
        case 2...6: template = "EEEE"
        default: template = "Md"
        }
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func samples() -> [Sample] {
        let parser = ISO8601DateFormatter()
        let anchors = ["2026-03-08T09:59:59Z", "2026-03-08T10:00:00Z", "2026-11-01T08:59:59Z", "2026-11-01T09:00:00Z", "2026-12-31T23:59:59Z"].map { parser.date(from: $0)! }
        var result: [Sample] = []
        for identifier in ["en_US", "en_GB", "de_DE", "ja_JP", "ar_SA", "en_US@hours=h23"] {
            let locale = Locale(identifier: identifier)
            for kind in [Calendar.Identifier.gregorian, .japanese, .buddhist] {
                for zone in ["UTC", "Asia/Saigon", "America/Los_Angeles"] {
                    var calendar = Calendar(identifier: kind)
                    calendar.locale = locale
                    calendar.timeZone = TimeZone(identifier: zone)!
                    for anchor in anchors {
                        let midnight = calendar.startOfDay(for: anchor)
                        for now in [anchor, midnight.addingTimeInterval(-0.001), midnight, midnight.addingTimeInterval(0.001)] {
                            var dates: [Date?] = [nil, .distantPast, .distantFuture, midnight.addingTimeInterval(-0.001), midnight, midnight.addingTimeInterval(0.001), now]
                            for age in [-2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 30, 366] {
                                let day = calendar.date(byAdding: .day, value: -age, to: now)!
                                dates.append(calendar.date(bySettingHour: 14, minute: 5, second: 0, of: day)!)
                            }
                            for date in dates { result.append(Sample(date: date, now: now, calendar: calendar, locale: locale)) }
                        }
                    }
                }
            }
        }
        return result
    }

    private static func checkCurrentConfigurations() -> Int {
        let original = NSTimeZone.default
        defer {
            NSTimeZone.default = original
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        }
        let liveCalendar = Calendar.autoupdatingCurrent
        let liveZone = TimeZone.autoupdatingCurrent
        let liveLocale = Locale.autoupdatingCurrent
        var count = 0
        var liveZones: Set<String> = []
        for zone in ["UTC", "Asia/Saigon", "America/Los_Angeles", "UTC"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            liveZones.insert(liveCalendar.timeZone.identifier)
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = liveZone
            var localized = Calendar(identifier: .buddhist)
            localized.locale = liveLocale
            for calendar in [Calendar.current, liveCalendar, calendar, localized] {
                for locale in [Locale.current, liveLocale, Locale(identifier: "en_GB")] {
                    let now = Date(timeIntervalSince1970: 1_800_000_000)
                    for offset in [-90_000.0, -10, 0, 10, 90_000, 604_800] {
                        Sample(date: now.addingTimeInterval(offset), now: now, calendar: calendar, locale: locale).check()
                        count += 1
                    }
                }
            }
        }
        precondition(liveZones.count > 1)
        return count
    }

    private static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }

    private static func benchmark() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = (0..<1000).map { now.addingTimeInterval(-Double($0 % 10) * 86400) }
        let chats = (0..<1000).map { index in
            let message = TeamsWebMessage(id: String(index), content: "<p><strong>Fictional message \(index)</strong> Xin chào 👋 <a href=\"https://example.com/fixture\">Reference</a></p><ol><li>First item</li><li><em>Second item</em></li></ol><blockquote>Fictional quoted content</blockquote>", messageType: "RichText/Html", imDisplayName: "Fixture User", from: .string("8:orgid:other"))
            return TeamsWebChat(id: String(index), isOneOnOne: false, lastMessage: message)
        }
        for date in dates.prefix(10) { _ = TeamsChatListPresentation.timestampLabel(for: date, now: now) }
        for name in ["timestamp_labels", "chat_list_rows"] {
            let start = ContinuousClock.now
            var sink = 0
            for (chat, date) in zip(chats, dates) {
                if name == "chat_list_rows" { sink += TeamsChatListPresentation.preview(for: chat, accountID: "fixture")?.utf8.count ?? 0 }
                sink += TeamsChatListPresentation.timestampLabel(for: date, now: now)?.utf8.count ?? 0
            }
            let elapsed = milliseconds(start)
            precondition(sink > 0)
            let row: [String: Any] = ["name": name, "count": dates.count, "ms": elapsed, "sink": sink]
            print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        }
    }

    static func main() async throws {
        if !CommandLine.arguments.contains("--benchmark") {
            let cases = samples()
            for sample in cases { sample.check() }
            await withTaskGroup(of: Void.self) { group in
                for worker in 0..<16 {
                    group.addTask {
                        for index in 0..<1024 {
                            cases[(worker * 997 + index * 31) % cases.count].check()
                            if index % 97 == 0 {
                                NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
                                NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
                            }
                        }
                    }
                }
            }
            let currentCases = checkCurrentConfigurations()
            print("TIMESTAMP_EQUIVALENCE_OK cases=\(cases.count) concurrent=16384 current_configurations=\(currentCases) locales=6 calendars=3 zones=3 dst=spring_and_fall midnight=true nil=true byte_identical=true")
        }
        try benchmark()
        if CommandLine.arguments.contains("--benchmark") {
            print("TIMESTAMP_BENCHMARK_OK")
        } else {
            print("TIMESTAMP_LABEL_LOADING_OK: reference equivalence, bounded-cache churn, concurrent callers, current configuration changes, 1000 labels and rows")
        }
    }
}
