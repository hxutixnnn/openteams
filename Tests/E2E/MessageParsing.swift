import Foundation
import TeamsCore

private actor MessageParsingTransport: HTTPTransport {
    let messages: [TeamsWebMessage]
    init(messages: [TeamsWebMessage]) { self.messages = messages }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.httpMethod == "GET", let url = request.url else { throw URLError(.unsupportedURL) }
        let data: Data
        if url.path.hasSuffix("/chats") {
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture", title: "Fictional parsing", isOneOnOne: true)]))
        } else if url.path.hasSuffix("/messages") {
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: messages))
        } else { throw URLError(.unsupportedURL) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct MessageParsing {
    static func card(_ texts: [String]) throws -> String {
        let body = texts.map { ["type": "TextBlock", "text": $0] }
        let data = try JSONSerialization.data(withJSONObject: ["type": "AdaptiveCard", "body": body])
        return "<swift b64='\(data.base64EncodedString())'></swift>"
    }

    @MainActor static func main() async throws {
        let image = "<img src='https://example.com/image.png' alt='Fixture image'>"
        let imageCard = try card(Array(repeating: image, count: 25))
        var nested = "<p>Nested card text</p>"
        for _ in 0..<3 { nested = try card([nested]) }
        let bodies = [
            "Hello <b>world</b>", "<p>Hello <b>world</b></p>", "",
            "<swift b64='invalid'></swift><p>After</p>",
            try card(["<p>Card title</p>", "Card body"]), imageCard, image + imageCard + image, nested,
            String(repeating: "<div>", count: 97) + nested + String(repeating: "</div>", count: 97) + "<p>After depth limit</p>"
        ]
        let messages = bodies.enumerated().map { index, body in
            TeamsWebMessage(id: String(1_800_000_000_000 + index), content: body, messageType: index == 0 ? "Text" : "RichText/Html", version: "1")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-message-parsing-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = MessageParsingTransport(messages: messages)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!, accessToken: "fictional", expiresAt: .distantFuture, accountID: "fixture-a", tenantID: "fixture-tenant", displayName: "Fictional account")
        await store.connect(session: session)
        precondition(store.chats.map(\.id) == ["fixture"])
        await store.loadConversation("fixture")
        let published = store.messages(in: "fixture")
        precondition(published.map(\.id) == messages.map(\.id))
        let plain = published[0].body
        precondition(plain.text == "Hello <b>world</b>" && !plain.hasUnsupportedContent)
        let rich = published[1].body
        precondition(rich.text == "Hello world" && !rich.hasUnsupportedContent)
        precondition(rich.blocks.flatMap(\.runs).contains { $0.text == "world" && $0.bold })
        let empty = published[2].body
        precondition(empty.text == "Message content is unavailable." && empty.hasUnsupportedContent)
        let malformed = published[3].body
        precondition(malformed.text == "After" && malformed.hasUnsupportedContent)

        let adaptive = published[4].body
        precondition(adaptive.text == "Card title\nCard body" && adaptive.hasUnsupportedContent)
        let images = published[5].body
        precondition(images.blocks.compactMap(\.image).count == 20 && images.hasUnsupportedContent)
        let sharedImages = published[6].body
        precondition(sharedImages.blocks.compactMap(\.image).count == 20 && sharedImages.hasUnsupportedContent)

        let shallow = published[7].body
        precondition(shallow.text == "Nested card text")
        let deep = published[8].body
        precondition(deep.text == "After depth limit" && deep.hasUnsupportedContent)
        print("MESSAGE_PARSING_OK: plain, rich, empty, malformed card, adaptive card, shared image limit, nested depth limit")
    }
}
