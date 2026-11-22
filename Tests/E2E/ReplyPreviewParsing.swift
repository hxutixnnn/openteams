import Foundation
import SwiftSoup
import TeamsCore

@main
struct ReplyPreviewParsing {
    private static let replyOpen = "<blockquote itemscope=\"\" itemtype=\"http://schema.skype.com/Reply\" itemid=\"1700000000000\">"

    private static let samples = [
        replyOpen + "<strong itemprop=\"mri\" itemid=\"8:orgid:a\">Fixture Author</strong><span itemprop=\"time\" itemid=\"1700000000000\"></span><p itemprop=\"preview\">earlier message</p></blockquote><p>reply text</p>",
        replyOpen + "<strong itemprop=\" MRI \" itemid=\"8:orgid:b\">Upper</strong><span itemprop=\"Time\t\" itemid=\"1700000000123\"></span><p itemprop=\"\nPreview\">padded</p></blockquote><p>x</p>",
        replyOpen + "<strong itemprop=\"mri\" itemid=\"8:orgid:first\">First</strong><strong itemprop=\"mri\" itemid=\"8:orgid:second\">Second</strong><p itemprop=\"preview\">one</p><p itemprop=\"preview\">two</p></blockquote>",
        replyOpen + "<div><span><em itemprop=\"mri\" itemid=\"8:orgid:deep\">Deep <b>Name</b></em></span></div><div><p itemprop=\"preview\">a <b>bold</b> <i>word</i>  and   spaces</p></div></blockquote>",
        "<blockquote itemprop=\"mri\" itemscope=\"\" itemtype=\"http://schema.skype.com/Reply\" itemid=\"9\">Self <p itemprop=\"preview\">p</p></blockquote>",
        replyOpen + "<p itemprop=\"preview\">preview only</p></blockquote>",
        replyOpen + "<strong itemprop=\"mri\" itemid=\"8:orgid:a\">Author only</strong></blockquote>",
        replyOpen + "<p>no item properties</p></blockquote><p>after</p>",
        replyOpen + "<strong itemprop=\"mri preview\" itemid=\"8:orgid:a\">Both</strong><p itemprop=\"previewx\">x</p></blockquote>",
        "<blockquote itemscope=\"\" itemtype=\"http://schema.skype.com/Reply\" itemid=\"\"><strong itemprop=\"mri\" itemid=\"\">A</strong><span itemprop=\"time\" itemid=\"soon\"></span><p itemprop=\"preview\">bad time</p></blockquote>",
        replyOpen + "<strong itemprop=\"mri\" itemid=\"8:orgid:a\">A</strong><span itemprop=\"time\" itemid=\"1e20\"></span><p itemprop=\"preview\">huge time</p></blockquote>",
        replyOpen + "<strong ITEMPROP=\"mri\" itemid=\"8:orgid:upperkey\">Upper key</strong><p ItemProp=\"preview\">mixed key</p></blockquote>",
        replyOpen + "<strong itemprop=\"mri\" itemid=\"8:orgid:outer\">Outer</strong>" + replyOpen + "<strong itemprop=\"mri\" itemid=\"8:orgid:inner\">Inner</strong><p itemprop=\"preview\">inner preview</p></blockquote><p itemprop=\"preview\">outer preview</p></blockquote>",
        replyOpen + "<strong itemprop=\"mri\" itemid=\"8:orgid:a\">" + String(repeating: "Long ", count: 100) + "</strong><p itemprop=\"preview\"><b>bold</b> long author</p></blockquote>",
        "<p>before</p>" + replyOpen + "<strong itemprop=\"mri\" itemid=\"8:orgid:a\">Mid</strong><p itemprop=\"preview\">middle</p></blockquote><p>after</p>",
    ]

    private struct Expected: Equatable {
        let messageID: String?
        let senderID: String?
        let author: String
        let date: Date?
        let previewText: String
    }

    private static func expected(_ html: String) throws -> Expected? {
        guard let reply = try SwiftSoup.parseBodyFragment(html).select("blockquote").first(where: {
            (try? $0.attr("itemtype")) == "http://schema.skype.com/Reply"
        }) else { return nil }
        let id = try reply.attr("itemid")
        let mri = try reply.select("[itemprop=mri]").first()
        let author = try mri?.text() ?? ""
        let sender = try mri?.attr("itemid") ?? ""
        let previewText = try reply.select("[itemprop=preview]").first()?.text() ?? ""
        let time = Double(try reply.select("[itemprop=time]").first()?.attr("itemid") ?? "")
        let date = time.flatMap { $0.isFinite && $0 > 0 && $0 < 100_000_000_000_000 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        guard !author.isEmpty || !previewText.isEmpty else { return nil }
        return Expected(messageID: id.isEmpty || id.utf8.count > 512 ? nil : id,
                        senderID: sender.isEmpty || sender.utf8.count > 512 ? nil : sender,
                        author: String((author.isEmpty ? "Unknown author" : author).prefix(200)),
                        date: date, previewText: previewText)
    }

    private static func check(_ html: String) throws {
        let reply = TeamsBodyParser.parse(html, messageType: "RichText/Html").blocks.lazy.compactMap(\.reply).first
        let actual = reply.map {
            Expected(messageID: $0.messageID, senderID: $0.senderID, author: $0.author, date: $0.date,
                     previewText: $0.excerpt.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        let reference = try expected(html)
        precondition(actual == reference, "Reply mismatch for \(html.prefix(120).debugDescription): \(String(describing: actual)) vs \(String(describing: reference))")
    }

    static func main() throws {
        for html in samples { try check(html) }
        let keys = ["itemprop", "ITEMPROP", "data-x"]
        let names = ["mri", " MRI", "preview", "Preview ", "time", "mri preview", "other"]
        var state: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33) % bound
        }
        for index in 0..<2_000 {
            var inner = ""
            for item in 0..<next(6) {
                let element = ["strong", "span", "p", "em"][next(4)]
                let wrap = next(3) == 0
                inner += (wrap ? "<div>" : "") + "<\(element) \(keys[next(keys.count)])=\"\(names[next(names.count)])\" itemid=\"\(next(2) == 0 ? "170000000\(item)000" : "8:orgid:\(item)")\">text \(index) \(item)</\(element)>" + (wrap ? "</div>" : "")
            }
            try check(replyOpen + inner + "</blockquote><p>reply \(index)</p>")
        }

        let messages = (0..<2_000).map { samples[0] + "<p>\($0)</p>" }
        var timings: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            for message in messages { _ = TeamsBodyParser.parse(message, messageType: "RichText/Html") }
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        print("REPLY_PREVIEW_PARSING_OK: \(samples.count) samples, 2000 generated replies, 2000 reply messages parse median \(String(format: "%.2f", timings.sorted()[2])) ms")
    }
}
