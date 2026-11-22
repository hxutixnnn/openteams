import Foundation
import CryptoKit
import Darwin
import TeamsCore

private struct DigestEnvelope<Value: Codable>: Codable {
    let version: Int
    let accountID: String
    let tenantID: String
    let payload: Value
}

private struct DigestIntent<Value: Codable>: Codable {
    let intent: Value?
}

private struct DigestRandom: RandomNumberGenerator {
    var state: UInt64 = 0x8ba4527d913cf601
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private actor DigestOffline: HTTPTransport {
    var requests = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        throw URLError(.notConnectedToInternet)
    }
}

@main struct CacheDigestLoading {
    static let account = "digest-fixture"
    static let tenant = "fixture-tenant"

    static func reference(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func directory(_ root: URL, account: String = account, tenant: String = tenant) -> URL {
        root.appendingPathComponent(reference(tenant + "\n" + account))
    }

    static func seed<Value: Codable>(_ value: Value, name: String, root: URL) throws {
        let folder = directory(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let envelope = DigestEnvelope(version: 1, accountID: account, tenantID: tenant, payload: value)
        try JSONEncoder().encode(envelope).write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
    }

    static func message(_ index: Int) -> TeamsWebMessage {
        let id = String(1_800_000_000_000 + index)
        return .init(id: id, content: "<p><strong>Fictional message \(index)</strong> Xin chào 👋 <a href=\"https://example.com/fixture\">Reference</a></p><ol><li>First item</li><li><em>Second item</em></li></ol><blockquote>Fictional quoted content</blockquote>", messageType: "RichText/Html", imDisplayName: "Fixture User", from: .string("8:orgid:other"), originalArrivalTime: id, version: "1")
    }

    static func filenames(root: URL) async throws {
        precondition(reference("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        var ids = ["", "\0", ".", "..", "chat/../../fixture", "line\nfeed\rtab\t", "é", "e\u{301}", "Xin chào 👋", "日本語", "مرحبا", String(repeating: "x", count: 100_000), String(repeating: "🧪é", count: 20_000)]
        var random = DigestRandom()
        for i in 0..<1024 {
            let bytes = (0..<Int(random.next() % 2049)).map { _ in UInt8(truncatingIfNeeded: random.next() >> 32) }
            ids.append("random-\(i)-" + String(decoding: bytes, as: UTF8.self))
        }
        let a = "account\né👋", t = "tenant日本語"
        let cache = TeamsReadCache(root: root, accountID: a, tenantID: t)
        let folder = directory(root, account: a, tenant: t)
        var covered = Set<UInt8>()
        var expected = Set<Data>()
        let history = TeamsCachedHistory(messages: [message(0)], messageToken: "older")
        for id in ids {
            covered.formUnion(SHA256.hash(data: Data(id.utf8)))
            let name = "chat-" + reference(id) + ".json"
            expected.insert(Data(name.utf8))
            try await cache.save(history, in: id)
            precondition(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "Filename differs from main")
            let restored = try await cache.history(in: id)
            precondition(restored.messages == history.messages && restored.messageToken == "older")
        }
        let actual = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        precondition(Set(actual.map { Data($0.lastPathComponent.utf8) }) == expected)
        precondition(covered == Set(UInt8.min...UInt8.max))
        for (i, id) in ["", "é", "e\u{301}", String(repeating: "long👋", count: 10_000)].enumerated() {
            let scope = root.appendingPathComponent("scope-\(i)")
            let scoped = TeamsReadCache(root: scope, accountID: id, tenantID: "tenant\n" + id)
            try await scoped.save(.init(chats: [.init(id: "fixture")]))
            precondition(FileManager.default.fileExists(atPath: directory(scope, account: id, tenant: "tenant\n" + id).appendingPathComponent("chats.json").path))
        }
        print("CACHE_DIGEST_FILENAMES_OK inputs=\(ids.count) random=1024 digest_byte_values=256 empty=true unicode=true long=true byte_identical=true")
    }

    static func lease(_ path: URL, acquire: () async throws -> TeamsReadLease?) async throws {
        let descriptor = open(path.path, O_CREAT | O_RDWR, mode_t(0o600))
        precondition(descriptor >= 0)
        defer { close(descriptor) }
        precondition(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let blocked = try await acquire()
        precondition(blocked == nil, "Legacy lease namespace changed")
        precondition(flock(descriptor, LOCK_UN) == 0)
        let acquired = try await acquire()
        precondition(acquired != nil)
        withExtendedLifetime(acquired) {}
    }

    static func compatibility(root: URL) async throws {
        let chat = "legacy/é\n👋", editID = "edit-" + String(repeating: "日本語", count: 1000)
        let deletion = TeamsPendingDeletion(original: message(1))
        let edit = TeamsPendingEdit(original: .init(id: editID, content: "Original", messageType: "Text"), document: .init(plainText: "Retained draft"))
        var read = TeamsPendingReadIntent(targetHorizon: 1_800_000_000_001, bookmarkRequired: false, minimumVersion: "1")
        read.stage = .bookmarkAccepted
        let history = TeamsCachedHistory(messages: [message(0)], messageToken: "legacy-older")
        let readName = "read-intent-" + reference(chat)
        let deleteKey = "edit\n" + chat + "\n" + deletion.original.id
        let editKey = "edit\n" + chat + "\n" + editID
        let deleteName = "delete-intent-" + reference(deleteKey)
        let editName = "edit-intent-" + reference(editKey)
        try seed(TeamsCachedChats(chats: [.init(id: chat, title: "Existing cache")]), name: "chats", root: root)
        try seed(history, name: "chat-" + reference(chat), root: root)
        try seed(DigestIntent(intent: read), name: readName, root: root)
        try seed(DigestIntent(intent: deletion), name: deleteName, root: root)
        try seed(DigestIntent(intent: edit), name: editName, root: root)
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        let chats = try await cache.chats(), restored = try await cache.history(in: chat)
        let savedRead = try await cache.pendingRead(in: chat)
        let savedDelete = try await cache.pendingDeletion(in: chat, messageID: deletion.original.id)
        let savedEdit = try await cache.pendingEdit(in: chat, messageID: editID)
        precondition(chats.chats.first?.title == "Existing cache" && restored.messages == history.messages && restored.messageToken == "legacy-older")
        precondition(savedRead?.id == read.id && savedRead?.stage == read.stage && savedRead?.targetHorizon == read.targetHorizon && savedRead?.bookmarkRequired == false)
        precondition(savedDelete?.id == deletion.id && savedDelete?.original == deletion.original && savedDelete?.stage == .prepared)
        precondition(savedEdit?.id == edit.id && savedEdit?.document == edit.document && savedEdit?.original == edit.original)
        let folder = directory(root)
        try await lease(folder.appendingPathComponent(readName + ".lease")) { try await cache.acquireReadLease(in: chat) }
        try await lease(folder.appendingPathComponent("read-intent-" + reference(editKey) + ".lease")) { try await cache.acquireEditLease(in: chat, messageID: editID) }
        let advanced = try await cache.advancePendingRead(id: read.id, stage: .horizonAccepted, in: chat)
        let clearedEdit = try await cache.clearPendingEdit(id: edit.id, in: chat, messageID: editID)
        let clearedDelete = try await cache.updatePendingDeletion(id: deletion.id, in: chat, messageID: deletion.original.id, expected: .prepared, stage: nil)
        precondition(advanced && clearedEdit && clearedDelete)
        let updated = try JSONDecoder().decode(DigestEnvelope<DigestIntent<TeamsPendingReadIntent>>.self, from: Data(contentsOf: folder.appendingPathComponent(readName + ".json")))
        precondition(updated.payload.intent?.stage == .horizonAccepted)
        let emptyEdit = try JSONDecoder().decode(DigestEnvelope<DigestIntent<TeamsPendingEdit>>.self, from: Data(contentsOf: folder.appendingPathComponent(editName + ".json")))
        let emptyDelete = try JSONDecoder().decode(DigestEnvelope<DigestIntent<TeamsPendingDeletion>>.self, from: Data(contentsOf: folder.appendingPathComponent(deleteName + ".json")))
        precondition(emptyEdit.payload.intent == nil && emptyDelete.payload.intent == nil)
        let expected = ["chats.json", "chat-" + reference(chat) + ".json", readName + ".json", editName + ".json", deleteName + ".json", readName + ".lease", "read-intent-" + reference(editKey) + ".lease", readName + ".lock", "read-intent-" + reference(editKey) + ".lock", "read-intent-" + reference(deleteKey) + ".lock"]
        let actual = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        precondition(Set(actual.map { Data($0.lastPathComponent.utf8) }) == Set(expected.map { Data($0.utf8) }))
        let missing = try await cache.pendingRead(in: "missing")
        precondition(missing == nil)
        let corruptID = "corrupt"
        try Data("{invalid".utf8).write(to: folder.appendingPathComponent("read-intent-" + reference(corruptID) + ".json"))
        do {
            _ = try await cache.pendingRead(in: corruptID)
            preconditionFailure("Corrupt legacy journal was treated as missing")
        } catch is DecodingError {}
        print("CACHE_DIGEST_LEGACY_OK chats=true history=true read=true edit=true deletion=true lease_contention=true lock_names=true updates=true missing=true corrupt=true")
    }

    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }

    static func report(_ name: String, _ elapsed: Double, count: Int) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["name": name, "ms": elapsed, "count": count], options: [.sortedKeys]), as: UTF8.self))
    }

