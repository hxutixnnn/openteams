import Foundation
import Testing
@testable import TeamsCore

private actor TeamsWebStubTransport: HTTPTransport {
    struct Reply: Sendable {
        let status: Int
        let body: String
        var headers: [String: String] = [:]
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private let failure: URLError?

    init(_ replies: [Reply] = [], failure: URLError? = nil) {
        self.replies = replies
        self.failure = failure
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        return (Data(reply.body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/2", headerFields: reply.headers
        )!)
    }
}

struct TeamsWebClientTests {
    private func session(
        url: String = "https://teams.cloud.microsoft/api/csa/amer", token: String = "test-csa-token",
        expiry: Date = Date().addingTimeInterval(3_600), account: String = "test-account", tenant: String = "test-tenant"
    ) -> TeamsWebSession {
        TeamsWebSession(
            baseURL: URL(string: url)!, accessToken: token, expiresAt: expiry,
            accountID: account, tenantID: tenant, displayName: "Demo User"
        )
    }

    @Test func groupPictureMetadataDistinguishesAbsentRemovalAndReplacement() async throws {
        let decoder = JSONDecoder()
        let missing = try decoder.decode(TeamsWebChat.self, from: Data(#"{"id":"chat"}"#.utf8))
        let present = try decoder.decode(TeamsWebChat.self, from: Data(#"{"id":"chat","picture":"v1@doc","threadVersion":7}"#.utf8))
        let removed = try decoder.decode(TeamsWebChat.self, from: Data(#"{"id":"chat","picture":null}"#.utf8))
        let malformed = try decoder.decode(TeamsWebChat.self, from: Data(#"{"id":"chat","picture":{"url":"not-a-string"}}"#.utf8))
        #expect(!missing.pictureMetadataPresent && present.pictureMetadataPresent && present.threadVersion == "7")
        #expect(removed.pictureMetadataPresent && removed.picture == nil && !malformed.pictureMetadataPresent)
        #expect(missing.retainingPicture(from: present).picture == "v1@doc")
        #expect(removed.retainingPicture(from: present).picture == nil)
        let restored = try decoder.decode(TeamsWebChat.self, from: JSONEncoder().encode(removed))
        #expect(restored.pictureMetadataPresent && restored.picture == nil)
        let transport = TeamsWebStubTransport([.init(status: 200, body: #"{"id":"chat","picture":"v2@doc","threadVersion":8}"#)])
        let metadata = try await TeamsWebClient(session: session(), transport: transport).knownChat("chat")
        #expect(metadata.picture == "v2@doc" && metadata.pictureMetadataPresent && metadata.threadVersion == "8")
    }

    @Test func singleMessageRequiresNumericIDAndMatchingResponse() async throws {
        let transport = TeamsWebStubTransport([.init(status: 200, body: #"{"id":"1234567890123456789","content":"Example","version":123,"properties":{}}"#), .init(status: 200, body: #"{"id":"999"}"#)])
        let client = TeamsWebClient(session: session(), transport: transport)
        let message = try await client.message(in: "chat/a", id: "1234567890123456789")
        #expect(message.version == "123")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://teams.cloud.microsoft/api/csa/amer/api/v1/chats/chat%2Fa/messages/1234567890123456789")
        do { _ = try await client.message(in: "chat", id: "../1"); Issue.record("Expected invalid ID") } catch { #expect(error as? TeamsWebClientError == .invalidMessageID) }
        do { _ = try await client.message(in: "chat", id: "123"); Issue.record("Expected mismatched response") } catch { #expect(error as? TeamsWebClientError == .invalidResponse) }
        #expect(await transport.requests.count == 2)
    }

    @Test func contextReadKeepsDirectionalTokensAsData() async throws {
        let transport = TeamsWebStubTransport([.init(status: 200, body: #"{"messages":[{"id":"123","content":"Example","messagetype":"Text","version":"7","sequenceId":42}],"_metadata":{"backwardLink":"https://untrusted.example/v1/messages/epochTimeStamp/100?ignored=1","forwardLink":"https://untrusted.example/v1/messages/epochTimeStamp/not-a-number"}}"#)])
        let contextSession = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let client = TeamsMessageContextClient(session: contextSession, transport: transport)
        let page = try await client.messages(in: "chat/a", pivot: "123")
        #expect(page.messages.first?.message.messageType == "Text")
        #expect(page.messages.first?.sequenceID == 42)
        #expect(page.backwardToken == "100")
        #expect(page.forwardToken == nil)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.host == "teams.cloud.microsoft")
        #expect(request.url?.absoluteString.contains("chat%2Fa/messages/epochTimeStamp/123?pageSize=20&direction=BIDIRECTIONAL&includeMetadata=true&locationType=Primary") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ic3")
        do { _ = try await client.messages(in: "chat", pivot: "../1"); Issue.record("Expected invalid pivot") } catch { #expect(error as? TeamsWebClientError == .invalidMessageID) }
        #expect(await transport.requests.count == 1)
    }

    @Test func contextRejectsInvalidIDsAndDeduplicatesByVersion() async throws {
        let transport = TeamsWebStubTransport([
            .init(status: 200, body: #"{"messages":[{"id":"12","version":"2","content":"new","sequenceId":2},{"id":"11","version":"1","sequenceId":1},{"id":"12","version":"1","content":"old","sequenceId":2}]}"#),
            .init(status: 200, body: #"{"messages":[{"id":""}]}"#)
        ])
        let contextSession = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        let client = TeamsMessageContextClient(session: contextSession, transport: transport)
        let page = try await client.messages(in: "chat", pivot: "12")
        #expect(page.messages.map(\.message.id) == ["11", "12"])
        #expect(page.messages.last?.message.content == "new")
        do { _ = try await client.messages(in: "chat", pivot: "12"); Issue.record("Expected invalid response") } catch { #expect(error as? TeamsWebClientError == .invalidResponse) }
    }

    @Test func usesProvenCSAReadContractWithoutCookiesOrWrites() async throws {
        let transport = TeamsWebStubTransport([
            .init(status: 200, body: #"{"items":[{"id":"chat-1","title":"Demo"}]}"#),
            .init(status: 200, body: #"{"messages":[{"id":"message-1","content":"Hello"}]}"#)
        ])
        let client = TeamsWebClient(session: session(), transport: transport)
        let chats = try await client.chats(pageSize: 5)
        let messages = try await client.messages(in: "chat-1", pageSize: 5)
        #expect(chats.items.first?.id == "chat-1")
        #expect(messages.messages.first?.content == "Hello")
        let requests = await transport.requests
        #expect(requests.map(\.url?.absoluteString) == [
            "https://teams.cloud.microsoft/api/csa/amer/api/v2/teams/users/me/chats?pageSize=5",
            "https://teams.cloud.microsoft/api/csa/amer/api/v1/chats/chat-1/messages?messagePageSize=5"
        ])
        for request in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(!request.httpShouldHandleCookies)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-csa-token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        }
    }

    @Test func paginationPreservesOpaqueTokensAndDoesNotFetchAutomatically() async throws {
        let cursor = "https://other.invalid/?a=b+c/d==&x=# %雪"
        let transport = TeamsWebStubTransport([
            .init(status: 200, body: String(data: try JSONEncoder().encode(
                TeamsWebChatPage(items: [.init(id: "first")], continuationToken: cursor)
            ), encoding: .utf8)!),
            .init(status: 200, body: #"{"items":[{"id":"second"}],"continuationToken":null}"#)
        ])
        let client = TeamsWebClient(session: session(url: "https://teams.cloud.microsoft/api/csa/amer/"), transport: transport)
        let first = try await client.chats()
        #expect(await transport.requests.count == 1)
        let second = try await client.chats(continuationToken: first.continuationToken)
        #expect(second.items.first?.id == "second")
        #expect(second.continuationToken == nil)
        let request = try #require(await transport.requests.last)
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(url.host == "teams.cloud.microsoft")
        #expect(query?.first { $0.name == "continuationToken" }?.value == cursor)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery?.contains("b%2Bc") == true)
        #expect(await transport.requests.count == 2)
    }

    @Test func historyUsesHeaderCursorAndEncodesTheWholeChatID() async throws {
        let transport = TeamsWebStubTransport([
            .init(status: 200, body: #"{"messageToken":"opaque+/=&token","messages":[]}"#),
            .init(status: 200, body: #"{"messages":[]}"#)
        ])
        let client = TeamsWebClient(session: session(), transport: transport)
        let id = "19:abc/def+ghi@thread.v2?x=1#%"
        let first = try await client.messages(in: id)
        _ = try await client.messages(in: id, messageToken: first.messageToken)
        let request = try #require(await transport.requests.last)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/api/csa/amer/api/v1/chats/19%3Aabc%2Fdef%2Bghi%40thread.v2%3Fx%3D1%23%25/messages")
        #expect(components.queryItems?.map(\.name) == ["messagePageSize"])
        #expect(request.value(forHTTPHeaderField: "x-ms-messageToken") == "opaque+/=&token")
    }

    @Test func rejectsInvalidServiceBoundariesBeforeTransport() async throws {
        let transport = TeamsWebStubTransport()
        for url in [
            "http://teams.cloud.microsoft/api/csa/amer",
            "https://teams.cloud.microsoft.attacker.invalid/api/csa/amer",
            "https://user@teams.cloud.microsoft/api/csa/amer",
            "https://user:password@teams.cloud.microsoft/api/csa/amer",
            "https://teams.cloud.microsoft:443/api/csa/amer",
            "https://teams.cloud.microsoft:444/api/csa/amer",
            "https://teams.cloud.microsoft/api/csa/amer?x=1",
            "https://teams.cloud.microsoft/api/csa/amer#fragment",
            "https://teams.cloud.microsoft/api/csa/amer/api/v1",
            "https://teams.cloud.microsoft/api/csa/%61mer",
            "https://teams.cloud.microsoft/api/csa/amer%2Fother",
            "https://teams.cloud.microsoft/api/csa/../amer",
            "https://teams.cloud.microsoft/api//csa/amer",
            "https://teams.cloud.microsoft/api/csa/"
        ] {
            do {
                _ = try await TeamsWebClient(session: session(url: url), transport: transport).chats()
                Issue.record("Invalid service boundary was accepted")
            } catch { #expect(error as? TeamsWebClientError == .unsafeBaseURL) }
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func rejectsExpiredAndMalformedSessionsBeforeTransport() async throws {
        let transport = TeamsWebStubTransport()
        do {
            _ = try await TeamsWebClient(session: session(expiry: .distantPast), transport: transport).chats()
            Issue.record("Expired session was accepted")
        } catch { #expect(error as? TeamsWebClientError == .expiredSession) }
        for token in ["", "token\r\nInjected: value", "has space", " token"] {
            do {
                _ = try await TeamsWebClient(session: session(token: token), transport: transport).chats()
                Issue.record("Malformed bearer value was accepted")
            } catch { #expect(error as? TeamsWebClientError == .invalidSession) }
        }
        for invalid in [session(account: ""), session(account: " \n"), session(tenant: ""), session(tenant: "\t")] {
            do {
                _ = try await TeamsWebClient(session: invalid, transport: transport).chats()
                Issue.record("Session without cache identity was accepted")
            } catch { #expect(error as? TeamsWebClientError == .invalidSession) }
        }
        let boundary = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throws: TeamsWebClientError.expiredSession) {
            try session(expiry: boundary).validate(at: boundary)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func rejectsInvalidReadParametersBeforeTransport() async throws {
        let transport = TeamsWebStubTransport()
        let client = TeamsWebClient(session: session(), transport: transport)
        for size in [0, -1, 201] {
            do {
                _ = try await client.chats(pageSize: size)
                Issue.record("Invalid page size was accepted")
            } catch { #expect(error as? TeamsWebClientError == .invalidPageSize) }
        }
        for id in ["", ".", ".."] {
            do {
                _ = try await client.messages(in: id)
                Issue.record("Invalid chat ID was accepted")
            } catch { #expect(error as? TeamsWebClientError == .invalidChatID) }
        }
        do {
            _ = try await client.messages(in: "chat", messageToken: "token\r\nInjected: value")
            Issue.record("Header injection was accepted")
        } catch { #expect(error as? TeamsWebClientError == .invalidPaginationToken) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func httpFailuresHaveSafeTypedMessagesAndAreNotRetried() async throws {
        for status in [401, 403, 429, 503, 302] {
            let transport = TeamsWebStubTransport([
                .init(status: status, body: "server-secret-do-not-display", headers: ["Retry-After": "8"])
            ])
            do {
                _ = try await TeamsWebClient(session: session(), transport: transport).chats()
                Issue.record("HTTP failure was accepted")
            } catch {
                #expect(error as? TeamsWebClientError == .http(status: status, retryAfter: 8))
                #expect(!error.localizedDescription.contains("server-secret"))
                #expect(!error.localizedDescription.contains("test-csa-token"))
            }
            #expect(await transport.requests.count == 1)
        }
    }

    @Test func retryAfterAcceptsHTTPDatesAndIgnoresInvalidDelays() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let transport = TeamsWebStubTransport([
            .init(status: 429, body: "", headers: ["Retry-After": formatter.string(from: Date().addingTimeInterval(120))])
        ])
        do {
            _ = try await TeamsWebClient(session: session(), transport: transport).chats()
            Issue.record("Throttle was accepted")
        } catch let error as TeamsWebClientError {
            guard case let .http(status, delay) = error else { Issue.record("Unexpected error"); return }
            #expect(status == 429)
            let seconds = try #require(delay)
            #expect((115...121).contains(seconds))
        }
        for header in ["-3", "garbage", "1e300"] {
            let failed = TeamsWebStubTransport([.init(status: 429, body: "", headers: ["Retry-After": header])])
            do {
                _ = try await TeamsWebClient(session: session(), transport: failed).chats()
                Issue.record("Throttle was accepted")
            } catch { #expect(error as? TeamsWebClientError == .http(status: 429, retryAfter: nil)) }
        }
    }

    @Test func richMessageShapesAndNumericScalarsSurviveCacheRoundTrip() throws {
        let data = Data(#"{"messages":[{"id":9007199254740993,"content":"<p>Xin chào 👋</p>","contentType":"html","messageType":"RichText/Html","imDisplayName":"Demo","from":{"mri":"8:orgid:demo"},"originalArrivalTime":1793420000123,"composeTime":"2026-10-31T07:00:00Z","version":42,"properties":{"cards":"[{\"type\":\"AdaptiveCard\"}]","nested":[true,null,{"n":9007199254740993}]}}],"messageToken":"next"}"#.utf8)
        let page = try JSONDecoder().decode(TeamsWebMessagePage.self, from: data)
        let message = try #require(page.messages.first)
        #expect(message.id == "9007199254740993")
        #expect(message.version == "42")
        #expect(message.originalArrivalTime == "1793420000123")
        #expect(message.senderID == "8:orgid:demo")
        #expect(message.arrivalDate == Date(timeIntervalSince1970: 1_793_420_000.123))
        #expect(message.content == "<p>Xin chào 👋</p>")
        let encoded = try JSONEncoder().encode(page)
        #expect(try JSONDecoder().decode(TeamsWebMessagePage.self, from: encoded) == page)
        let propertyData = Data("9007199254740993".utf8)
        #expect(try JSONDecoder().decode(TeamsWebJSONValue.self, from: propertyData) == .number(Decimal(string: "9007199254740993")!))
    }

    @Test func publicChatModelsCanBeCachedAndUseMemberTitleFallback() throws {
        let chat = TeamsWebChat(
            id: "demo", title: " ", chatType: "group", isRead: false,
            members: [.init(mri: "8:demo", objectId: "demo", displayName: "Demo User")],
            lastMessage: .init(id: "last", content: "Hello", from: .string("8:demo"))
        )
        #expect(chat.displayTitle == "Demo User")
        let page = TeamsWebChatPage(items: [chat], continuationToken: "cursor")
        #expect(try JSONDecoder().decode(TeamsWebChatPage.self, from: JSONEncoder().encode(page)) == page)
        let composed = TeamsWebMessage(id: "system", originalArrivalTime: "invalid", composeTime: "2026-10-31T07:00:00Z")
        #expect(composed.arrivalDate == ISO8601DateFormatter().date(from: "2026-10-31T07:00:00Z"))
        #expect(TeamsWebMessage(id: "1793420000123").arrivalDate == Date(timeIntervalSince1970: 1_793_420_000.123))
        #expect(TeamsWebMessage(id: "42").arrivalDate == nil)
        #expect(TeamsWebMessage(id: "9007199254740993").arrivalDate == nil)
    }

    @Test func malformedSuccessIsNotPresentedAsAnEmptyPage() async throws {
        for body in [#"{"unexpected":true}"#, #"{"items":"wrong"}"#] {
            let transport = TeamsWebStubTransport([.init(status: 200, body: body)])
            do {
                _ = try await TeamsWebClient(session: session(), transport: transport).chats()
                Issue.record("Malformed response was accepted")
            } catch { #expect(error as? TeamsWebClientError == .invalidResponse) }
        }
        let transport = TeamsWebStubTransport([.init(status: 200, body: #"{"messages":[{"content":"missing id"}]}"#)])
        do {
            _ = try await TeamsWebClient(session: session(), transport: transport).messages(in: "chat")
            Issue.record("Message without identity was accepted")
        } catch { #expect(error as? TeamsWebClientError == .invalidResponse) }
    }

    @Test func arrivalDatesPreserveFallbacksAndCacheRepresentation() throws {
        let cases: [(id: String, original: String?, compose: String?, expected: Date?)] = [
            ("1", "2026-10-31T07:00:00.123Z", nil, Date(timeIntervalSince1970: 1_793_430_000.123)),
            ("2", "invalid", "2026-10-31T14:00:00+07:00", Date(timeIntervalSince1970: 1_793_430_000)),
            ("3", "1793430000", nil, Date(timeIntervalSince1970: 1_793_430_000)),
            ("4", "1793430000123", nil, Date(timeIntervalSince1970: 1_793_430_000.123)),
            ("1793430000123", nil, nil, Date(timeIntervalSince1970: 1_793_430_000.123)),
            ("6", "invalid", "invalid", nil),
            ("9007199254740993", nil, nil, nil)
        ]
        for value in cases {
            let message = TeamsWebMessage(id: value.id, originalArrivalTime: value.original, composeTime: value.compose)
            #expect(message.arrivalDate == value.expected)
            let encoded = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(TeamsWebMessage.self, from: encoded)
            #expect(decoded == message && decoded.arrivalDate == value.expected)
            let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(Set(fields.keys).isSubset(of: ["id", "originalArrivalTime", "composeTime"]))
        }
    }

    @Test func sessionDiagnosticsNeverExposeBearerValue() {
        let value = session(token: "sensitive-test-token")
        var output = ""
        dump(value, to: &output)
        #expect(!String(describing: value).contains("sensitive-test-token"))
        #expect(!String(reflecting: value).contains("sensitive-test-token"))
        #expect(!output.contains("sensitive-test-token"))
        #expect(output.contains("redacted"))
    }

    @Test func transportFailuresAreSafeAndCancellationRemainsCancellation() async throws {
        let offline = TeamsWebStubTransport(failure: URLError(.notConnectedToInternet))
        do {
            _ = try await TeamsWebClient(session: session(), transport: offline).chats()
            Issue.record("Transport failure was accepted")
        } catch { #expect(error as? TeamsWebClientError == .network) }
        let cancelled = TeamsWebStubTransport(failure: URLError(.cancelled))
        do {
            _ = try await TeamsWebClient(session: session(), transport: cancelled).chats()
            Issue.record("Cancellation was accepted")
        } catch { #expect(error is CancellationError) }
    }
}

struct TeamsFilePresentationTests {
    @Test func retainsOnlySameOriginFileMetadataWithMessageProvenance() throws {
        let files = #"[{"version":2,"id":"file-id","title":"Plan","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://example.sharepoint.com/sites/team/file.pdf"},{"version":2,"id":"other","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://evil.example/file"}]"#
        let message = TeamsWebMessage(id: "message", properties: .object(["files": .string(files)]))
        let epoch = UUID()
        let rendered = TeamsRenderedMessage(message, accountScope: "tenant:account", accountRevision: epoch, chatID: "chat")
        let attachment = try #require(rendered.files.first?.sharePoint)
        #expect(attachment.fileID == "file-id" && attachment.chatID == "chat" && attachment.messageID == "message")
        #expect(attachment.accountScope == "tenant:account" && attachment.accountRevision == epoch)
        #expect(rendered.files.last?.sharePoint == nil)
        #expect(TeamsRenderedMessage(message).files.first?.sharePoint == nil)
    }
    @Test func legacyFileIdentityUsesItemidAndFileInfoOnly() throws {
        let files = #"[{"id":"wrong","itemid":"legacy-id","fileInfo":{"siteUrl":"https://example.sharepoint.com/sites/team","fileUrl":"https://example.sharepoint.com/sites/team/file.pdf"}}]"#
        let message = TeamsWebMessage(id: "message", properties: .object(["files": .string(files)]))
        let attachment = try #require(TeamsRenderedMessage(message, accountScope: "tenant:account", accountRevision: UUID(), chatID: "chat").files.first?.sharePoint)
        #expect(attachment.fileID == "legacy-id")
    }
    @Test func fileMetadataExposesOnlySafeHTTPSLinksAndHidesDeletedAttachments() {
        let files = #"[{"title":"Plan.pdf","openUrl":"https://example.com/doc","filePreview":{"previewUrl":"https://us-api.asm.skype.com/v1/objects/example/views/imgo","previewWidth":452,"previewHeight":514}},{"title":"Duplicate","shareUrl":"https://example.com/doc"},{"title":"Unsafe","openUrl":"javascript:alert(1)"},{"title":"Password","openUrl":"https://user:pass@example.com/x"}]"#
        let message = TeamsWebMessage(id: "1", content: "File", messageType: "Text", properties: .object(["files": .string(files)]))
        let rendered = TeamsRenderedMessage(message)
        #expect(rendered.files.count == 1)
        #expect(rendered.files.first?.title == "Plan.pdf")
        #expect(rendered.files.first?.preview?.width == 452)
        #expect(rendered.files.first?.preview?.height == 514)
        let deleted = TeamsWebMessage(id: "2", properties: .object(["files": .string(files), "deletetime": .string("1")]))
        #expect(TeamsRenderedMessage(deleted).files.isEmpty)
    }
}

struct TeamsReactionPresentationTests {
    @Test func displaysVerifiedAliasesEncodedEmojiAndNamedCustomFallback() {
        #expect(TeamsReactionPresentation.symbol(for: "skull") == "💀")
        #expect(TeamsReactionPresentation.symbol(for: "laugh") == "😆")
        #expect(TeamsReactionPresentation.symbol(for: "grinningfacewithsmilingeyes") == "😄")
        #expect(TeamsReactionPresentation.symbol(for: "1f37b_clinkingbeermugs") == "🍻")
        #expect(TeamsReactionPresentation.name(for: "1f37b_clinkingbeermugs") == "Clinking Beer Mugs")
        #expect(TeamsReactionPresentation.symbol(for: "custom_fireworks") == "✦")
        #expect(TeamsReactionPresentation.name(for: "custom_fireworks") == "Custom Fireworks")
        #expect(TeamsReactionPresentation.symbol(for: "1f469_200d_1f4bb_womantechnologist") == "👩‍💻")
        #expect(TeamsReactionPresentation.symbol(for: "1f44d_000a_label") == "✦")
        #expect(TeamsReactionPresentation.symbol(for: "1f44d_202e_label") == "✦")
        #expect(TeamsReactionPresentation.symbol(for: "hello😄") == "✦")
    }
    @Test func parsesReactionUsersAndHidesDeletedReactions() {
        let raw = #"[{"key":"like","users":[{"mri":"8:orgid:a","time":1},{"mri":"8:orgid:b","time":2}]},{"key":"heart","users":[]}]"#
        let message = TeamsWebMessage(id: "1", properties: .object(["emotions": .string(raw)]))
        let reactions = TeamsRenderedMessage(message).reactions
        #expect(reactions.count == 1)
        #expect(reactions.first?.key == "like")
        #expect(reactions.first?.userIDs == ["8:orgid:a", "8:orgid:b"])
        let deleted = TeamsWebMessage(id: "2", properties: .object(["emotions": .string(raw), "deletetime": .string("1")]))
        #expect(TeamsRenderedMessage(deleted).reactions.isEmpty)
    }
}

struct TeamsKnownMemberTests {
    @Test func friendlyNameFallbackPreservesRawNamesAndClassification() throws {
        let input = #"{"id":"chat","members":[{"mri":"8:orgid:a","friendlyName":"Ada"},{"mri":"8:orgid:b","displayName":"Named","friendlyName":"Fallback"},{"mri":"8:orgid:c","displayName":"","friendlyName":"Clara"},{"mri":"8:orgid:d"},{"mri":"28:bot","friendlyName":"Agent"},{"mri":"8:orgid:e","userIdentityType":"agentic","friendlyName":"Agentic"}]}"#
        let chat = try JSONDecoder().decode(TeamsWebChat.self, from: Data(input.utf8))
        let members = try #require(chat.members)
        #expect(members[0].displayName == nil && members[0].friendlyName == "Ada" && members[0].preferredDisplayName == "Ada")
        #expect(members[1].preferredDisplayName == "Named")
        #expect(members[2].displayName == "" && members[2].preferredDisplayName == "Clara")
        #expect(members[3].displayName == nil && members[3].friendlyName == nil && members[3].preferredDisplayName == nil)
        #expect(members[4].kind == .agent && members[5].kind == .agentic)
        let restored = try JSONDecoder().decode(TeamsWebChat.self, from: JSONEncoder().encode(chat))
        #expect(restored.members == chat.members)
        let absent = try JSONDecoder().decode(TeamsWebChat.self, from: Data(#"{"id":"missing"}"#.utf8))
        let empty = try JSONDecoder().decode(TeamsWebChat.self, from: Data(#"{"id":"empty","members":[]}"#.utf8))
        #expect(absent.members == nil && empty.members == [])
    }
    @Test func cachedKnownRosterPreservesFriendlyNamesWithoutClaimingCompleteness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        let chat = TeamsWebChat(id: "chat", members: [.init(mri: "8:orgid:a", friendlyName: "Ada")])
        try await cache.save(TeamsCachedChats(chats: [chat]))
        let loaded = try await cache.chats()
        #expect(loaded.chats.first?.members?.first?.preferredDisplayName == "Ada")
        #expect(loaded.chats.first?.members?.first?.displayName == nil)
    }
}
