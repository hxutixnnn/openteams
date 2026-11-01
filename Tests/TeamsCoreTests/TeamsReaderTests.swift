import Foundation
import Observation
import Testing
@testable import TeamsCore

private actor ReadFixtureTransport: HTTPTransport {
    struct Reply: Sendable {
        var data: Data
        var status = 200
        var headers: [String: String] = [:]
    }
    var requests: [URLRequest] = []
    var replies: [Reply]
    init(_ replies: [Reply]) { self.replies = replies }
    func enqueue(_ reply: Reply) { replies.append(reply) }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let next = replies.removeFirst()
        return (next.data, HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: next.headers)!)
    }
}

@MainActor
struct TeamsReaderTests {
    private let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "test-only",
              expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Example Person")
    }
    private func reply<T: Encodable>(_ body: T) throws -> ReadFixtureTransport.Reply {
        .init(data: try JSONEncoder().encode(body))
    }
    private func message(_ id: Int, version: String = "1", content: String? = nil) -> TeamsWebMessage {
        .init(id: String(id), content: content ?? "Message \(id)", messageType: "Text",
              originalArrivalTime: String(1_800_000_000 + id), version: version)
    }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }

    @Test func pagingRefreshAndOfflineRestoreKeepOneOrderedCopyPerMessage() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReadFixtureTransport(try [
            reply(TeamsWebChatPage(items: [.init(id: "chat", title: "Conversation")], continuationToken: "chat-page")),
            reply(TeamsWebMessagePage(messages: [message(3), message(2)], messageToken: "older-page")),
            reply(TeamsWebMessagePage(messages: [message(2), message(1)])),
            reply(TeamsWebMessagePage(messages: [message(5), message(4)], messageToken: "refresh-page")),
            reply(TeamsWebMessagePage(messages: [message(3, version: "2", content: "Edited"), message(2)], messageToken: "unused"))
        ])
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session())
        await store.loadConversation("chat")
        #expect(store.messages(in: "chat").map(\.id) == ["2", "3"])
        #expect(store.hasOlderMessages("chat"))
        await store.loadOlderMessages("chat")
        await store.refreshConversation("chat")
        #expect(store.messages(in: "chat").map(\.id) == ["1", "2", "3", "4", "5"])
        #expect(store.messages(in: "chat")[2].body.text == "Edited")
        #expect(!store.hasOlderMessages("chat"))
        let requests = await transport.requests
        #expect(requests[2].value(forHTTPHeaderField: "x-ms-messageToken") == "older-page")
        #expect(requests[4].value(forHTTPHeaderField: "x-ms-messageToken") == "refresh-page")
        let restored = TeamsReaderStore(cacheRoot: root, transport: transport)
        await restored.restoreAccount(accountID: account, tenantID: tenant, displayName: "Example Person")
        await restored.loadConversation("chat")
        #expect(!restored.connected)
        #expect(restored.chats.count == 1)
        #expect(restored.messages(in: "chat").count == 5)
        #expect(await transport.requests.count == 5)
        await restored.restoreAccount(accountID: "another-account", tenantID: tenant, displayName: "Another")
        #expect(restored.chats.isEmpty)
        #expect(restored.messages(in: "chat").isEmpty)
    }

    @Test func expiredServerSessionPreservesCachedReadingAndStopsFurtherRequests() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReadFixtureTransport(try [
            reply(TeamsWebChatPage(items: [.init(id: "chat")])),
            reply(TeamsWebMessagePage(messages: [message(1)])),
            .init(data: Data(), status: 401)
        ])
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session())
        await store.loadConversation("chat")
        await store.refreshConversation("chat")
        #expect(store.sessionExpired && !store.connected)
        #expect(store.messages(in: "chat").count == 1)
        #expect(store.chatErrors["chat"] != nil)
        await store.refreshChats()
        #expect(await transport.requests.count == 3)
    }

    @Test func conversationTitleDoesNotMixBotIdentifiersIntoPeople() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TeamsReaderStore(cacheRoot: root)
        await store.restoreAccount(accountID: account, tenantID: tenant, displayName: "Me")
        let members = [TeamsWebMember(mri: "8:orgid:\(account)", objectId: account, displayName: "Me"),
                       TeamsWebMember(mri: "8:orgid:other", displayName: "Alex"),
                       TeamsWebMember(mri: "28:bot", displayName: "Bot-1234-abcd")]
        #expect(store.conversationTitle(.init(id: "chat", members: members)) == "Alex")
        #expect(store.conversationTitle(.init(id: "bot", members: [members[0], members[2]])) == "Agent")
    }

    @Test func throttlingHonorsRetryAfterAndKeepsTheCurrentList() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReadFixtureTransport(try [
            reply(TeamsWebChatPage(items: [.init(id: "chat")])),
            .init(data: Data(), status: 429, headers: ["Retry-After": "300"])
        ])
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session())
        await store.refreshChats()
        await store.refreshChats()
        #expect(await transport.requests.count == 2)
        #expect(store.chats.count == 1)
        #expect(store.chatListError?.contains("300") == true)
    }

    @Test func cacheMergeRejectsStaleVersionsAndRetainsDeletionTombstones() throws {
        var history = TeamsCachedHistory(messages: [message(1, version: "10", content: "Current")])
        history.merge([message(1, version: "9", content: "Stale")])
        #expect(history.messages.first?.content == "Current")
        history.merge([.init(id: "1", content: "Old content", version: "11", properties: .object(["deletetime": .number(123)]))])
        #expect(history.messages.count == 1)
        #expect(TeamsRenderedMessage(history.messages[0]).isDeleted)
    }

    @Test func unchangedRefreshDoesNotInvalidateRenderedMessages() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = TeamsWebChat(id: "chat", isOneOnOne: true)
        let messages = [message(1), message(2)]
        let transport = ReadFixtureTransport(try [
            reply(TeamsWebChatPage(items: [chat])),
            reply(TeamsWebMessagePage(messages: messages)),
            reply(TeamsWebChatPage(items: [chat])),
            reply(TeamsWebMessagePage(messages: messages))
        ])
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session())
        await store.loadConversation("chat")
        await confirmation(expectedCount: 0) { changed in
            withObservationTracking { _ = store.messages(in: "chat") } onChange: { changed() }
            await store.refreshChats()
            await store.refreshConversation("chat")
        }
        #expect(store.chatListError == nil && store.chatErrors["chat"] == nil)
        #expect(await transport.requests.count == 4)
    }

    @Test func renderingRefreshesSameVersionEditsReactionsFilesAndDeletions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = message(2)
        let files = #"[{"version":2,"id":"file-id","title":"Plan","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://example.sharepoint.com/sites/team/plan.pdf"}]"#
        let edited = TeamsWebMessage(id: original.id, content: "<p>Changed <b>content</b></p>",
                                     messageType: "RichText/Html", imDisplayName: "Updated author",
                                     originalArrivalTime: original.originalArrivalTime, version: original.version,
                                     properties: .object(["edittime": .number(1), "files": .string(files),
                                        "emotions": .array([.object(["key": .string("like"), "users": .array([.object(["mri": .string("8:orgid:other")])])])])]))
        let deleted = TeamsWebMessage(id: original.id, content: edited.content, messageType: edited.messageType,
                                      originalArrivalTime: original.originalArrivalTime, version: original.version,
                                      properties: .object(["deletetime": .number(1)]))
        let transport = ReadFixtureTransport(try [
            reply(TeamsWebChatPage(items: [.init(id: "chat", isOneOnOne: true)])),
            reply(TeamsWebMessagePage(messages: [message(1), original], messageToken: "older")),
            reply(TeamsWebMessagePage(messages: [message(1), edited, message(3)])),
            reply(TeamsWebMessagePage(messages: [message(0)])),
            reply(TeamsWebMessagePage(messages: [deleted]))
        ])
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session())
        await store.loadConversation("chat")
        let untouched = try #require(store.messages(in: "chat").first)
        await store.refreshConversation("chat")
        #expect(store.messages(in: "chat").map(\.id) == ["1", "2", "3"])
        #expect(store.messages(in: "chat").first == untouched)
        #expect(store.messages(in: "chat")[1] == TeamsRenderedMessage(edited, accountScope: store.accountScope,
                                                                   accountRevision: store.accountRevision, chatID: "chat"))
        let attachment = try #require(store.messages(in: "chat")[1].files.first?.sharePoint)
        #expect(store.ownsSharePointAttachment(attachment))
        await store.loadOlderMessages("chat")
        #expect(store.messages(in: "chat").map(\.id) == ["0", "1", "2", "3"])
        #expect(store.messages(in: "chat")[1] == untouched)
        await store.refreshConversation("chat")
        #expect(store.messages(in: "chat")[2].isDeleted)
        #expect(store.messages(in: "chat")[2].files.isEmpty && store.messages(in: "chat")[2].reactions.isEmpty)
        #expect(!store.ownsSharePointAttachment(attachment))
        #expect(store.chatErrors["chat"] == nil)
    }

    @Test func chatRefreshUpdatesFallbackAuthorNames() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = "8:orgid:other"
        let original = TeamsWebChat(id: "chat", isOneOnOne: true, members: [.init(mri: sender, displayName: "Before")])
        let renamed = TeamsWebChat(id: "chat", isOneOnOne: true, members: [.init(mri: sender, displayName: "After")])
        let transport = ReadFixtureTransport(try [
            reply(TeamsWebChatPage(items: [original])),
            reply(TeamsWebMessagePage(messages: [
                .init(id: "1", content: "Fallback", messageType: "Text", from: .string(sender)),
                .init(id: "2", content: "Explicit", messageType: "Text", imDisplayName: "Message author", from: .string(sender))
            ])),
            reply(TeamsWebChatPage(items: [renamed]))
        ])
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session())
        await store.loadConversation("chat")
        #expect(store.messages(in: "chat").map(\.author.name) == ["Before", "Message author"])
        await store.refreshChats()
        #expect(store.messages(in: "chat").map(\.author.name) == ["After", "Message author"])
    }

    @Test func unchangedPresentationStillReconcilesOutgoingDelivery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TeamsWebMessage(id: "1", content: "Fixture draft", messageType: "Text", from: .string("8:orgid:" + account))
        let transport = ReadFixtureTransport(try [
            reply(TeamsWebChatPage(items: [.init(id: "chat", isOneOnOne: true)])),
            reply(TeamsWebMessagePage(messages: [original])),
            .init(data: Data(), status: 503)
        ])
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let sendingSession = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "test-only",
                                             expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Example Person",
                                             messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!,
                                                              accessToken: "fixture-only", expiresAt: .distantFuture))
        await store.connect(session: sendingSession)
        await store.loadConversation("chat")
        store.composer.setDraft("Fixture draft", in: "chat")
        #expect(store.composer.canSend(in: "chat"))
        _ = await store.composer.sendDraft(in: "chat")
        let pending = try #require(store.composer.outgoing["chat"])
        #expect(pending.phase == .uncertain)
        let confirmed = TeamsWebMessage(id: original.id, content: original.content, messageType: original.messageType,
                                        from: original.from, clientMessageId: pending.clientMessageID)
        await transport.enqueue(try reply(TeamsWebMessagePage(messages: [confirmed])))
        await confirmation(expectedCount: 0) { changed in
            withObservationTracking { _ = store.messages(in: "chat") } onChange: { changed() }
            await store.refreshConversation("chat")
        }
        #expect(store.composer.outgoing["chat"] == nil)
        #expect(store.composer.draft(in: "chat").isEmpty)
        #expect(store.chatErrors["chat"] == nil)
        #expect(await transport.requests.count == 4)
    }

    @Test func cachedRenderRebindsAttachmentsAcrossAccountsAndRevisions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = TeamsWebChat(id: "shared-chat", isOneOnOne: true)
        let files = #"[{"version":2,"id":"file","title":"Plan","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://example.sharepoint.com/sites/team/plan.pdf"}]"#
        let raw = TeamsWebMessage(id: "same-message", content: "Attachment", messageType: "Text", properties: .object(["files": .string(files)]))
        for accountID in [account, "other-account"] {
            let cache = TeamsReadCache(root: root, accountID: accountID, tenantID: tenant)
            try await cache.save(.init(chats: [chat]))
            try await cache.save(.init(messages: [raw]), in: chat.id)
        }
        let transport = ReadFixtureTransport([])
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        var previous: TeamsSharePointAttachment?
        for accountID in [account, "other-account", account, account] {
            await store.restoreAccount(accountID: accountID, tenantID: tenant, displayName: "Fixture")
            await store.loadConversation(chat.id)
            let attachment = try #require(store.messages(in: chat.id).first?.files.first?.sharePoint)
            #expect(attachment.accountScope == tenant + ":" + accountID)
            #expect(attachment.accountRevision == store.accountRevision)
            #expect(store.ownsSharePointAttachment(attachment))
            if let previous {
                #expect(previous.accountRevision != attachment.accountRevision)
                #expect(!store.ownsSharePointAttachment(previous))
            }
            previous = attachment
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func cacheMergeKeepsDateFallbacksAndIDTieBreaking() throws {
        let dated = TeamsWebMessage(id: "dated", originalArrivalTime: "2026-10-31T07:00:00.000Z")
        let tie = TeamsWebMessage(id: "tie", originalArrivalTime: "invalid", composeTime: "2026-10-31T14:00:00+07:00")
        let fallback = TeamsWebMessage(id: "1793430000000")
        let missing = TeamsWebMessage(id: "missing", originalArrivalTime: "invalid")
        var history = TeamsCachedHistory(messages: [tie, dated, missing, dated])
        history.merge([fallback])
        #expect(history.messages.map(\.id) == ["missing", "1793430000000", "dated", "tie"])
        let restored = try JSONDecoder().decode(TeamsCachedHistory.self, from: JSONEncoder().encode(history))
        #expect(restored.messages == history.messages)
    }

    @Test func placeholderLastMessageDoesNotDiscardAnOtherwiseValidChat() throws {
        let data = Data(#"{"items":[{"id":"chat","title":"Empty","lastMessage":{"id":null,"content":null}}]}"#.utf8)
        let page = try JSONDecoder().decode(TeamsWebChatPage.self, from: data)
        #expect(page.items.count == 1)
        #expect(page.items[0].lastMessage == nil)
    }

    @Test func nativeRichTextPreservesFormattingWithoutExecutingOrLoadingHTML() {
        let body = TeamsBodyParser.parse("<p>Hello <b>world</b> <at>Minh</at> <a href='https://example.com'>link</a><a href='javascript:bad()'>unsafe</a></p><blockquote>Quote</blockquote><pre>let x = 1\n  x</pre><script>secret()</script><img src='https://example.com/private' alt='Chart'>")
        #expect(body.blocks.contains { $0.kind == .quote && $0.text == "Quote" })
        #expect(body.blocks.contains { $0.kind == .code && $0.text.contains("\n  x") })
        #expect(body.blocks.flatMap(\.runs).contains { $0.bold && $0.text == "world" })
        #expect(body.blocks.flatMap(\.runs).contains { $0.isMention && $0.text == "Minh" })
        #expect(body.blocks.flatMap(\.runs).compactMap(\.link).map(\.absoluteString) == ["https://example.com"])
        #expect(!body.text.contains("secret()"))
        #expect(body.text.contains("[Chart]"))
        #expect(!body.hasUnsupportedContent)
        let images = TeamsBodyParser.parse("<p>Before<img src='https://example.com/a' alt='First' width='452' height='514'>Middle<img src='https://example.com/b' alt='Second'>After</p><blockquote><img src='https://example.com/c'></blockquote><blockquote>Separate</blockquote>")
        #expect(images.blocks.map(\.text) == ["Before", "[First]", "Middle", "[Second]", "After", "[Image]", "Separate"])
        #expect(images.blocks[1].image?.width == 452)
        #expect(images.blocks[1].image?.height == 514)
        let imageOnly = TeamsBodyParser.parse("<img src='https://us-api.asm.skype.com/v1/objects/example/views/imgo' alt='Picture'>")
        #expect(imageOnly.blocks.count == 1 && imageOnly.blocks[0].kind == .image)
        #expect(!TeamsBodyParser.parse("<uriobject><img src='https://us-api.asm.skype.com/v1/objects/example/views/imgo'></uriobject>").hasUnsupportedContent)
        #expect(TeamsBodyParser.parse("<uriobject><attachment></attachment></uriobject>").hasUnsupportedContent)
        #expect(images.blocks[5].quoteGroup != images.blocks[6].quoteGroup)
        #expect(!String(reflecting: images.blocks[1].image!).contains("example.com"))
        let unsafeImage = TeamsBodyParser.parse("<img src='https://user:pass@example.com/x' alt='Unsafe'>")
        #expect(unsafeImage.blocks.first?.image == nil)
        let quotes = TeamsBodyParser.parse("<blockquote><div>Author</div><div>Excerpt</div></blockquote><blockquote><p>Another</p></blockquote>")
        let quoteBlocks = quotes.blocks.filter { $0.kind == .quote }
        #expect(quoteBlocks.map(\.text) == ["Author", "Excerpt", "Another"])
        #expect(quoteBlocks[0].quoteGroup == quoteBlocks[1].quoteGroup)
        #expect(quoteBlocks[1].quoteGroup != quoteBlocks[2].quoteGroup)
        let reply = TeamsBodyParser.parse(#"<blockquote itemtype="http://schema.skype.com/Reply" itemid="123"><strong itemprop="mri" itemid="8:orgid:sender">Alex</strong><span itemprop="time" itemid="1800000000000"></span><p itemprop="preview">A longer original excerpt</p></blockquote><p>Response</p>"#)
        let metadata = reply.blocks.first?.reply
        #expect(metadata?.messageID == "123")
        #expect(metadata?.author == "Alex")
        #expect(metadata?.senderID == "8:orgid:sender")
        #expect(metadata?.resolvedAuthor(original: .init(id: "123", imDisplayName: "Actual Author"), members: []) == "Actual Author")
        #expect(metadata?.resolvedAuthor(original: nil, members: [.init(mri: "8:orgid:sender", displayName: "Roster Author")]) == "Roster Author")
        #expect(metadata?.resolvedAuthor(original: nil, members: []) == "Alex")
        #expect(metadata?.date == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(metadata?.excerpt == "A longer original excerpt")
        #expect(reply.text.contains("A longer original excerpt"))
        let emojiReply = TeamsBodyParser.parse(#"<blockquote itemtype="http://schema.skype.com/Reply" itemid="123"><strong itemprop="mri">Alex</strong><p itemprop="preview">Hello <img itemtype="http://schema.skype.com/Emoji" alt="😄"></p></blockquote>"#)
        #expect(emojiReply.blocks.first?.reply?.excerpt == "Hello 😄")
        #expect(quotes.blocks.allSatisfy { $0.reply == nil })
        let emoji = TeamsBodyParser.parse("<p>Hello <img itemtype='http://schema.skype.com/Emoji' alt='😄' src='https://example.com/emoji'></p>")
        #expect(emoji.text == "Hello 😄")
        #expect(!emoji.hasUnsupportedContent)
        let nested = TeamsBodyParser.parse(String(repeating: "<div>", count: 150) + "deep" + String(repeating: "</div>", count: 150))
        #expect(nested.hasUnsupportedContent)
    }

    @Test func sessionHandoffRejectsWrongAudienceUnsafeDestinationAndExpiredClaims() throws {
        func payload(audience: String = "https://chatsvcagg.teams.microsoft.com", base: String = "https://teams.cloud.microsoft/api/csa/amer", expiry: Double = 2_000_000_000) throws -> Data {
            let claims: [String: Any] = ["aud": audience, "oid": account, "tid": tenant, "name": "Example Person", "exp": expiry]
            let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return try JSONSerialization.data(withJSONObject: ["csaBaseURL": base, "accessToken": "header.\(encoded).test-only", "expiresAt": 2_000_000_000])
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = try TeamsSessionHandoff.decode(payload(), at: now)
        #expect(valid.accountID == account)
        #expect(valid.displayName == "Example Person")
        #expect(throws: TeamsWebClientError.invalidSession) { try TeamsSessionHandoff.decode(payload(audience: "https://graph.microsoft.com"), at: now) }
        #expect(throws: TeamsWebClientError.unsafeBaseURL) { try TeamsSessionHandoff.decode(payload(base: "https://example.com"), at: now) }
        #expect(throws: TeamsWebClientError.expiredSession) { try TeamsSessionHandoff.decode(payload(expiry: 1_700_000_000), at: now) }
    }
}

@Suite struct TeamsTimelineUpdateTests {
    @Test func classifiesMembersWithoutTreatingBotObjectIDsAsPeople() {
        #expect(TeamsWebMember(mri: "8:orgid:person").kind == .person)
        #expect(TeamsWebMember(mri: "28:bot", objectId: UUID().uuidString).kind == .agent)
        #expect(TeamsWebMember(mri: "8:28:bot").kind == .agent)
        #expect(TeamsWebMember(mri: "28:orgid:voice").kind == .unknown)
        #expect(TeamsWebMember(objectId: UUID().uuidString).kind == .unknown)
        #expect(TeamsWebMember(mri: "8:orgid:agent", userIdentityType: "agentic").kind == .agentic)
    }
    @Test func incomingMessagesStickAtBottomOrShowAnIndicatorAbove() {
        let previous = ["1", "2"], incoming = ["1", "2", "3", "4"]
        let bottom = TeamsTimelineUpdate.decide(previous: previous, current: incoming, atBottom: true)
        #expect(bottom.scrollToBottom && bottom.newMessageCount == 0)
        let above = TeamsTimelineUpdate.decide(previous: previous, current: incoming, atBottom: false)
        #expect(!above.scrollToBottom && above.newMessageCount == 2)
        let older = TeamsTimelineUpdate.decide(previous: previous, current: ["0", "1", "2"], atBottom: false)
        #expect(!older.scrollToBottom && older.newMessageCount == 0)
    }
}

private actor DelayedUnauthorizedTransport: HTTPTransport {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var requestCount = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let number = requestCount
        if number == 2 {
            started?.resume(); started = nil
            await withCheckedContinuation { pending = $0 }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func waitForRequest() async {
        if requestCount >= 2 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}

@MainActor
struct TeamsSessionRevisionTests {
    @Test func oldUnauthorizedReadDoesNotDisconnectRenewedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DelayedUnauthorizedTransport()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        func session(_ token: String) -> TeamsWebSession {
            .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: token,
                  expiresAt: .distantFuture, accountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                  tenantID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", displayName: "Example")
        }
        await store.connect(session: session("old"))
        let oldRead = Task { await store.refreshConversation("chat") }
        await transport.waitForRequest()
        await store.connect(session: session("new"))
        await transport.release()
        await oldRead.value
        #expect(store.connected)
        #expect(!store.sessionExpired)
        #expect(store.chatErrors["chat"] == nil)
    }
}

private actor CreationFixtureTransport: HTTPTransport {
    private(set) var creationCount = 0
    private var held: CheckedContinuation<Void, Never>?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == "POST" && request.url!.path.hasSuffix("/v1/threads") {
            creationCount += 1
            await withCheckedContinuation { held = $0 }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                            headerFields: ["Location": "/v1/threads/19:new@thread.v2"])!)
        }
        let data = try JSONEncoder().encode(TeamsWebChatPage(items: []))
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func release() { held?.resume(); held = nil }
}

@MainActor
struct TeamsNewChatStoreTests {
    @Test func pendingCreationBlocksDuplicateAndInsertsConfirmedChat() async throws {
        let account = UUID().uuidString.lowercased(), tenant = UUID().uuidString.lowercased()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CreationFixtureTransport()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa",
                                      expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Test",
                                      messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "chat", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        let person = TeamsDirectoryPerson(mri: "8:orgid:other", displayName: "Other")
        let creation = Task { try await store.createChat(with: [person], title: nil) }
        while await transport.creationCount == 0 { await Task.yield() }
        #expect(store.creationNeedsReview && store.isCreatingChat)
        _ = await store.acknowledgeChatCreationReview(expectedID: store.creationReview?.operationID)
        #expect(store.creationNeedsReview)
        do { _ = try await store.createChat(with: [person], title: nil); Issue.record("Duplicate creation allowed") } catch { }
        #expect(await transport.creationCount == 1)
        await transport.release()
        let result = try await creation.value
        #expect(store.conversation(result.threadID) != nil)
        #expect(!store.creationNeedsReview && store.creationReview?.threadID == result.threadID)
        _ = await store.acknowledgeChatCreationReview(expectedID: store.creationReview?.operationID)
        #expect(!store.creationNeedsReview)
    }
}

private actor ReactionStoreTransport: HTTPTransport {
    private(set) var writes = 0
    private var waiting: CheckedContinuation<Void, Never>?
    var failWrite = false
    var deleted = false
    func setFailure() { failWrite = true }
    func setDeleted() { deleted = true }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response: Data
        if request.httpMethod == "PUT" || request.httpMethod == "DELETE" {
            writes += 1
            await withCheckedContinuation { waiting = $0 }
            if failWrite { throw URLError(.networkConnectionLost) }
            response = Data()
        } else if request.url!.path.hasSuffix("/messages") {
            response = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "1", content: "Hello", messageType: "Text", originalArrivalTime: "1800000000", properties: deleted ? .object(["deletetime": .number(1)]) : nil)]))
        } else {
            response = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        }
        return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func release() { waiting?.resume(); waiting = nil }
}

