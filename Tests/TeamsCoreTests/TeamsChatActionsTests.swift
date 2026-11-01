import Foundation
import Testing
@testable import TeamsCore

private actor ChatActionsTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct TeamsChatActionsTests {
    private func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa-test",
              expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Example",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!,
                               accessToken: "ic3-test", expiresAt: .distantFuture))
    }
    private func message(sender: String = "8:orgid:account", id: String = "9007199254740993") -> TeamsWebMessage {
        .init(id: id, content: "old", messageType: "Text", from: .string(sender),
              originalArrivalTime: "1793420000123", composeTime: "2026-10-31T00:00:00Z",
              properties: .object(["files": .string("[]")]), clientMessageId: "1234567890123456789")
    }
    private func body(_ request: URLRequest) throws -> [String: TeamsWebJSONValue] {
        try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: #require(request.httpBody))
    }

    @Test func editAndDeleteUseOwnMessageContractsAndIC3Authorization() async throws {
        let transport = ChatActionsTransport()
        let client = TeamsChatActionsClient(session: session(), transport: transport)
        let now = Date(timeIntervalSince1970: 1793421234)
        try await client.editText("Updated 👋", in: "19:a/b@thread.v2", message: message(), at: now)
        try await client.delete(in: "19:a/b@thread.v2", message: message())
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "PUT")
        #expect(requests[0].url?.absoluteString == "https://teams.cloud.microsoft/api/chatsvc/amer/v1/users/ME/conversations/19%3Aa%2Fb%40thread.v2/messages/9007199254740993")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer ic3-test")
        #expect(!requests[0].httpShouldHandleCookies)
        let edited = try body(requests[0])
        #expect(edited["content"] == .string("Updated 👋"))
        #expect(edited["id"] == .string("9007199254740993"))
        #expect(edited["clientmessageid"] == .string("1234567890123456789"))
        #expect(edited["originalarrivaltime"] == .string("1793420000123"))
        #expect(edited["properties"] == .object(["files": .string("[]"), "formatVariant": .string("TEAMS"), "edittime": .number(1793421234000)]))
        #expect(requests[1].httpMethod == "DELETE")
        #expect(requests[1].url?.query == "behavior=softDelete")
        #expect(requests[1].httpBody == nil)
    }

    @Test func ownershipAndPlaceholderGuardsPreventRequests() async throws {
        let transport = ChatActionsTransport()
        let client = TeamsChatActionsClient(session: session(), transport: transport)
        await #expect(throws: TeamsChatActionError.ownMessageRequired) {
            try await client.editText("edit", in: "chat", message: message(sender: "8:orgid:someone-else"))
        }
        await #expect(throws: TeamsChatActionError.ownMessageRequired) {
            try await client.delete(in: "chat", message: message(sender: "8:orgid:someone-else"))
        }
        await #expect(throws: TeamsChatActionError.invalidMessage) {
            try await client.delete(in: "chat", message: message(id: "-1"))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func richEditRebuildsReplyAndMentionMetadata() async throws {
        let transport = ChatActionsTransport()
        let mentions = #"[{"itemid":"0","mri":"8:orgid:person","mentionType":"person","displayName":"Ada"}]"#
        let content = #"<blockquote itemscope="" itemtype="http://schema.skype.com/Reply" itemid="123"><strong itemprop="mri" itemid="8:orgid:sender">Sam</strong><span itemprop="time" itemid="123"></span><p itemprop="preview">Earlier</p></blockquote><p>Hello <span itemtype="http://schema.skype.com/Mention" itemscope="" itemid="0">Ada</span></p>"#
        let original = TeamsWebMessage(id: "456", content: content, messageType: "RichText/Html", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", properties: .object(["mentions": .string(mentions), "pinned": .bool(true), "unrelated": .string("do not copy")]), clientMessageId: "789")
        var draft = try TeamsRichEditImport(message: original).document
        draft.blocks[0].runs[0].bold = true
        try await TeamsChatActionsClient(session: session(), transport: transport).editDocument(draft, in: "chat", message: original)
        let request = try #require(await transport.requests.first)
        let value = try body(request)
        #expect(value["messagetype"] == .string("RichText/Html"))
        #expect(value["originalarrivaltime"] == .string("1000") && value["clientmessageid"] == .string("789"))
        let html = try #require(value["content"]?.stringValue)
        #expect(html.contains("schema.skype.com/Reply") && html.contains("<strong>Hello </strong>"))
        guard case let .object(properties)? = value["properties"] else { Issue.record("Missing properties"); return }
        #expect(properties["pinned"] == .bool(true) && properties["unrelated"] == nil)
        #expect(properties["mentions"]?.stringValue?.contains("8:orgid:person") == true)
        #expect(properties["qtdMsgs"]?.stringValue?.contains("8:orgid:sender") == true)
    }
    @Test func editDocumentRejectsAttachmentsEvenForPlainText() async throws {
        let transport = ChatActionsTransport()
        let original = TeamsWebMessage(id: "456", content: "Caption", messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", properties: .object(["files": .string("[{\"id\":\"file\"}]")]))
        #expect(throws: TeamsChatActionError.unsupportedMessage) { try TeamsChatActionsClient.editableContent(original) }
        await #expect(throws: TeamsChatActionError.unsupportedMessage) {
            try await TeamsChatActionsClient(session: session(), transport: transport).editDocument(.init(plainText: "Changed"), in: "chat", message: original)
        }
        #expect(await transport.requests.isEmpty)
    }
    @Test func editDocumentRejectsTopLevelMediaForwardAndLowercaseOnBehalf() async throws {
        let transport = ChatActionsTransport()
        let bodies = [
            #"{"id":"456","content":"Caption","messageType":"Text","from":"8:orgid:account","originalArrivalTime":"1000","composeTime":"2026-10-31T00:00:00Z","amsreferences":["asset"]}"#,
            #"{"id":"456","content":"Caption","messageType":"Text","from":"8:orgid:account","originalArrivalTime":"1000","composeTime":"2026-10-31T00:00:00Z","forwardedMessageContext":[{"id":"x"}]}"#,
            #"{"id":"456","content":"Caption","messageType":"Text","from":"8:orgid:account","originalArrivalTime":"1000","composeTime":"2026-10-31T00:00:00Z","properties":{"onbehalfof":"sender"}}"#,
            #"{"id":"456","content":"Caption","messageType":"Text","from":"8:orgid:account","originalArrivalTime":"1000","composeTime":"2026-10-31T00:00:00Z","properties":"malformed"}"#,
            #"{"id":"456","content":"Caption","messageType":"Text","from":"8:orgid:account","originalArrivalTime":"1000","composeTime":"2026-10-31T00:00:00Z","properties":{"subject":"Important subject"}}"#
        ]
        for body in bodies {
            let message = try JSONDecoder().decode(TeamsWebMessage.self, from: Data(body.utf8))
            await #expect(throws: TeamsChatActionError.unsupportedMessage) {
                try await TeamsChatActionsClient(session: session(), transport: transport).editDocument(.init(plainText: "Changed"), in: "chat", message: message)
            }
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func reactionsUseTimestampedPropertySetAndKeyOnlyRemoval() async throws {
        let transport = ChatActionsTransport()
        let client = TeamsChatActionsClient(session: session(), transport: transport)
        try await client.setReaction("like", in: "chat", message: message(), at: Date(timeIntervalSince1970: 1000))
        try await client.removeReaction("like", in: "chat", message: message())
        let requests = await transport.requests
        #expect(requests[0].httpMethod == "PUT")
        #expect(requests[0].url?.query == "name=emotions&replace=true")
        #expect(try body(requests[0]) == ["emotions": .object(["key": .string("like"), "value": .number(1000000)])])
        #expect(requests[1].httpMethod == "DELETE")
        #expect(requests[1].url?.query == "name=emotions")
        #expect(try body(requests[1]) == ["emotions": .object(["key": .string("like")])])
    }

    @Test func readHorizonPreservesLargeClientIDAndQuoteUsesSerializedMetadata() async throws {
        let transport = ChatActionsTransport()
        try await TeamsChatActionsClient(session: session(), transport: transport)
            .markRead(in: "chat", through: message(), at: Date(timeIntervalSince1970: 1793421234))
        let request = try #require(await transport.requests.first)
        #expect(request.url?.query == "name=consumptionhorizon")
        #expect(try body(request) == ["consumptionhorizon": .string("1793420000123;1793421234000;1234567890123456789")])
        let properties = try TeamsChatActionsClient.quotedReplyProperties(for: message())
        let serialized = try #require(properties["qtdMsgs"]?.stringValue)
        let quote = try JSONDecoder().decode([[String: TeamsWebJSONValue]].self, from: Data(serialized.utf8))
        #expect(quote == [["messageId": .string("9007199254740993"), "sender": .string("8:orgid:account"), "time": .number(1793420000123)]])
    }

    @Test func quotedReplyHTMLEscapesBothPreviewAndComposedText() throws {
        let result = try TeamsChatActionsClient.quotedReplyContent("Hello <tag> & 👋\nnext", replyingTo: message(), preview: "<script>bad</script>")
        #expect(result.content.contains("itemtype=\"http://schema.skype.com/Reply\""))
        #expect(result.content.contains("itemid=\"9007199254740993\""))
        #expect(result.content.contains("&lt;script&gt;bad&lt;/script&gt;"))
        #expect(result.content.hasSuffix("<p>Hello &lt;tag&gt; &amp; 👋</p><p>next</p>"))
        #expect(!result.content.contains("<script>"))
        #expect(result.properties["qtdMsgs"]?.stringValue != nil)
    }

    @Test func uncertainWritesAreNotRetried() async throws {
        let transport = ChatActionsTransport(status: 503)
        await #expect(throws: TeamsChatActionError.outcomeUnknown) {
            try await TeamsChatActionsClient(session: session(), transport: transport).delete(in: "chat", message: message())
        }
        #expect(await transport.requests.count == 1)
    }
}
