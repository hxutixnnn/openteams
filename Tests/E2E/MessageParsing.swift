import Foundation
import TeamsCore

@main struct MessageParsing {
    static func card(_ texts: [String]) throws -> String {
        let body = texts.map { ["type": "TextBlock", "text": $0] }
        let data = try JSONSerialization.data(withJSONObject: ["type": "AdaptiveCard", "body": body])
        return "<swift b64='\(data.base64EncodedString())'></swift>"
    }

    static func main() throws {
        let plain = TeamsBodyParser.parse("Hello <b>world</b>", messageType: "Text")
        precondition(plain.text == "Hello <b>world</b>" && !plain.hasUnsupportedContent)
        let rich = TeamsBodyParser.parse("<p>Hello <b>world</b></p>", messageType: "RichText/Html")
        precondition(rich.text == "Hello world" && !rich.hasUnsupportedContent)
        precondition(rich.blocks.flatMap(\.runs).contains { $0.text == "world" && $0.bold })
        let empty = TeamsBodyParser.parse("")
        precondition(empty.text == "Message content is unavailable." && empty.hasUnsupportedContent)
        let malformed = TeamsBodyParser.parse("<swift b64='invalid'></swift><p>After</p>")
        precondition(malformed.text == "After" && malformed.hasUnsupportedContent)

        let adaptive = TeamsBodyParser.parse(try card(["<p>Card title</p>", "Card body"]))
        precondition(adaptive.text == "Card title\nCard body" && adaptive.hasUnsupportedContent)
        let image = "<img src='https://example.com/image.png' alt='Fixture image'>"
        let imageCard = try card(Array(repeating: image, count: 25))
        let images = TeamsBodyParser.parse(imageCard)
        precondition(images.blocks.compactMap(\.image).count == 20 && images.hasUnsupportedContent)
        let sharedImages = TeamsBodyParser.parse(image + imageCard + image)
        precondition(sharedImages.blocks.compactMap(\.image).count == 20)

        var nested = "<p>Nested card text</p>"
        for _ in 0..<3 { nested = try card([nested]) }
        let shallow = TeamsBodyParser.parse(nested)
        precondition(shallow.text == "Nested card text")
        let deep = TeamsBodyParser.parse(String(repeating: "<div>", count: 97) + nested + String(repeating: "</div>", count: 97) + "<p>After depth limit</p>")
        precondition(deep.text == "After depth limit" && deep.hasUnsupportedContent)
        print("MESSAGE_PARSING_OK: plain, rich, empty, malformed card, adaptive card, shared image limit, nested depth limit")
    }
}