@MainActor struct TeamsReactionStoreTests {
    private func makeSession() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture,
              accountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", tenantID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", displayName: "Test",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "chat", expiresAt: .distantFuture))
    }
    @Test func blocksCompetingReactionsUntilReadBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReactionStoreTransport()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: makeSession()); await store.loadConversation("chat")
        #expect(store.canReact(in: "chat", messageID: "1"))
        await store.messageAction("like", chatID: "chat", messageID: "1", accountScope: "different-account")
        #expect(await transport.writes == 0)
        let first = Task { await store.messageAction("like", chatID: "chat", messageID: "1") }
        while await transport.writes == 0 { await Task.yield() }
        #expect(!store.canReact(in: "chat", messageID: "1"))
        await store.messageAction("heart", chatID: "chat", messageID: "1")
        #expect(await transport.writes == 1)
        await transport.release(); await first.value
        #expect(store.canReact(in: "chat", messageID: "1"))
        store.disconnect()
        #expect(!store.canReact(in: "chat", messageID: "1"))
    }
    @Test func uncertainReactionRequiresSuccessfulRefreshBeforeAnotherWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReactionStoreTransport(); await transport.setFailure()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: makeSession()); await store.loadConversation("chat")
        let first = Task { await store.messageAction("like", chatID: "chat", messageID: "1") }
        while await transport.writes == 0 { await Task.yield() }
        await transport.release(); await first.value
        #expect(!store.canReact(in: "chat", messageID: "1"))
        await store.messageAction("heart", chatID: "chat", messageID: "1")
        #expect(await transport.writes == 1)
        await store.refreshConversation("chat")
        #expect(store.canReact(in: "chat", messageID: "1"))
    }
    @Test func deletedMessagesCannotBeReactedTo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReactionStoreTransport(); await transport.setDeleted()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: makeSession()); await store.loadConversation("chat")
        #expect(!store.canReact(in: "chat", messageID: "1"))
        await store.messageAction("like", chatID: "chat", messageID: "1")
        #expect(await transport.writes == 0)
    }
}

