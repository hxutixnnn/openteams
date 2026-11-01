import Foundation
import CryptoKit
import Testing
@testable import TeamsCore

private actor DeletionTransport: HTTPTransport {
    let account: String
    var deletes = 0
    var reads = 0
    var deleteStatus = 204
    var readStatus = 200
    var historyStatus = 200
    var newestOnly = false
    var lastHistoryIDs: [String] = []
    var unknown = false
    var tombstone = false
    var stale = false
    var held = false
    var waiting: CheckedContinuation<Void, Never>?
    init(account: String) { self.account = account }
    func configure(delete: Int? = nil, read: Int? = nil, unknown: Bool? = nil, tombstone: Bool? = nil, stale: Bool? = nil) {
        if let delete { deleteStatus = delete }; if let read { readStatus = read }; if let unknown { self.unknown = unknown }
        if let tombstone { self.tombstone = tombstone }; if let stale { self.stale = stale }
    }
    func useNewestOnly() { newestOnly = true }
    func throttleHistory() { historyStatus = 429 }
    func hold() { held = true }
    func release() { held = false; waiting?.resume(); waiting = nil }
    func message(_ id: String, deleted: Bool = false, version: String = "1") -> TeamsWebMessage {
        .init(id: id, content: "Fixture \(id)", messageType: "Text", from: .string("8:orgid:" + account), originalArrivalTime: "1800000000000", version: version,
              properties: deleted ? .object(["deletetime": .number(1)]) : nil)
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!, path = url.path
        var status = 200, headers: [String: String] = [:], body = Data("{}".utf8)
        if request.httpMethod == "DELETE" {
            deletes += 1
            if held { await withCheckedContinuation { waiting = $0 } }
            if unknown { throw URLError(.networkConnectionLost) }
            status = deleteStatus
            if status == 429 { headers["Retry-After"] = "120" }
        } else if path.hasSuffix("/messages/100") {
            reads += 1; status = readStatus
            body = try JSONEncoder().encode(message("100", deleted: tombstone, version: stale ? "1" : "2"))
        } else if path.hasSuffix("/messages") {
            status = historyStatus
            if status == 429 { headers["Retry-After"] = "120" }
            let values = newestOnly ? [message("200")] : [message("100"), message("200")]
            lastHistoryIDs = values.map(\.id)
            body = try JSONEncoder().encode(TeamsWebMessagePage(messages: values, messageToken: "older"))
        } else { body = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat", title: "Fixture")])) }
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private actor DeletionReadGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor struct TeamsDeletionLifecycleTests {
    func session(_ account: String) -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: account, tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "fixture", expiresAt: .distantFuture))
    }
    private func make() async -> (TeamsReaderStore, DeletionTransport, URL, String) {
        let account = UUID().uuidString.lowercased(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transport = DeletionTransport(account: account), store = TeamsReaderStore(cacheRoot: root, transport: transport)
        await store.connect(session: session(account)); await store.loadConversation("chat")
        return (store, transport, root, account)
    }
    @Test func unknownSurvivesRestartAndCannotRepeat() async throws {
        let (store, transport, root, account) = await make()
        await transport.configure(unknown: true)
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(store.deletionStage(in: "chat", messageID: "100") == .uncertain)
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(await transport.deletes == 1)
        let reopened = TeamsReaderStore(cacheRoot: root, transport: transport)
        await reopened.connect(session: session(account)); await reopened.loadConversation("chat")
        await reopened.loadDeletionStatus(in: "chat", messageID: "100", expectedScope: reopened.accountScope, expectedRevision: reopened.accountRevision)
        #expect(reopened.deletionStage(in: "chat", messageID: "100") == .uncertain)
        do { _ = try await reopened.beginMessageEdit(in: "chat", messageID: "100", accountScope: reopened.accountScope); Issue.record("Edit opened over uncertain delete") } catch {}
        await reopened.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(await transport.deletes == 1)
    }
    @Test func acceptedReadFailureAndStaleTombstoneRemainPendingThenMergeTarget() async throws {
        let (store, transport, _, _) = await make()
        await transport.useNewestOnly(); await store.refreshConversation("chat")
        #expect(await transport.lastHistoryIDs == ["200"])
        #expect(store.messages(in: "chat").contains { $0.id == "100" })
        await transport.configure(read: 404)
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        while await transport.reads == 0 { await Task.yield() }
        while store.chatErrors["chat"] == nil { await Task.yield() }
        #expect(store.deletionStage(in: "chat", messageID: "100") == .accepted)
        #expect(store.deletionMessage(in: "chat", messageID: "100")?.contains("accepted") == true)
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(await transport.deletes == 1)
        await transport.configure(read: 200, tombstone: true, stale: true)
        await store.checkDeletion(in: "chat", messageID: "100")
        #expect(store.deletionStage(in: "chat", messageID: "100") == .accepted)
        await transport.configure(stale: false)
        await store.checkDeletion(in: "chat", messageID: "100")
        #expect(store.deletionStage(in: "chat", messageID: "100") == nil)
        #expect(store.messages(in: "chat").first(where: { $0.id == "100" })?.isDeleted == true)
        #expect(!store.canDelete(in: "chat", messageID: "100"))
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(await transport.deletes == 1)
        #expect(store.hasOlderMessages("chat"))
    }
    @Test func throttleAndSharedLeasePreventDuplicateDispatch() async throws {
        let (store, transport, root, account) = await make()
        await transport.configure(delete: 429)
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(store.deletionStage(in: "chat", messageID: "100") == .rejected && store.retryNotBefore != nil)
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(await transport.deletes == 1)
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = TeamsReaderStore(cacheRoot: otherRoot, transport: transport)
        await other.connect(session: session(account)); await other.loadConversation("chat")
        await transport.configure(delete: 204, read: 404); await transport.hold()
        let task = Task { await other.messageAction("delete", chatID: "chat", messageID: "100") }
        while await transport.deletes < 2 { await Task.yield() }
        let second = TeamsReaderStore(cacheRoot: otherRoot, transport: transport)
        await second.connect(session: session(account)); await second.loadConversation("chat")
        do {
            let edit = try await second.beginMessageEdit(in: "chat", messageID: "100", accountScope: second.accountScope)
            await second.saveMessageEdit(edit)
        } catch {}
        await second.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(await transport.deletes == 2)
        await transport.release(); await task.value
        _ = root
    }
    @Test func priorEditAndUnrelatedThrottleBlockDelete() async throws {
        let (store, transport, root, account) = await make()
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: "tenant")
        let original = await transport.message("100")
        let edit = TeamsPendingEdit(original: original, document: TeamsRichDraft(plainText: "Draft"))
        #expect(try await cache.installPendingEdit(edit, in: "chat"))
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(await transport.deletes == 0)
        #expect(try await cache.clearPendingEdit(id: edit.id, in: "chat", messageID: "100"))
        await transport.throttleHistory(); await store.refreshConversation("chat")
        #expect(store.retryNotBefore != nil)
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(await transport.deletes == 0)
    }
    @Test func acceptedResultSurvivesSameAccountRenewal() async throws {
        let (store, transport, _, account) = await make()
        await transport.hold()
        let task = Task { await store.messageAction("delete", chatID: "chat", messageID: "100") }
        while await transport.deletes == 0 { await Task.yield() }
        await store.connect(session: session(account))
        await transport.release(); await task.value
        #expect(store.deletionStage(in: "chat", messageID: "100") == .accepted)
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(await transport.deletes == 1)
    }
    @Test func delayedResultStaysWithOriginalAccount() async throws {
        let (store, transport, root, account) = await make()
        await transport.hold()
        let task = Task { await store.messageAction("delete", chatID: "chat", messageID: "100") }
        while await transport.deletes == 0 { await Task.yield() }
        await store.restoreAccount(accountID: UUID().uuidString, tenantID: "tenant", displayName: "Other")
        await transport.release(); await task.value
        #expect(store.deletionStage(in: "chat", messageID: "100") == nil)
        let restored = TeamsReaderStore(cacheRoot: root, transport: transport)
        await restored.connect(session: session(account)); await restored.loadConversation("chat")
        await restored.loadDeletionStatus(in: "chat", messageID: "100", expectedScope: restored.accountScope, expectedRevision: restored.accountRevision)
        #expect(restored.deletionStage(in: "chat", messageID: "100") == .accepted)
        #expect(await transport.deletes == 1)
    }

    @Test func preparedRecordCanBeReviewedWithoutDispatch() async throws {
        let (store, transport, root, account) = await make()
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: "tenant")
        let intent = TeamsPendingDeletion(original: await transport.message("100"))
        #expect(try await cache.installPendingDeletion(intent, in: "chat"))
        await store.loadDeletionStatus(in: "chat", messageID: "100", expectedScope: store.accountScope, expectedRevision: store.accountRevision)
        #expect(store.deletionStage(in: "chat", messageID: "100") == .prepared)
        await store.checkDeletion(in: "chat", messageID: "100")
        #expect(store.deletionStage(in: "chat", messageID: "100") == .rejected)
        #expect(await transport.deletes == 0)
        #expect(await transport.reads == 0)
    }

    @Test func acceptedResponseStaysKnownWhenStatusWriteFails() async throws {
        let (store, transport, root, account) = await make()
        await transport.hold()
        let task = Task { await store.messageAction("delete", chatID: "chat", messageID: "100") }
        while await transport.deletes == 0 { await Task.yield() }
        let digest = SHA256.hash(data: Data(("tenant\n" + account).utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(digest)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await transport.release(); await task.value
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(store.deletionStage(in: "chat", messageID: "100") == .accepted)
        #expect(store.deletionMessage(in: "chat", messageID: "100")?.contains("could not be saved") == true)
        await store.loadDeletionStatus(in: "chat", messageID: "100", expectedScope: store.accountScope, expectedRevision: store.accountRevision)
        #expect(store.deletionStage(in: "chat", messageID: "100") == .accepted)
        await store.messageAction("delete", chatID: "chat", messageID: "100")
        #expect(await transport.deletes == 1)
        await transport.configure(read: 404)
        await store.checkDeletion(in: "chat", messageID: "100")
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: "tenant")
        #expect(try await cache.pendingDeletion(in: "chat", messageID: "100")?.stage == .accepted)
        #expect(await transport.deletes == 1)
    }
    @Test func statusReadRechecksAccountAndCooldownAfterJournalSuspension() async throws {
        for changeAccount in [true, false] {
            let (store, transport, root, account) = await make()
            let cache = TeamsReadCache(root: root, accountID: account, tenantID: "tenant")
            let intent = TeamsPendingDeletion(original: await transport.message("100"))
            #expect(try await cache.installPendingDeletion(intent, in: "chat"))
            #expect(try await cache.updatePendingDeletion(id: intent.id, in: "chat", messageID: "100", expected: .prepared, stage: .dispatched))
            let gate = DeletionReadGate()
            store.deletionCheckAfterJournal = { await gate.pause() }
            let task = Task { await store.checkDeletion(in: "chat", messageID: "100") }
            while !(await gate.entered) { await Task.yield() }
            if changeAccount { await store.restoreAccount(accountID: UUID().uuidString, tenantID: "tenant", displayName: "Other") }
            else { await transport.throttleHistory(); await store.refreshConversation("chat") }
            await gate.release(); await task.value
            #expect(await transport.reads == 0)
            if !changeAccount { #expect(store.retryNotBefore != nil) }
        }
    }

}
