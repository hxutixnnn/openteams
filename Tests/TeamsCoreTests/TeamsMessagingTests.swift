import Foundation
import Testing
@testable import TeamsCore

private actor MessagingTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let status: Int
    let headers: [String: String]
    let failure: URLError?
    let hold: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(status: Int = 201, headers: [String: String] = ["Location": "/messages/9007199254740993"],
         failure: URLError? = nil, hold: Bool = false) {
        self.status = status; self.headers = headers; self.failure = failure; self.hold = hold
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        return (Data(#"{"OriginalArrivalTime":1793420000123}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
struct TeamsMessagingTests {
    private let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private func session(base: String = "https://teams.cloud.microsoft/api/chatsvc/amer",
                         account: String = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa-test-secret",
              expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Example Person",
              messaging: .init(baseURL: URL(string: base)!, accessToken: "ic3-test-secret", expiresAt: .distantFuture))
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func richReplySerializesMentionAndQuoteIndependently() async throws {
        let transport = MessagingTransport()
        let person = TeamsRichDraft.Mention(mri: "8:orgid:other", displayName: "Ánh & Co")
        let draft = TeamsRichDraft(blocks: [.init(runs: [.init(text: "Hello ", bold: true), .init(text: "Ánh & Co", mention: person)])])
        let original = TeamsWebMessage(id: "123", content: "Original", messageType: "Text", from: .string("8:orgid:" + account), originalArrivalTime: "1793420000123")
        let sent = try await TeamsMessagingClient(session: session(), transport: transport).sendText(draft.plainText, in: "chat", clientMessageID: "456", replyingTo: original, preview: "<quote>", richDraft: draft)
        let request = try #require(await transport.requests.first)
        let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: #require(request.httpBody))
        #expect(body["messagetype"] == .string("RichText/Html"))
        guard case let .string(content)? = body["content"], case let .object(properties)? = body["properties"], case let .string(mentions)? = properties["mentions"] else { Issue.record("Missing rich payload"); return }
        #expect(content.contains("&lt;quote&gt;"))
        #expect(content.contains("<strong>Hello </strong>"))
        #expect(content.contains("itemid=\"0\">Ánh &amp; Co</span>"))
        #expect(properties["qtdMsgs"] != nil)
        #expect(mentions.contains("8:orgid:other"))
        #expect(sent.content == content)
        #expect(TeamsRenderedMessage(sent).body.blocks.flatMap(\.runs).contains { $0.isMention && $0.text == "Ánh & Co" })
    }

    @Test func sendsTheRecoveredTextContractAndMapsTheReceiptWithoutRoundingIDs() async throws {
        let transport = MessagingTransport()
        let text = "Xin chào 👋🏽 — <tag> & \"quotes\"\nSecond line"
        let chat = "19:example/with+reserved@thread.v2"
        let sent = try await TeamsMessagingClient(session: session(), transport: transport)
            .sendText(text, in: chat, clientMessageID: "1234567890123456789")
        let request = try #require(await transport.requests.first)
        #expect(await transport.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://teams.cloud.microsoft/api/chatsvc/amer/v1/users/ME/conversations/19%3Aexample%2Fwith%2Breserved%40thread.v2/messages")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ic3-test-secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-ms-request-priority") == "10")
        #expect(!request.httpShouldHandleCookies)
        let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: #require(request.httpBody))
        #expect(body["content"] == .string(text))
        #expect(body["messagetype"] == .string("Text"))
        #expect(body["contenttype"] == .string("Text"))
        #expect(body["clientmessageid"] == .string("1234567890123456789"))
        #expect(body["from"] == .string("8:orgid:" + account))
        #expect(body["id"] == .string("-1"))
        #expect(body["state"] == .number(0))
        #expect(body["properties"] == .object(["importance": .string(""), "links": .string("[]"),
                                              "mentions": .string("[]"), "onbehalfof": .null,
                                              "files": .string("[]"), "formatVariant": .string("TEAMS")]))
        #expect(sent.id == "9007199254740993")
        #expect(sent.originalArrivalTime == "1793420000123")
        #expect(sent.clientMessageId == "1234567890123456789")
        #expect(TeamsRenderedMessage(sent).body.text == text)
    }

    @Test func replySendsQuoteMetadataWithEscapedHTML() async throws {
        let transport = MessagingTransport()
        let quoted = TeamsWebMessage(id: "123", content: "original", messageType: "Text",
                                     from: .string("8:orgid:" + account), originalArrivalTime: "1793420000123")
        _ = try await TeamsMessagingClient(session: session(), transport: transport)
            .sendText("<reply>", in: "chat", clientMessageID: "456", replyingTo: quoted, preview: "<original>")
        let request = try #require(await transport.requests.first)
        let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: #require(request.httpBody))
        #expect(body["messagetype"] == .string("RichText/Html"))
        #expect(body["contenttype"] == .string("Text"))
        if case let .string(content)? = body["content"] {
            #expect(content.contains("&lt;reply&gt;"))
            #expect(content.contains("&lt;original&gt;"))
        } else { Issue.record("Missing reply content") }
        if case let .object(properties)? = body["properties"] {
            #expect(properties["qtdMsgs"] != nil)
            #expect(properties["formatVariant"] == .string("TEAMS"))
        } else { Issue.record("Missing reply properties") }
    }

    @Test func invalidTextIDsAndMessagingDestinationsNeverReachTransport() async throws {
        let transport = MessagingTransport()
        for base in ["http://teams.cloud.microsoft/api/chatsvc/amer", "https://evil.invalid/api/chatsvc/amer",
                     "https://teams.cloud.microsoft/api/csa/amer", "https://teams.cloud.microsoft/api/chatsvc/%61mer",
                     "https://teams.cloud.microsoft/api/chatsvc/amer?next=evil", "https://teams.cloud.microsoft:444/api/chatsvc/amer"] {
            do {
                _ = try await TeamsMessagingClient(session: session(base: base), transport: transport)
                    .sendText("hello", in: "chat", clientMessageID: "123")
                Issue.record("Unsafe messaging address accepted")
            } catch { #expect(error as? TeamsWebClientError == .unsafeBaseURL) }
        }
        for (text, id, expected) in [(" \n", "123", TeamsWebClientError.emptyMessage),
                                     (String(repeating: "🙂", count: 7_001), "123", .messageTooLarge),
                                     ("hello", "bad-id", .invalidClientMessageID)] {
            do {
                _ = try await TeamsMessagingClient(session: session(), transport: transport)
                    .sendText(text, in: "chat", clientMessageID: id)
                Issue.record("Invalid send accepted")
            } catch { #expect(error as? TeamsWebClientError == expected) }
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func ambiguousFailuresNeverAutomaticallyReplayThePOST() async throws {
        for transport in [MessagingTransport(failure: URLError(.timedOut)), MessagingTransport(failure: URLError(.cancelled)),
                          MessagingTransport(status: 503), MessagingTransport(status: 408), MessagingTransport(headers: [:])] {
            do {
                _ = try await TeamsMessagingClient(session: session(), transport: transport)
                    .sendText("hello", in: "chat", clientMessageID: "123")
                Issue.record("Ambiguous delivery was accepted")
            } catch { #expect(error as? TeamsWebClientError == .sendOutcomeUnknown) }
            #expect(await transport.requests.count == 1)
        }
    }

    @Test func duplicateClicksAreBlockedAndTextTypedDuringSendIsPreserved() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MessagingTransport(hold: true)
        let store = TeamsComposeStore(root: directory, transport: transport)
        store.connect(session())
        store.setDraft("First message", in: "chat")
        let pending = Task { await store.sendDraft(in: "chat") }
        while await transport.requests.isEmpty { await Task.yield() }
        #expect(store.outgoing["chat"]?.phase == .sending)
        store.setDraft("Next draft", in: "chat")
        #expect(await store.sendDraft(in: "chat") == nil)
        #expect(await transport.requests.count == 1)
        await transport.release()
        #expect(await pending.value?.id == "9007199254740993")
        #expect(store.draft(in: "chat") == "Next draft")
        #expect(store.outgoing["chat"] == nil)
    }

    @Test func formattingOnlyChangesDuringSendArePreserved() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MessagingTransport(hold: true)
        let store = TeamsComposeStore(root: directory, transport: transport); store.connect(session())
        let first = TeamsRichDraft(blocks: [.init(runs: [.init(text: "Hello", bold: true)])])
        let next = TeamsRichDraft(blocks: [.init(runs: [.init(text: "Hello", italic: true)])])
        store.setRichDraft(first, in: "chat")
        let pending = Task { await store.sendDraft(in: "chat") }
        while await transport.requests.isEmpty { await Task.yield() }
        store.setRichDraft(next, in: "chat")
        await transport.release(); _ = await pending.value
        #expect(store.richDrafts["chat"] == next && store.draft(in: "chat") == "Hello")
        let restored = TeamsComposeStore(root: directory, transport: transport); restored.connect(session())
        #expect(restored.richDrafts["chat"] == next)
    }

    @Test func uncertainRichDraftSurvivesRestart() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MessagingTransport(failure: URLError(.networkConnectionLost))
        let mention = TeamsRichDraft.Mention(mri: "8:orgid:person", displayName: "Person")
        let draft = TeamsRichDraft(blocks: [.init(runs: [.init(text: "Per", bold: true, mention: mention), .init(text: "son", mention: mention)])])
        let store = TeamsComposeStore(root: directory, transport: transport); store.connect(session()); store.setRichDraft(draft, in: "chat")
        _ = await store.sendDraft(in: "chat")
        let restored = TeamsComposeStore(root: directory, transport: transport); restored.connect(session())
        #expect(restored.richDrafts["chat"] == draft)
        #expect(restored.outgoing["chat"]?.richDraft == draft)
        #expect(restored.outgoing["chat"]?.phase == .uncertain)
    }

    @Test func legacyMentionWithoutOccurrencePreservesOtherDraftsAndPendingSend() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MessagingTransport(failure: URLError(.networkConnectionLost))
        let mention = TeamsRichDraft.Mention(mri: "8:orgid:person", displayName: "Person")
        let draft = TeamsRichDraft(blocks: [.init(runs: [.init(text: "Per", bold: true, mention: mention), .init(text: "son", mention: mention)])])
        let store = TeamsComposeStore(root: directory, transport: transport); store.connect(session())
        store.setDraft("Other draft", in: "other"); store.setRichDraft(draft, in: "chat"); _ = await store.sendDraft(in: "chat")
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        func strip(_ value: Any) -> Any {
            if let object = value as? [String: Any] { return object.filter { $0.key != "occurrenceID" }.mapValues(strip) }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        try JSONSerialization.data(withJSONObject: strip(json)).write(to: file)
        let restored = TeamsComposeStore(root: directory, transport: transport); restored.connect(session())
        #expect(restored.draft(in: "other") == "Other draft")
        #expect(restored.outgoing["chat"]?.phase == .uncertain)
        #expect(restored.richDrafts["chat"]?.blocks.first?.runs.first?.mention != nil)
        #expect(restored.persistenceError == nil)
        let rich = try #require(restored.richDrafts["chat"])
        #expect(try rich.serialize().mentionsJSON.contains("8:orgid:person"))
        #expect(rich.blocks[0].runs[0].mention?.occurrenceID == rich.blocks[0].runs[1].mention?.occurrenceID)
        let pending = try #require(restored.outgoing["chat"])
        #expect(pending.richDraft == rich)
        restored.reconcile([.init(id: "200", from: .string("8:orgid:" + account), clientMessageId: pending.clientMessageID)], in: "chat")
        #expect(restored.draft(in: "chat").isEmpty && restored.richDrafts["chat"] == nil)
        #expect(restored.draft(in: "other") == "Other draft")
    }
    @Test func legacyListDraftMigratesWithoutLosingPendingReconciliation() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MessagingTransport(failure: URLError(.networkConnectionLost))
        let draft = TeamsRichDraft(blocks: [.init(kind: .numberedList, children: [.init(kind: .listItem, runs: [.init(text: "First")]), .init(kind: .listItem, runs: [.init(text: "Second")])])])
        let store = TeamsComposeStore(root: directory, transport: transport); store.connect(session()); store.setRichDraft(draft, in: "chat"); _ = await store.sendDraft(in: "chat")
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var drafts = try #require(saved["drafts"] as? [String: String]); drafts["chat"] = "First\nSecond"; saved["drafts"] = drafts
        var outgoing = try #require(saved["outgoing"] as? [String: [String: Any]]); outgoing["chat"]?["text"] = "First\nSecond"; saved["outgoing"] = outgoing
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        let restored = TeamsComposeStore(root: directory, transport: transport); restored.connect(session())
        #expect(restored.richDrafts["chat"] == draft && restored.draft(in: "chat") == draft.plainText)
        let pending = try #require(restored.outgoing["chat"])
        restored.reconcile([.init(id: "200", from: .string("8:orgid:" + account), clientMessageId: pending.clientMessageID)], in: "chat")
        #expect(restored.draft(in: "chat").isEmpty)
    }

    @Test func uncertainDeliverySurvivesRelaunchAndReconcilesOnlyByClientIdentity() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MessagingTransport(failure: URLError(.networkConnectionLost))
        let store = TeamsComposeStore(root: directory, transport: transport)
        store.connect(session())
        store.setDraft("Xin chào 👋", in: "chat")
        #expect(await store.sendDraft(in: "chat") == nil)
        let id = try #require(store.outgoing["chat"]?.clientMessageID)
        #expect(store.outgoing["chat"]?.phase == .uncertain)
        let restored = TeamsComposeStore(root: directory, transport: transport)
        restored.connect(session())
        #expect(restored.draft(in: "chat") == "Xin chào 👋")
        #expect(!restored.canSend(in: "chat"))
        #expect(await restored.sendDraft(in: "chat") == nil)
        #expect(await transport.requests.count == 1)
        restored.reconcile([.init(id: "unrelated", content: "Xin chào 👋")], in: "chat")
        #expect(restored.outgoing["chat"] != nil)
        restored.reconcile([.init(id: "wrong-sender", from: .string("8:orgid:someone-else"), clientMessageId: id)], in: "chat")
        #expect(restored.outgoing["chat"] != nil)
        let message = try JSONDecoder().decode(TeamsWebMessage.self, from: Data("{\"id\":\"server-id\",\"clientmessageid\":\"\(id)\",\"from\":\"8:orgid:\(account)\"}".utf8))
        restored.reconcile([message], in: "chat")
        #expect(restored.outgoing["chat"] == nil)
        #expect(restored.draft(in: "chat").isEmpty)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("test-secret"))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func replyDraftSurvivesUncertaintyAndDoesNotEraseNewerQuote() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TeamsReplyDraft(messageID: "123", preview: "First", author: "A")
        let next = TeamsReplyDraft(messageID: "456", preview: "Next", author: "B")
        let quoted = TeamsWebMessage(id: "123", content: "First", messageType: "Text",
                                     from: .string("8:orgid:" + account), originalArrivalTime: "1793420000123")
        let transport = MessagingTransport(failure: URLError(.networkConnectionLost))
        let store = TeamsComposeStore(root: directory, transport: transport)
        store.connect(session())
        store.setDraft("Reply", in: "chat")
        store.setReply(first, in: "chat")
        #expect(await store.sendDraft(in: "chat", replyingTo: quoted, preview: first.preview) == nil)
        let pendingID = try #require(store.outgoing["chat"]?.clientMessageID)
        let restored = TeamsComposeStore(root: directory, transport: transport)
        restored.connect(session())
        #expect(restored.replies["chat"] == first)
        #expect(restored.outgoing["chat"]?.reply == first)
        restored.setReply(next, in: "chat")
        restored.reconcile([.init(id: "server", from: .string("8:orgid:" + account), clientMessageId: pendingID)], in: "chat")
        #expect(restored.replies["chat"] == next)
        #expect(restored.draft(in: "chat") == "Reply")
        #expect(restored.outgoing["chat"] == nil)

        let held = MessagingTransport(hold: true)
        let delayed = TeamsComposeStore(root: root(), transport: held)
        delayed.connect(session())
        delayed.setDraft("Reply", in: "chat")
        delayed.setReply(first, in: "chat")
        let send = Task { await delayed.sendDraft(in: "chat", replyingTo: quoted, preview: first.preview) }
        while await held.requests.isEmpty { await Task.yield() }
        delayed.setReply(next, in: "chat")
        await held.release()
        #expect(await send.value != nil)
        #expect(delayed.replies["chat"] == next)
        #expect(delayed.draft(in: "chat") == "Reply")
    }

    @Test func throttleRetainsDraftAndEnforcesDelayWithoutQueuingASend() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MessagingTransport(status: 429, headers: ["Retry-After": "300"])
        let store = TeamsComposeStore(root: directory, transport: transport)
        store.connect(session())
        store.setDraft("hello", in: "chat")
        #expect(await store.sendDraft(in: "chat") == nil)
        #expect(store.outgoing["chat"] == nil)
        #expect(store.draft(in: "chat") == "hello")
        #expect(!store.canSend(in: "chat"))
        #expect(store.canSend(in: "chat", at: Date().addingTimeInterval(301)))
        #expect(await store.sendDraft(in: "chat") == nil)
        #expect(await transport.requests.count == 1)
    }

    @Test func accountSwitchIsolatesDraftsAndIgnoresOldSendCompletion() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MessagingTransport(hold: true)
        let store = TeamsComposeStore(root: directory, transport: transport)
        store.connect(session())
        store.setDraft("Old account message", in: "chat")
        let pending = Task { await store.sendDraft(in: "chat") }
        while await transport.requests.isEmpty { await Task.yield() }
        store.connect(session(account: "cccccccc-cccc-cccc-cccc-cccccccccccc"))
        store.setDraft("New account draft", in: "chat")
        await transport.release()
        #expect(await pending.value == nil)
        #expect(store.draft(in: "chat") == "New account draft")
        #expect(store.outgoing.isEmpty)
        store.connect(session())
        #expect(store.draft(in: "chat") == "Old account message")
        #expect(store.outgoing["chat"]?.phase == .uncertain)
    }

    @Test func messagingHandoffRejectsOtherAccountsAndAudiences() throws {
        func jwt(audience: String, accountID: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["aud": audience, "oid": accountID, "tid": tenant,
                                                                  "name": "Example Person", "exp": 2_000_000_000])
            return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".test-only"
        }
        for (audience, otherAccount) in [("https://graph.microsoft.com", account),
                                        ("https://ic3.teams.office.com", "cccccccc-cccc-cccc-cccc-cccccccccccc")] {
            let payload = try JSONSerialization.data(withJSONObject: [
                "csaBaseURL": "https://teams.cloud.microsoft/api/csa/amer", "expiresAt": 2_000_000_000,
                "accessToken": jwt(audience: "https://chatsvcagg.teams.microsoft.com", accountID: account),
                "messaging": ["baseURL": "https://teams.cloud.microsoft/api/chatsvc/amer", "expiresAt": 2_000_000_000,
                              "accessToken": jwt(audience: audience, accountID: otherAccount)]
            ])
            #expect(throws: TeamsWebClientError.invalidSession) {
                try TeamsSessionHandoff.decode(payload, at: Date(timeIntervalSince1970: 1_800_000_000))
            }
        }
    }
}