private actor PagedReactionTransport: HTTPTransport {
    enum Outcome { case success, uncertain, throttle, missing }
    let outcome: Outcome
    private(set) var writes = 0
    private(set) var requestedCursors: [String] = []
    private var applied = false
    init(_ outcome: Outcome) { self.outcome = outcome }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        var status = 200
        var headers: [String: String] = [:]
        if request.httpMethod == "PUT" || request.httpMethod == "DELETE" {
            writes += 1
            if outcome == .throttle { status = 429; headers["Retry-After"] = "300"; data = Data() }
            else {
                applied = true
                if outcome == .uncertain { throw URLError(.networkConnectionLost) }
                data = Data()
            }
        } else if request.url!.path.hasSuffix("/messages") {
            let cursor = request.value(forHTTPHeaderField: "x-ms-messageToken") ?? "first"
            requestedCursors.append(cursor)
            let message: TeamsWebMessage
            let next: String?
            if cursor == "first" {
                message = .init(id: "2", content: "Recent", messageType: "Text", version: "1"); next = "older"
            } else if cursor == "older" {
                let emotions = #"[{"key":"like","users":[{"mri":"8:orgid:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}]}]"#
                message = .init(id: applied && outcome == .missing ? "99" : "1", content: "Older", messageType: "Text", version: applied ? "2" : "1", properties: applied ? .object(["emotions": .string(emotions)]) : nil); next = applied && outcome == .missing ? nil : "older2"
            } else {
                message = .init(id: "0", content: "Oldest", messageType: "Text", version: "1"); next = nil
            }
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [message], messageToken: next))
        } else { data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")])) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

extension TeamsReactionStoreTests {
    @Test(arguments: [false, true]) func confirmsOlderReactionAndPreservesPaging(uncertain: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PagedReactionTransport(uncertain ? .uncertain : .success)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: makeSession()); await store.loadConversation("chat"); await store.loadOlderMessages("chat")
        #expect(store.canReact(in: "chat", messageID: "1"))
        await store.messageAction("like", chatID: "chat", messageID: "1")
        if uncertain {
            #expect(!store.canReact(in: "chat", messageID: "1"))
            await store.refreshConversation("chat")
        }
        #expect(store.canReact(in: "chat", messageID: "1"))
        #expect(store.messages(in: "chat").first(where: { $0.id == "1" })?.reactions.first?.key == "like")
        await store.loadOlderMessages("chat")
        #expect(await transport.requestedCursors.last == "older2")
    }
    @Test func reactionThrottleBlocksAnotherWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PagedReactionTransport(.throttle)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: makeSession()); await store.loadConversation("chat")
        await store.messageAction("like", chatID: "chat", messageID: "2")
        #expect(!store.canReact(in: "chat", messageID: "2"))
        await store.messageAction("heart", chatID: "chat", messageID: "2")
        await store.connect(session: makeSession())
        #expect(!store.canReact(in: "chat", messageID: "2"))
        #expect(await transport.writes == 1)
    }
    @Test func missingReactionTargetStaysBlockedWithExplanation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PagedReactionTransport(.missing)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: makeSession()); await store.loadConversation("chat"); await store.loadOlderMessages("chat")
        await store.messageAction("like", chatID: "chat", messageID: "1")
        #expect(!store.canReact(in: "chat", messageID: "1"))
        #expect(store.chatErrors["chat"]?.contains("Could not confirm") == true)
        #expect(store.hasOlderMessages("chat"))
    }
}