    @MainActor static func benchmark(root: URL) async throws {
        let raw = (1...2000).map(message)
        let chats = (0..<1000).map { TeamsWebChat(id: $0 == 0 ? "fixture" : "chat-\($0)", title: "Fixture \($0)", isOneOnOne: true, isRead: false, lastMessage: raw[$0]) }
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        try await cache.save(.init(chats: chats))
        try await cache.save(.init(messages: raw), in: "fixture")
        let sentinel = TeamsPendingReadIntent(targetHorizon: 1)
        let installed = try await cache.installPendingRead(sentinel, in: chats.last!.id)
        precondition(installed)
        let deletion = TeamsPendingDeletion(original: raw.last!)
        let installedDeletion = try await cache.installPendingDeletion(deletion, in: "fixture")
        precondition(installedDeletion)
        let transport = DigestOffline()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport)
        let start = ContinuousClock.now
        await store.restoreAccount(accountID: account, tenantID: tenant, displayName: "Fixture")
        let publication = milliseconds(start)
        while !store.pendingReadChatIDs.contains(chats.last!.id) {
            precondition(milliseconds(start) < 10_000, "Pending-status scan did not reach its final chat")
            try await Task.sleep(for: .milliseconds(1))
        }
        let complete = milliseconds(start)
        precondition(store.chats.map(\.id) == chats.map(\.id) && store.pendingReadChatIDs == [chats.last!.id])
        try report("restore_1000_complete", complete, count: 1000)
        try report("restore_1000_publication", publication, count: 1000)
        await store.loadConversation("fixture")
        precondition(store.messages(in: "fixture").count == raw.count)
        let deletionStart = ContinuousClock.now
        await store.loadDeletionStatuses(in: "fixture", messageIDs: store.messageIDs(in: "fixture"), expectedScope: store.accountScope, expectedRevision: store.accountRevision)
        let elapsed = milliseconds(deletionStart)
        precondition(store.deletionStage(in: "fixture", messageID: raw.last!.id) == .prepared)
        try report("deletion_status_2000", elapsed, count: 2000)
        let requests = await transport.requests
        precondition(requests == 0)
        store.disconnect()
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-cache-digest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        if !CommandLine.arguments.contains("--benchmark") {
            try await filenames(root: root.appendingPathComponent("filenames"))
            try await compatibility(root: root.appendingPathComponent("legacy"))
        }
        try await benchmark(root: root.appendingPathComponent("benchmark"))
        print("CACHE_DIGEST_LOADING_OK")
    }
}