private actor TwoHeldSends: HTTPTransport {
    private(set) var count = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let index = count
        await withCheckedContinuation { pending[index] = $0 }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                        headerFields: ["Location": "/messages/\(index)"])!)
    }
    func release(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
}

@MainActor
struct TeamsSendReconciliationTests {
    @Test func delayedCompletionCannotClearNewerPendingSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = TwoHeldSends()
        let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa",
                                      expiresAt: .distantFuture, accountID: account, tenantID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                                      displayName: "Test", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "chat", expiresAt: .distantFuture))
        let store = TeamsComposeStore(root: directory, transport: transport)
        store.connect(session)
        store.setDraft("A", in: "chat")
        let first = Task { await store.sendDraft(in: "chat") }
        while await transport.count < 1 { await Task.yield() }
        let firstID = try #require(store.outgoing["chat"]?.clientMessageID)
        store.reconcile([.init(id: "1", from: .string("8:orgid:" + account), clientMessageId: firstID)], in: "chat")
        store.setDraft("B", in: "chat")
        let second = Task { await store.sendDraft(in: "chat") }
        while await transport.count < 2 { await Task.yield() }
        let secondID = try #require(store.outgoing["chat"]?.clientMessageID)
        await transport.release(1)
        _ = await first.value
        #expect(store.outgoing["chat"]?.clientMessageID == secondID)
        #expect(store.draft(in: "chat") == "B")
        await transport.release(2)
        _ = await second.value
        #expect(store.outgoing["chat"] == nil)
    }
}