private actor MultiReactionTransport: HTTPTransport {
    private(set) var reactions: Set<String> = ["like", "skull"]
    private(set) var writes: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.httpMethod == "PUT" || request.httpMethod == "DELETE" {
            writes.append(request)
            let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: request.httpBody!)
            if case let .object(fields)? = body["emotions"], let key = fields["key"]?.stringValue {
                if request.httpMethod == "DELETE" { reactions.remove(key) } else { reactions.insert(key) }
            }
            data = Data()
        } else if request.url!.path.hasSuffix("/messages") {
            let items = reactions.sorted().map { key in ["key": key, "users": [["mri": "8:orgid:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"]]] as [String: Any] }
            let json = try JSONSerialization.data(withJSONObject: items)
            let message = TeamsWebMessage(id: "1", content: "Hello", messageType: "Text", version: String(writes.count + 1), properties: .object(["emotions": .string(String(decoding: json, as: UTF8.self))]))
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [message]))
        } else { data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")])) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension TeamsReactionStoreTests {
    @Test func addingAndRemovingPreservesOtherSelectedReactions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = MultiReactionTransport()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: makeSession()); await store.loadConversation("chat")
        await store.messageAction("heart", chatID: "chat", messageID: "1")
        #expect(Set(store.messages(in: "chat")[0].reactions.map(\.key)) == ["like", "skull", "heart"])
        await store.messageAction("remove:like", chatID: "chat", messageID: "1")
        #expect(Set(store.messages(in: "chat")[0].reactions.map(\.key)) == ["skull", "heart"])
        let writes = await transport.writes
        #expect(writes.count == 2)
        #expect(writes[0].url?.query == "name=emotions")
        #expect(writes[1].httpMethod == "DELETE")
    }
}

