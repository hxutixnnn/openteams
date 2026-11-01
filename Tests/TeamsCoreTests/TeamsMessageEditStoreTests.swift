import Foundation
import Testing
@testable import TeamsCore

private actor EditStoreTransport: HTTPTransport {
    let original: TeamsWebMessage
    let edited: TeamsWebMessage
    private(set) var writes = 0
    private(set) var deletes = 0
    private(set) var targetedReads = 0
    private(set) var historyReads = 0
    var showEdited = false
    var targetedStatus = 200
    var writeStatus = 500
    var targetedStatusAfterWrite: Int?
    var throttleHistory = false
    var holdTarget = false
    var targetPending: CheckedContinuation<Void, Never>?
    var targetStarted: CheckedContinuation<Void, Never>?
    var holdWrite = false
    var pending: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    init(original: TeamsWebMessage, edited: TeamsWebMessage) { self.original = original; self.edited = edited }
    func confirmEdit() { showEdited = true }
    func setTargetedStatus(_ status: Int) { targetedStatus = status }
    func acknowledgeThenFailRefresh() { writeStatus = 200; targetedStatusAfterWrite = 429 }
    func rejectWrites() { writeStatus = 403 }
    func holdNextTarget() { holdTarget = true }
    func waitForTarget() async { if targetPending == nil { await withCheckedContinuation { targetStarted = $0 } } }
    func releaseTarget() { targetPending?.resume(); targetPending = nil }
    func throttleNextHistory() { throttleHistory = true }
    func holdNextWrite() { holdWrite = true }
    func waitForWrite() async { if pending == nil { await withCheckedContinuation { started = $0 } } }
    func releaseWrite() { pending?.resume(); pending = nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if request.httpMethod == "DELETE" { deletes += 1; return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        if request.httpMethod == "PUT" {
            writes += 1
            if holdWrite { holdWrite = false; await withCheckedContinuation { pending = $0; started?.resume(); started = nil } }
            if writeStatus == 200 { showEdited = true }
            if let status = targetedStatusAfterWrite { targetedStatus = status }
            return (Data(), HTTPURLResponse(url: url, statusCode: writeStatus, httpVersion: nil, headerFields: nil)!)
        }
        let data: Data
        if url.path.hasSuffix("/messages/123") {
            targetedReads += 1
            if holdTarget { holdTarget = false; await withCheckedContinuation { targetPending = $0; targetStarted?.resume(); targetStarted = nil } }
            if targetedStatus != 200 { return (Data(), HTTPURLResponse(url: url, statusCode: targetedStatus, httpVersion: nil, headerFields: ["Retry-After": "1"])!) }
            data = try JSONEncoder().encode(showEdited ? edited : original)
        }
        else if url.path.hasSuffix("/messages") {
            historyReads += 1
            if throttleHistory { throttleHistory = false; return (Data(), HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!) }
            let newer = TeamsWebMessage(id: "999", content: "newer", messageType: "Text", originalArrivalTime: "2000")
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: historyReads == 1 ? [original, newer] : [newer], messageToken: "older"))
        }
        else { data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat")])) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor struct TeamsMessageEditStoreTests {
    @Test(arguments: [false, true]) func uncertainEditRetainsDraftAndReadOnlyCheckConfirms(code: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func message(_ content: String, _ version: String) -> TeamsWebMessage {
            .init(id: "123", content: code ? "<pre><code>\(content)</code></pre>" : content, messageType: code ? "RichText/Html" : "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: version, clientMessageId: "123")
        }
        let transport = EditStoreTransport(original: message("before", "1"), edited: message("after", "2"))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        await store.connect(session: session); await store.loadConversation("chat")
        let edit = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        edit.document = code ? .init(blocks: [.init(kind: .codeBlock, runs: [.init(text: "after")])]) : .init(plainText: "after")
        await store.saveMessageEdit(edit)
        #expect(edit.uncertain)
        #expect(await transport.writes == 1)
        await store.saveMessageEdit(edit)
        #expect(await transport.writes == 1)
        let restored = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        #expect(restored.uncertain && restored.document.contentText == "after")
        await store.checkMessageEdit(restored)
        #expect(restored.uncertain)
        #expect(await transport.writes == 1)
        await transport.confirmEdit()
        await store.checkMessageEdit(restored)
        #expect(!restored.uncertain && restored.status == "Edit confirmed.")
        #expect(await transport.writes == 1)
        #expect(store.messages(in: "chat").first(where: { $0.id == "123" })?.body.text == "after")
        #expect(store.hasOlderMessages("chat"))
    }
    @Test func concurrentEditsDoNotDispatchTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TeamsWebMessage(id: "123", content: "before", messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: "1", clientMessageId: "123")
        let transport = EditStoreTransport(original: original, edited: original)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        await store.connect(session: session); await store.loadConversation("chat")
        let first = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        let second = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        first.document = .init(plainText: "first"); second.document = .init(plainText: "second")
        await transport.holdNextWrite()
        let pending = Task { await store.saveMessageEdit(first) }
        await transport.waitForWrite()
        await store.saveMessageEdit(second)
        await store.messageAction("delete", chatID: "chat", messageID: "123", accountScope: store.accountScope)
        #expect(second.status?.contains("another window") == true)
        #expect(await transport.writes == 1)
        #expect(await transport.deletes == 0)
        await transport.releaseWrite(); await pending.value
        #expect(first.uncertain)
        await store.messageAction("delete", chatID: "chat", messageID: "123", accountScope: store.accountScope)
        #expect(await transport.deletes == 0)
    }
    @Test(arguments: [false, true]) func targetedThrottleBlocksImmediateEditRetry(duringCheck: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TeamsWebMessage(id: "123", content: "before", messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: "1")
        let transport = EditStoreTransport(original: original, edited: original)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        await store.connect(session: session); await store.loadConversation("chat")
        let edit = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        edit.document = .init(plainText: "after")
        if duringCheck { await store.saveMessageEdit(edit); #expect(edit.uncertain) }
        await transport.setTargetedStatus(429)
        if duringCheck { await store.checkMessageEdit(edit); await store.checkMessageEdit(edit) }
        else { await store.saveMessageEdit(edit); await store.saveMessageEdit(edit) }
        #expect(await transport.targetedReads == (duringCheck ? 2 : 1))
        #expect(await transport.writes == (duringCheck ? 1 : 0))
        #expect(store.retryNotBefore != nil)
    }
    @Test func missingMessagingSessionKeepsProposalWithoutWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TeamsWebMessage(id: "123", content: "before", messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: "1")
        let transport = EditStoreTransport(original: original, edited: original)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture")
        await store.connect(session: session); await store.loadConversation("chat")
        let edit = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        edit.document = .init(plainText: "after")
        await store.saveMessageEdit(edit)
        #expect(edit.document.plainText == "after" && edit.status?.contains("Reconnect") == true)
        #expect(await transport.writes == 0)
        let reopened = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        #expect(reopened.document.plainText == "after")
    }
    @Test func disconnectDuringWriteLeavesRecoverableUncertainty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TeamsWebMessage(id: "123", content: "before", messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: "1")
        let transport = EditStoreTransport(original: original, edited: original)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        await store.connect(session: session); await store.loadConversation("chat")
        let edit = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        edit.document = .init(plainText: "after")
        await transport.holdNextWrite()
        let task = Task { await store.saveMessageEdit(edit) }
        await transport.waitForWrite()
        store.disconnect()
        await transport.releaseWrite(); await task.value
        await store.connect(session: session); await store.loadConversation("chat")
        let reopened = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        #expect(reopened.uncertain && reopened.document.plainText == "after")
        #expect(await transport.writes == 1)
    }
    @Test func conflictingSourceKeepsProposalUntilExplicitDiscard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TeamsWebMessage(id: "123", content: "before", messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: "1")
        let changed = TeamsWebMessage(id: "123", content: "external", messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: "2")
        let transport = EditStoreTransport(original: original, edited: changed)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        await store.connect(session: session); await store.loadConversation("chat"); await store.refreshConversation("chat")
        let edit = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        edit.document = .init(plainText: "my proposal")
        await transport.confirmEdit(); await store.saveMessageEdit(edit)
        let reopened = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        #expect(reopened.document.plainText == "my proposal")
        #expect(await transport.writes == 0)
        #expect(await store.discardMessageEdit(reopened))
        let current = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        #expect(current.document.plainText == "external")
    }
    @Test func acknowledgedEditKeepsReadRecoveryUntilOlderTargetLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func message(_ content: String, _ version: String) -> TeamsWebMessage {
            .init(id: "123", content: content, messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: version)
        }
        let transport = EditStoreTransport(original: message("before", "1"), edited: message("after", "2"))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        await store.connect(session: session); await store.loadConversation("chat"); await store.refreshConversation("chat")
        let edit = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        edit.document = .init(plainText: "after")
        await transport.acknowledgeThenFailRefresh(); await store.saveMessageEdit(edit)
        #expect(edit.uncertain && edit.status?.contains("saved") == true)
        #expect(await transport.writes == 1)
        await store.checkMessageEdit(edit)
        #expect(await transport.targetedReads == 2)
        await transport.setTargetedStatus(200)
        for _ in 0..<200 { if store.retryNotBefore == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        await store.checkMessageEdit(edit)
        #expect(edit.completed && store.messages(in: "chat").first(where: { $0.id == "123" })?.body.text == "after")
        #expect(store.hasOlderMessages("chat"))
        #expect(await transport.writes == 1)
    }
    @Test func cooldownEstablishedDuringPreflightPreventsDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TeamsWebMessage(id: "123", content: "before", messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: "1")
        let transport = EditStoreTransport(original: original, edited: original)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        await store.connect(session: session); await store.loadConversation("chat")
        let edit = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        edit.document = .init(plainText: "after")
        await transport.holdNextTarget()
        let task = Task { await store.saveMessageEdit(edit) }
        await transport.waitForTarget()
        await transport.throttleNextHistory(); await store.refreshConversation("chat")
        await transport.releaseTarget(); await task.value
        #expect(await transport.writes == 0)
        #expect(!edit.uncertain && edit.status?.contains("limiting") == true)
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        #expect(try await cache.pendingEdit(in: "chat", messageID: "123")?.stage == .prepared)
    }
    @Test(arguments: [false, true]) func newerDifferentMessageOnlyClearsAcknowledgedEdit(acknowledged: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func message(_ content: String, _ version: String) -> TeamsWebMessage {
            .init(id: "123", content: content, messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: version)
        }
        let transport = EditStoreTransport(original: message("before", "1"), edited: message("newer external", "3"))
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        await store.connect(session: session); await store.loadConversation("chat")
        let edit = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        edit.document = .init(plainText: "my edit")
        if acknowledged { await transport.acknowledgeThenFailRefresh() }
        await store.saveMessageEdit(edit)
        if acknowledged {
            let reopened = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
            #expect(reopened.status?.contains("saved") == true)
            await transport.setTargetedStatus(200)
            for _ in 0..<200 { if store.retryNotBefore == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            await store.checkMessageEdit(reopened)
            #expect(reopened.completed && reopened.status?.contains("current message") == true)
            #expect(store.messages(in: "chat").first(where: { $0.id == "123" })?.body.text == "newer external")
        } else {
            await transport.confirmEdit(); await store.checkMessageEdit(edit)
            #expect(edit.uncertain && !edit.completed)
        }
        #expect(await transport.writes == 1)
    }
    @Test func rejectedEditPersistsUntilExplicitDiscard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TeamsWebMessage(id: "123", content: "before", messageType: "Text", from: .string("8:orgid:account"), originalArrivalTime: "1000", composeTime: "2026-10-31T00:00:00Z", version: "1")
        let transport = EditStoreTransport(original: original, edited: original)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let session = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture, accountID: "account", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "ic3", expiresAt: .distantFuture))
        await store.connect(session: session); await store.loadConversation("chat")
        let edit = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        edit.document = .init(plainText: "proposal")
        await transport.rejectWrites(); await store.saveMessageEdit(edit)
        #expect(!edit.uncertain && edit.status?.contains("not saved") == true)
        let reopened = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        #expect(reopened.document.plainText == "proposal")
        reopened.document = .init(plainText: "revised proposal")
        #expect(await store.retainMessageEdit(reopened))
        let retained = try await store.beginMessageEdit(in: "chat", messageID: "123", accountScope: store.accountScope)
        #expect(retained.document.plainText == "revised proposal")
        #expect(await store.discardMessageEdit(retained))
        #expect(await transport.writes == 1)
    }
}
