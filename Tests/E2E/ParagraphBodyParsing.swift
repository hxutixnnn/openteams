import Foundation
import TeamsCore

@main
struct ParagraphBodyParsing {
    private static let samples = [
        "<p>See you at 3pm, thanks!</p>", "<p></p>", "<p> </p>", "<p>  two  spaces  </p>", "<p>tab\there</p>", "<p>line\nbreak</p>",
        "<p>\r\nwindows\r\n</p>", "<p>\u{a0}nbsp\u{a0}</p>", "<p>Xin chào 👋 🇻🇳</p>", "<p>a > b and \"quotes\" 'single'</p>",
        "<p>first</p><p>second</p>", "<p>first</p><p></p><p>third</p>", "<p>\n</p><p>kept</p>", "<p>first</p>\n<p>second</p>",
        "<p>first</p> trailing", "<p>unclosed", "<p>a</p><p>b", "<P>upper</P>", "<p class=\"x\">attr</p>", "<p>a &amp; b</p>",
        "<p>a <b>bold</b></p>", "<p>nul\u{0}</p>", "<p>\u{ffff}</p>", "<p></p></p>", "<p><p>nested</p></p>", "</p>", "<p>",
        "<p>" + String(repeating: "long text ", count: 20_000) + "</p>", "<p>" + String(repeating: "x", count: 1_000_001) + "</p>",
    ]

    private static func reference(_ html: String, messageType: String?) -> TeamsMessageBody {
        let truncated = html.utf8.count > 1_000_000
        let body = TeamsBodyParser.parse((truncated ? String(html.prefix(200_000)) : html) + "<!---->", messageType: messageType)
        return .init(text: body.text, blocks: body.blocks, hasUnsupportedContent: body.hasUnsupportedContent || truncated)
    }

    private static func check(_ html: String) {
        for messageType in [nil, "RichText/Html"] {
            precondition(TeamsBodyParser.parse(html, messageType: messageType) == reference(html, messageType: messageType),
                         "Body mismatch for \(html.prefix(60).debugDescription)")
        }
    }

    static func main() {
        samples.forEach(check)
        let pieces = ["word", " ", "  ", "\n", "\t", "é", "👋", ">", "\"", "\u{a0}", "\u{2028}", "</p><p>", ""]
        var state: UInt64 = 0x9A7A
        for _ in 0..<4_000 {
            var text = ""
            for _ in 0..<Int(state % 12) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                text += pieces[Int(state >> 33) % pieces.count]
            }
            check("<p>" + text + "</p>")
        }

        let messages = (0..<2_000).map { "<p>Fixture message \($0), see you at 3pm, thanks!</p>" }
        var timings: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            for message in messages { _ = TeamsBodyParser.parse(message, messageType: "RichText/Html") }
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        print("PARAGRAPH_BODY_PARSING_OK: \(samples.count) samples, 4000 generated paragraphs, 2000 paragraph messages parse median \(String(format: "%.2f", timings.sorted()[2])) ms")
    }
}