@MainActor struct TeamsConversationFolderTests {
    @Test func completeSnapshotPersistsAndPartialDoesNotEraseIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = TeamsConversationFolder(id: "a", name: "First", folderType: "UserCreated", sortType: "UserDefinedCustomOrder", conversationFolderItems: [.init(conversationId: "older"), .init(conversationId: "recent")])
        let b = TeamsConversationFolder(id: "b", name: "Favorites", folderType: "Favorites", conversationFolderItems: [.init(conversationId: "recent")])
        let complete = TeamsConversationFolders(conversationFolders: [a, b], conversationFolderOrder: ["b", "a"], isPartialResponse: false)
        let partial = TeamsConversationFolders(conversationFolders: [a], conversationFolderOrder: ["a"], isPartialResponse: true)
        let transport = ReadFixtureTransport(try [.init(data: JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "recent")]))),
                                                   .init(data: JSONEncoder().encode(complete)), .init(data: JSONEncoder().encode(partial))])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test")
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        await store.refreshConversationFolders()
        #expect(store.conversationFolders?.orderedChatFolders.map(\.id) == ["b", "a"])
        #expect(store.conversationFolders?.orderedChatFolders.last?.conversationFolderItems.map(\.conversationId) == ["older", "recent"])
        let mixed = TeamsConversationFolder(id: "mixed", folderType: "UserCreated", conversationFolderItems: [.init(conversationId: "one"), .init(conversationId: "slice", itemType: "Slice"), .init(conversationId: "future", itemType: "FutureType"), .init(conversationId: "one")])
        #expect(mixed.chatIDs == ["one"])
        await store.refreshConversationFolders()
        #expect(store.conversationFolders == complete)
        #expect(store.foldersWarning != nil)
        let requests = await transport.requests
        #expect(requests[1].httpMethod == "GET")
        #expect(requests[1].url?.path.hasSuffix("/api/v1/teams/users/me/conversationFolders") == true)
        #expect(requests[1].url?.query == "supportsAdditionalSystemGeneratedFolders=true&supportsSliceItems=true")
        let restored = TeamsReaderStore(cacheRoot: root, transport: transport)
        await restored.restoreAccount(accountID: "account", tenantID: "tenant", displayName: "Test")
        #expect(restored.conversationFolders == complete)
        await restored.restoreAccount(accountID: "other", tenantID: "tenant", displayName: "Other")
        #expect(restored.conversationFolders == nil)
    }

    @Test func folderErrorsRespectSessionAndBackoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let complete = TeamsConversationFolders(conversationFolders: [.init(id: "a", folderType: "Favorites")], conversationFolderOrder: ["a"], isPartialResponse: false)
        let transport = ReadFixtureTransport(try [.init(data: JSONEncoder().encode(TeamsWebChatPage(items: []))),
            .init(data: JSONEncoder().encode(complete)), .init(data: Data(), status: 429, headers: ["Retry-After": "60"]),
            .init(data: Data(), status: 401)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test")
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        await store.refreshConversationFolders()
        await store.refreshConversationFolders()
        await store.refreshConversationFolders()
        #expect(await transport.requests.count == 3)
        #expect(store.conversationFolders == complete)
        let unauthorized = TeamsReaderStore(cacheRoot: root, transport: ReadFixtureTransport(try [.init(data: JSONEncoder().encode(TeamsWebChatPage(items: []))), .init(data: Data(), status: 401)]))
        await unauthorized.connect(session: session)
        await unauthorized.refreshConversationFolders()
        #expect(unauthorized.sessionExpired)
        #expect(!unauthorized.connected)
        #expect(unauthorized.conversationFolders == complete)
    }
}

private actor DelayedReadActionTransport: HTTPTransport {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var puts = 0
    private(set) var stateReads = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.httpMethod == "PUT" {
            puts += 1
            let ready = waiters.filter { $0.0 <= puts }; waiters.removeAll { $0.0 <= puts }
            ready.forEach { $0.1.resume() }
            await withCheckedContinuation { pending.append($0) }
            data = Data()
        } else if request.url!.path.hasSuffix("/conversations/chat") {
            stateReads += 1
            data = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1;1;0","consumptionHorizonBookmark":"1;1;0"}}"#.utf8)
        } else if request.url!.path.hasSuffix("/messages") {
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        } else { data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")])) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func waitForPuts(_ count: Int) async { if puts < count { await withCheckedContinuation { waiters.append((count, $0)) } } }
    func releaseFirst() { if !pending.isEmpty { pending.removeFirst().resume() } }
}

private actor DelayedContextPageTransport: HTTPTransport {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var waiting = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.url!.path.hasSuffix("/100") {
            data = Data(#"{"messages":[{"id":"100","content":"Original"}],"_metadata":{"backwardLink":"https://example.invalid/epochTimeStamp/90"}}"#.utf8)
        } else if request.url!.path.hasSuffix("/90") {
            waiting = true; started?.resume(); started = nil
            await withCheckedContinuation { pending = $0 }
            data = Data(#"{"messages":[{"id":"90","content":"Late"}]}"#.utf8)
        } else { data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")])) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func waitForRequest() async { if !waiting { await withCheckedContinuation { started = $0 } } }
    func release() { pending?.resume(); pending = nil }
}

private actor DelayedContextTransport: HTTPTransport {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var waiting = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: Data
        if request.url!.path.contains("epochTimeStamp") {
            waiting = true; started?.resume(); started = nil
            await withCheckedContinuation { pending = $0 }
            body = Data(#"{"messages":[{"id":"100","content":"Older"}]}"#.utf8)
        } else { body = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")])) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func waitForRequest() async { if !waiting { await withCheckedContinuation { started = $0 } } }
    func release() { pending?.resume(); pending = nil }
}

private actor ContextReactionTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var failRead = false
    private var failWrite = false
    func setFailRead() { failRead = true }
    func setFailWrite() { failWrite = true }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        let body: Data
        if request.httpMethod == "POST" {
            return (Data(#"{"OriginalArrivalTime":1793420000123}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: ["Location": "/messages/200"])!)
        }
        if request.httpMethod == "PUT", failWrite { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!) }
        if path.hasSuffix("/messages/100"), failRead { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!) }
        if request.httpMethod == "PUT" { body = Data() }
        else if path.contains("epochTimeStamp") { body = Data(#"{"messages":[{"id":"100","content":"Older","messagetype":"Text"}]}"#.utf8) }
        else if path.hasSuffix("/messages/100") { body = Data(#"{"id":"100","content":"Older","messageType":"Text","from":"8:orgid:other","originalArrivalTime":"1793420000123","properties":{"emotions":"[{\"key\":\"like\",\"users\":[{\"mri\":\"8:orgid:account\"}]}]"}}"#.utf8) }
        else if path.hasSuffix("/messages") { body = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Older", messageType: "Text")], messageToken: "cursor")) }
        else { body = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")])) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor DelayedReplyTransport: HTTPTransport {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var waiting = false
    private(set) var posts = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == "POST" { posts += 1 }
        let body: Data
        if request.url!.path.hasSuffix("/messages/100") {
            waiting = true; started?.resume(); started = nil
            await withCheckedContinuation { pending = $0 }
            body = Data(#"{"id":"100","content":"Older","messageType":"Text","from":"8:orgid:other","originalArrivalTime":"1793420000123"}"#.utf8)
        } else { body = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")])) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func waitForRequest() async { if !waiting { await withCheckedContinuation { started = $0 } } }
    func release() { pending?.resume(); pending = nil }
}

private actor DelayedSearchTransport: HTTPTransport {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var waiting = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: Data
        if request.url?.host == "substrate.office.com" {
            waiting = true; started?.resume(); started = nil
            await withCheckedContinuation { pending = $0 }
            body = Data(#"{"EntitySets":[]}"#.utf8)
        } else { body = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")])) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func waitForRequest() async { if !waiting { await withCheckedContinuation { started = $0 } } }
    func release() { pending?.resume(); pending = nil }
}

private actor ThrottledSearchTransport: HTTPTransport {
    private(set) var searches = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == "substrate.office.com" {
            searches += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!)
        }
        return (try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")])), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor struct TeamsContextStoreTests {
    @Test func notificationSnapshotRequiresSuccessfulServerChatRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        let cached = TeamsWebChat(id: "chat", isRead: false, lastMessage: .init(id: "100", from: .string("other")))
        let older = TeamsWebChat(id: "chat", isRead: false, lastMessage: .init(id: "150", from: .string("other")))
        let newer = TeamsWebChat(id: "chat", isRead: false, lastMessage: .init(id: "151", from: .string("other")))
        try await cache.save(.init(chats: [cached]))
        let transport = ReadFixtureTransport([.init(data: Data(), status: 500), .init(data: try JSONEncoder().encode(TeamsWebChatPage(items: [older]))), .init(data: try JSONEncoder().encode(TeamsWebChatPage(items: [newer])))])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test")
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        #expect(store.chats.first?.lastMessage?.id == "100" && store.serverChatSnapshot == nil)
        await store.refreshChats()
        let first = try #require(store.serverChatSnapshot)
        var tracker = TeamsNotificationTracker()
        #expect(tracker.update(chats: first.chats, accountID: store.accountID, accountScope: first.accountScope).isEmpty)
        await store.refreshChats()
        let second = try #require(store.serverChatSnapshot)
        #expect(first.revision != second.revision)
        #expect(tracker.update(chats: second.chats, accountID: store.accountID, accountScope: second.accountScope).map(\.id) == ["chat"])
        store.disconnect()
        #expect(store.serverChatSnapshot == nil)
    }
    @Test func explicitFinishNeverReplaysUnknownDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        let intent = TeamsPendingReadIntent(targetHorizon: 1_800_000_000_000)
        #expect(try await cache.installPendingRead(intent, in: "chat"))
        #expect(try await cache.advancePendingRead(id: intent.id, stage: .bookmarkDispatched, in: "chat"))
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let state = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1;1;0","consumptionHorizonBookmark":"1;1;0"}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: history), .init(data: state)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.finishMarkConversationRead("chat")
        #expect(await transport.requests.filter { $0.httpMethod == "PUT" }.isEmpty)
        #expect(try await cache.pendingRead(in: "chat")?.stage == .bookmarkDispatched)
    }
    @Test(arguments: [TeamsPendingReadIntent.Stage.bookmarkAccepted, .horizonRejected], [false, true]) func explicitFinishCompletesKnownPartialAfterRestart(stage: TeamsPendingReadIntent.Stage, bookmarkChanged: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        let intent = TeamsPendingReadIntent(targetHorizon: 1_800_000_000_000, bookmarkRequired: true)
        #expect(try await cache.installPendingRead(intent, in: "chat"))
        #expect(try await cache.advancePendingRead(id: intent.id, stage: stage, in: "chat"))
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat", isRead: true)]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let before = Data((bookmarkChanged ? #"{"id":"chat","properties":{"consumptionhorizon":"1;1;0","consumptionHorizonBookmark":"9;2;0"}}"# : #"{"id":"chat","properties":{"consumptionhorizon":"1;1;0","consumptionHorizonBookmark":"0;2;0"}}"#).utf8)
        let after = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1800000000000;3;100","consumptionHorizonBookmark":"0;2;0"}}"#.utf8)
        var replies: [ReadFixtureTransport.Reply] = [.init(data: chats), .init(data: before), .init(data: history), .init(data: before)]
        if bookmarkChanged { replies.append(.init(data: Data())) }
        replies += [.init(data: Data()), .init(data: after), .init(data: chats)]
        let transport = ReadFixtureTransport(replies)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.checkReadStatus("chat")
        #expect(await transport.requests.filter { $0.httpMethod == "PUT" }.isEmpty)
        #expect(store.readStatusMessages["chat"]?.contains("Finish Mark as Read") == true)
        await store.finishMarkConversationRead("chat")
        let puts = await transport.requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.count == (bookmarkChanged ? 2 : 1))
        #expect(puts.last?.url?.query?.contains("consumptionhorizon") == true)
        if bookmarkChanged { #expect(puts.first?.url?.query?.contains("consumptionHorizonBookmark") == true) }
        #expect(try await cache.pendingRead(in: "chat") == nil)
        #expect(store.readStatusMessages["chat"] == "Read update confirmed.")
    }
    @Test func localReadValidationFailureReleasesUndispatchedMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "invalid", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let state = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1;1;0"}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: history), .init(data: state)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.markConversationRead("chat")
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        #expect(await transport.requests.filter { $0.httpMethod == "PUT" }.isEmpty)
        #expect(try await cache.pendingRead(in: "chat") == nil)
        #expect(store.chatErrors["chat"]?.contains("No update was sent") == true)
    }
    @Test func olderReadStateVersionCannotConfirmUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let before = Data(#"{"id":"chat","version":"100","properties":{"consumptionhorizon":"1;1;0"}}"#.utf8)
        let stale = Data(#"{"id":"chat","version":"99","properties":{"consumptionhorizon":"1800000000000;2;100"}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: history), .init(data: before), .init(data: Data()), .init(data: stale)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.markConversationRead("chat")
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        #expect(try await cache.pendingRead(in: "chat") != nil)
        #expect(store.chatErrors["chat"] != nil)
    }
    @Test func omittedBookmarkInCompleteStateAdvancesOnlyHorizon() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let before = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1;1;0"}}"#.utf8)
        let after = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1800000000000;2;100"}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: history), .init(data: before), .init(data: Data()), .init(data: after), .init(data: chats)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.markConversationRead("chat")
        let puts = await transport.requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.count == 1 && puts[0].url?.query?.contains("consumptionhorizon") == true)
        #expect(store.chatErrors["chat"] == nil)
    }
    @Test(arguments: [false, true], [403, 429]) func definiteReadRejectionDistinguishesPartialResult(secondStep: Bool, status: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let before = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1;1;0","consumptionHorizonBookmark":"1;1;0"}}"#.utf8)
        var replies: [ReadFixtureTransport.Reply] = [.init(data: chats), .init(data: history), .init(data: before)]
        if secondStep { replies.append(.init(data: Data())) }
        replies.append(.init(data: Data(), status: status))
        let transport = ReadFixtureTransport(replies)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.markConversationRead("chat")
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        let pending = try await cache.pendingRead(in: "chat")
        #expect(secondStep ? pending?.stage == .horizonRejected : pending == nil)
        #expect(store.chatErrors["chat"]?.contains("rejected") == true)
    }
    @Test func markReadNeverRegressesNewerServerHorizon() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let before = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1900000000000;1;0","consumptionHorizonBookmark":"1;1;0"}}"#.utf8)
        let after = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1900000000000;1;0","consumptionHorizonBookmark":"0;2;0"}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: history), .init(data: before), .init(data: Data()), .init(data: after), .init(data: chats)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.markConversationRead("chat")
        let puts = await transport.requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.count == 1 && puts[0].url?.query?.contains("consumptionHorizonBookmark") == true)
        #expect(store.chatErrors["chat"] == nil)
    }
    @Test func pendingReadOwnershipIsAtomicAcrossCacheInstances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        let b = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        let first = TeamsPendingReadIntent(targetHorizon: 10), second = TeamsPendingReadIntent(targetHorizon: 20)
        async let installedA = a.installPendingRead(first, in: "chat")
        async let installedB = b.installPendingRead(second, in: "chat")
        let results = try await (installedA, installedB)
        #expect(results.0 != results.1)
        let winner = try #require(await a.pendingRead(in: "chat"))
        let loser = winner.id == first.id ? second : first
        try await b.clearPendingRead(id: loser.id, in: "chat")
        #expect(try await a.pendingRead(in: "chat")?.id == winner.id)
        try await b.clearPendingRead(id: winner.id, in: "chat")
        #expect(try await a.pendingRead(in: "chat") == nil)
    }
    @Test func partialReadUpdateRetainsRecoveryMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let before = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1;1;0","consumptionHorizonBookmark":"1;1;0"}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: history), .init(data: before), .init(data: Data()), .init(data: Data(), status: 500)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.markConversationRead("chat")
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        #expect(await transport.requests.filter { $0.httpMethod == "PUT" }.count == 2)
        #expect(try await cache.pendingRead(in: "chat") != nil)
        #expect(store.chatErrors["chat"] != nil)
    }
    @Test func missingReadStateNeverWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let missing = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1;1;0","consumptionHorizonBookmark":true}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: history), .init(data: missing)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.markConversationRead("chat")
        #expect(await transport.requests.filter { $0.httpMethod == "PUT" }.isEmpty)
        #expect(store.chatErrors["chat"] != nil)
    }
    @Test(arguments: [false, true]) func uncertainReadSurvivesRestartAndNeverReplays(confirmed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let before = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1;1;0","consumptionHorizonBookmark":"1;1;0"}}"#.utf8)
        let after = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1800000000000;2;100","consumptionHorizonBookmark":"0;2;0"}}"#.utf8)
        var replies: [ReadFixtureTransport.Reply] = [.init(data: chats), .init(data: history), .init(data: before), .init(data: Data(), status: 500), .init(data: chats), .init(data: history), .init(data: confirmed ? after : before)]
        if confirmed { replies.append(.init(data: chats)) }
        let transport = ReadFixtureTransport(replies)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let first = TeamsReaderStore(cacheRoot: root, transport: transport)
        await first.connect(session: session); await first.markConversationRead("chat")
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        #expect(try await cache.pendingRead(in: "chat") != nil)
        let second = TeamsReaderStore(cacheRoot: root, transport: transport)
        await second.connect(session: session); await second.markConversationRead("chat")
        #expect(await transport.requests.filter { $0.httpMethod == "PUT" }.count == 1)
        #expect((try await cache.pendingRead(in: "chat") == nil) == confirmed)
        #expect((second.chatErrors["chat"] == nil) == confirmed)
    }
    @Test func markReadClearsBookmarkAdvancesHorizonAndConfirms() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let before = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1;1;0","consumptionHorizonBookmark":"1;1;0"}}"#.utf8)
        let after = Data(#"{"id":"chat","properties":{"consumptionhorizon":"1800000000000;2;100","consumptionHorizonBookmark":"0;2;0"}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: history), .init(data: before), .init(data: Data()), .init(data: Data()), .init(data: after), .init(data: chats)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.markConversationRead("chat")
        let puts = await transport.requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.count == 2)
        #expect(puts[0].url?.query?.contains("consumptionHorizonBookmark") == true)
        #expect(puts[1].url?.query?.contains("consumptionhorizon") == true)
        let clearBody = try #require(puts[0].httpBody)
        let horizonBody = try #require(puts[1].httpBody)
        let clear = try #require(JSONSerialization.jsonObject(with: clearBody) as? [String: String])
        let horizon = try #require(JSONSerialization.jsonObject(with: horizonBody) as? [String: String])
        #expect(clear["consumptionHorizonBookmark"]?.hasPrefix("0;") == true && clear["consumptionHorizonBookmark"]?.hasSuffix(";0") == true)
        #expect(horizon["consumptionhorizon"]?.hasPrefix("1800000000000;") == true)
        #expect(store.chatErrors["chat"] == nil)
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        #expect(try await cache.pendingRead(in: "chat") == nil)
    }
    @Test func rawReadStatePreservesPresenceAndValidatesSegments() async throws {
        #expect(TeamsReadState.parse(nil) == .absent)
        #expect(TeamsReadState.parse(.null) == .absent)
        #expect(TeamsReadState.parse(.string("0;123;0")) == .known(originalArrival: 0, timestamp: 123, clientID: "0"))
        #expect(TeamsReadState.parse(.string("1;2")) == .malformed)
        #expect(TeamsReadState.parse(.string("1;2;x")) == .malformed)
        let raw = Data(#"{"id":"chat","properties":{"consumptionhorizon":"100;200;123456789012345678901234567890","consumptionHorizonBookmark":"0;300;0"}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: raw)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let state = try await TeamsReadStateClient(session: session, transport: transport).state(in: "chat")
        #expect(state.horizon == .known(originalArrival: 100, timestamp: 200, clientID: "123456789012345678901234567890"))
        #expect(state.bookmark == .known(originalArrival: 0, timestamp: 300, clientID: "0"))
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET" && request.url?.path.hasSuffix("/v1/users/ME/conversations/chat") == true)
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "msnp24Equivalent")
    }
    @Test func mergedContextUsesSequenceInsteadOfNumericID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let initial = Data(#"{"messages":[{"id":"100","content":"First","sequenceId":10}],"_metadata":{"forwardLink":"https://example.invalid/epochTimeStamp/110"}}"#.utf8)
        let later = Data(#"{"messages":[{"id":"90","content":"Second","sequenceId":20}]}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: initial), .init(data: later)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.openMessageContext(in: "chat", targetID: "100"); await store.loadContextPage(.forward)
        #expect(store.contextMessages.map(\.id) == ["100", "90"])
    }
    @Test func oldReadCompletionCannotReleaseNewOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DelayedReadActionTransport()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        let first = Task { await store.markConversationRead("chat") }
        await transport.waitForPuts(1)
        store.disconnect(); await store.connect(session: session)
        await store.checkReadStatus("chat")
        #expect(store.readStatusMessages["chat"]?.contains("in progress") == true)
        await store.markConversationRead("chat")
        #expect(await transport.stateReads == 1)
        #expect(await transport.puts == 1)
        await transport.releaseFirst(); await first.value
        await store.checkReadStatus("chat")
        #expect(await transport.puts == 1)
        #expect(store.readStatusMessages["chat"]?.contains("partly complete") == true)
    }
    @Test func markReadDoesNotWriteDuringGlobalCooldown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "100", content: "Fixture", originalArrivalTime: "1800000000000")]))
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: history), .init(data: Data(), status: 429, headers: ["Retry-After": "60"])])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.loadConversation("chat"); await store.refreshChats()
        await store.markConversationRead("chat")
        #expect(await transport.requests.filter { $0.httpMethod == "PUT" }.isEmpty)
    }
    @Test func failedContextPageKeepsMessagesAndRetryCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let initial = Data(#"{"messages":[{"id":"100","content":"Original"}],"_metadata":{"backwardLink":"https://example.invalid/epochTimeStamp/90"}}"#.utf8)
        let earlier = Data(#"{"messages":[{"id":"90","content":"Earlier"}]}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: initial), .init(data: Data(), status: 500), .init(data: earlier)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.openMessageContext(in: "chat", targetID: "100")
        await store.loadContextPage(.backward)
        #expect(store.contextMessages.map(\.id) == ["100"] && store.contextBackwardToken == "90" && store.contextBackwardError != nil)
        await store.loadContextPage(.backward)
        #expect(store.contextMessages.map(\.id) == ["90", "100"] && store.contextBackwardError == nil)
    }
    @Test(arguments: [false, true]) func delayedContextPageCannotCrossCloseOrRenewal(renew: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DelayedContextPageTransport()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.openMessageContext(in: "chat", targetID: "100")
        let task = Task { await store.loadContextPage(.backward) }
        await transport.waitForRequest()
        if renew { await store.connect(session: session); #expect(store.contextBackwardError != nil) }
        else { store.closeMessageContext() }
        await transport.release(); await task.value
        #expect(!store.contextBackwardLoading)
        #expect(store.contextMessages.map(\.id) == (renew ? ["100"] : []))
    }
    @Test func contextPagesMergeVersionsAndStopRepeatedCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let initial = Data(#"{"messages":[{"id":"100","content":"Old","version":"1","sequenceId":100}],"_metadata":{"backwardLink":"https://example.invalid/epochTimeStamp/90","forwardLink":"https://example.invalid/epochTimeStamp/110"}}"#.utf8)
        let earlier = Data(#"{"messages":[{"id":"90","content":"Earlier","version":"1","sequenceId":90},{"id":"100","content":"Updated","version":"2","sequenceId":100}],"_metadata":{"backwardLink":"https://example.invalid/epochTimeStamp/90"}}"#.utf8)
        let later = Data(#"{"messages":[{"id":"100","content":"Stale","version":"1","sequenceId":100},{"id":"110","content":"Later","version":"1","sequenceId":110}],"_metadata":{"forwardLink":"https://example.invalid/epochTimeStamp/120"}}"#.utf8)
        let empty = Data(#"{"messages":[],"_metadata":{"forwardLink":"https://example.invalid/epochTimeStamp/130"}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: initial), .init(data: earlier), .init(data: later), .init(data: empty)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.openMessageContext(in: "chat", targetID: "100")
        await store.loadContextPage(.backward)
        #expect(store.contextMessages.map(\.id) == ["90", "100"])
        #expect(store.contextBackwardToken == nil && store.contextForwardToken == "110")
        await store.loadContextPage(.forward)
        #expect(store.contextMessages.map(\.id) == ["90", "100", "110"])
        #expect(store.contextMessages.first { $0.id == "100" }?.body.text == "Updated")
        await store.loadContextPage(.forward)
        #expect(store.contextForwardToken == nil && store.contextMessages.count == 3)
    }
    @Test func searchThrottleBlocksImmediateRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ThrottledSearchTransport()
        let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Test", searchSession: .init(accessToken: "search", expiresAt: .distantFuture, accountID: account, tenantID: tenant))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        for _ in 0..<2 { do { _ = try await store.searchServer("fixture", in: "chat"); Issue.record("Expected throttle") } catch { } }
        #expect(await transport.searches == 1)
        #expect(store.searchCoolingDown)
        store.disconnect(); await store.connect(session: session)
        #expect(store.searchCoolingDown)
    }
    @Test(arguments: [false, true]) func delayedSearchCannotCrossDisconnectOrTenantChange(changeTenant: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DelayedSearchTransport()
        let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Test", searchSession: .init(accessToken: "search", expiresAt: .distantFuture, accountID: account, tenantID: tenant))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        let task = Task { try await store.searchServer("fixture", in: "chat") }
        await transport.waitForRequest()
        if changeTenant { await store.restoreAccount(accountID: account, tenantID: "cccccccc-cccc-cccc-cccc-cccccccccccc", displayName: "Test") }
        else { store.disconnect() }
        await transport.release()
        do { _ = try await task.value; Issue.record("Stale search was returned") } catch { #expect(error is CancellationError) }
    }
    @Test func contextIsSeparateAndMissingPivotIsExplicit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")]))
        let history = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: "200", content: "Latest")], messageToken: "older-cursor"))
        let page = Data(#"{"messages":[{"id":"100","content":"Older","sequenceId":1}],"_metadata":{"backwardLink":"https://example.invalid/epochTimeStamp/90","forwardLink":"https://example.invalid/epochTimeStamp/110"}}"#.utf8)
        let missing = Data(#"{"messages":[{"id":"99","content":"Other"}],"_metadata":{}}"#.utf8)
        let transport = ReadFixtureTransport([.init(data: chats), .init(data: history), .init(data: page), .init(data: missing)])
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.loadConversation("chat")
        await store.openMessageContext(in: "chat", targetID: "100")
        #expect(store.contextMessages.map(\.id) == ["100"])
        #expect(store.messages(in: "chat").map(\.id) == ["200"])
        #expect(store.hasOlderMessages("chat"))
        #expect(store.contextBackwardToken == "90" && store.contextForwardToken == "110")
        await store.openMessageContext(in: "chat", targetID: "101")
        #expect(store.contextMessages.isEmpty && store.contextError != nil)
        store.closeMessageContext()
        #expect(store.contextTargetID == nil && store.messages(in: "chat").map(\.id) == ["200"])
    }
    @Test func closingContextDiscardsLateResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DelayedContextTransport()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        let task = Task { await store.openMessageContext(in: "chat", targetID: "100") }
        await transport.waitForRequest()
        store.closeMessageContext()
        await transport.release(); await task.value
        #expect(store.contextTargetID == nil && store.contextMessages.isEmpty && !store.contextLoading)
    }
    @Test func renewalEndsPendingContextWithRetryState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DelayedContextTransport()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        let task = Task { await store.openMessageContext(in: "chat", targetID: "100") }
        await transport.waitForRequest(); await store.connect(session: session)
        #expect(!store.contextLoading && store.contextTargetID == "100" && store.contextError != nil)
        await transport.release(); await task.value
        #expect(store.contextMessages.isEmpty && store.contextError != nil)
    }
    @Test func contextReactionUsesTargetedReadWithoutMergingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ContextReactionTransport()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.openMessageContext(in: "chat", targetID: "100")
        let oldScope = store.contextRevision
        await store.openMessageContext(in: "chat", targetID: "100")
        await store.messageAction("like", chatID: "chat", messageID: "100", contextScope: oldScope)
        #expect(await transport.requests.filter { $0.httpMethod == "PUT" }.isEmpty)
        await store.messageAction("like", chatID: "chat", messageID: "100")
        #expect(store.contextMessages.first?.reactions.first?.key == "like")
        #expect(!store.reactionNeedsConfirmation(in: "chat", messageID: "100"))
        #expect(store.messages(in: "chat").isEmpty)
        let requests = await transport.requests
        #expect(requests.filter { $0.httpMethod == "PUT" }.count == 1)
        #expect(requests.last?.url?.path.hasSuffix("/api/v1/chats/chat/messages/100") == true)
    }
    @Test func sharedContextReactionUpdatesBothAndUncertainReadStaysBlocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ContextReactionTransport()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.loadConversation("chat"); await store.openMessageContext(in: "chat", targetID: "100")
        await store.messageAction("like", chatID: "chat", messageID: "100")
        #expect(store.contextMessages.first?.reactions.first?.key == "like")
        #expect(store.messages(in: "chat").first?.reactions.first?.key == "like")
        #expect(store.hasOlderMessages("chat"))
        await transport.setFailRead()
        await store.messageAction("remove:like", chatID: "chat", messageID: "100")
        #expect(store.reactionNeedsConfirmation(in: "chat", messageID: "100"))
        #expect(!store.canReact(in: "chat", messageID: "100"))
        #expect(store.contextActionError != nil)
    }
    @Test func contextReplyResolvesTargetAfterContextCloses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ContextReactionTransport()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.openMessageContext(in: "chat", targetID: "100")
        store.composer.setReply(.init(messageID: "100", preview: "Older", author: "Other"), in: "chat")
        store.composer.setDraft("Reply", in: "chat"); store.closeMessageContext()
        let sent = await store.sendDraft(in: "chat")
        #expect(sent == "200")
        let requests = await transport.requests
        #expect(requests.contains { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/api/v1/chats/chat/messages/100") == true })
        let post = try #require(requests.first { $0.httpMethod == "POST" })
        let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: #require(post.httpBody))
        #expect(body["messagetype"] == .string("RichText/Html"))
    }
    @Test func contextReactionWriteFailureIsVisibleAndUncertain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ContextReactionTransport(); await transport.setFailWrite()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session); await store.openMessageContext(in: "chat", targetID: "100")
        await store.messageAction("like", chatID: "chat", messageID: "100")
        #expect(store.contextActionError != nil)
        #expect(store.reactionNeedsConfirmation(in: "chat", messageID: "100"))
        #expect(!store.canReact(in: "chat", messageID: "100"))
    }
    @Test func editingOrCancellingDuringReplyLookupNeverSendsNewDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DelayedReplyTransport()
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session)
        store.composer.setReply(.init(messageID: "100", preview: "Older", author: "Other"), in: "chat")
        store.composer.setDraft("Original", in: "chat")
        let pending = Task { await store.sendDraft(in: "chat") }
        await transport.waitForRequest()
        #expect(!store.composer.canSend(in: "chat"))
        store.composer.setDraft("Newer unsent text", in: "chat")
        #expect(await store.sendDraft(in: "chat") == nil)
        store.composer.setReply(nil, in: "chat")
        await transport.release(); #expect(await pending.value == nil)
        #expect(await transport.posts == 0)
        #expect(store.composer.draft(in: "chat") == "Newer unsent text")
    }
}
