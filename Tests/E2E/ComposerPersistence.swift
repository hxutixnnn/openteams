import CryptoKit
import Foundation
import TeamsCore

private struct ComposeSnapshot: Codable, Equatable, Sendable {
    let accountKey: String
    let drafts: [String: String]
    let outgoing: [String: TeamsOutgoingMessage]
    let replies: [String: TeamsReplyDraft]?
    let richDrafts: [String: TeamsRichDraft]?
}

private actor PersistedSendTransport: HTTPTransport {
    let file: URL
    private(set) var snapshots: [ComposeSnapshot] = []
    private var duringRequest: (@Sendable () async -> Void)?
    init(file: URL) { self.file = file }
    func setDuringRequest(_ action: @escaping @Sendable () async -> Void) { duringRequest = action }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        snapshots.append(try JSONDecoder().decode(ComposeSnapshot.self, from: Data(contentsOf: file)))
        await duringRequest?()
        throw URLError(.timedOut)
    }
}

@main @MainActor
struct ComposerPersistence {

    static func main() async throws {
        let scenario = ComposerPersistence()
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--recover" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let expected = try scenario.snapshot(at: URL(fileURLWithPath: CommandLine.arguments[4]))
            let store = TeamsComposeStore(root: directory)
            store.restore(accountID: CommandLine.arguments[3], tenantID: scenario.tenant)
            try check(store.persistenceError == nil)
            try check(store.drafts == expected.drafts)
            try check(store.richDrafts == expected.richDrafts ?? [:])
            try check(store.replies == expected.replies ?? [:])
            let recoveredOutgoing = expected.outgoing.mapValues { value in
                var recovered = value
                recovered.phase = .uncertain
                return recovered
            }
            try check(store.outgoing == recoveredOutgoing)
            print("RECOVERY_OK")
            return
        }
        try scenario.identicalPublicationsSkipWritesButStillCancelPreparation()
        try scenario.cachedRichMembersRetainTheJSONSchemaAndEscaping()
        try scenario.completedWritesSurviveAccountSwitchDisconnectAndFreshStore()
        try scenario.failedWritesRetryIdenticalInputAndThePreviousSuccessfulState()
        try scenario.exactSizeLimitPreservesTheLastSavedSnapshotAndRecovers()
        try await scenario.pendingSendIsSavedBeforeHTTPAndUncertaintySurvivesRestart()
        try await scenario.failedPendingSaveNeverReachesHTTPAfterAnIdenticalPublication()
        try await scenario.editsAndAccountSwitchDuringSendSurviveRecovery()
        print("E2E_OK composer persistence: 8 workflows")
    }

    private func verifyRecovery(in directory: URL, account: String? = nil) throws {
        let expectedFile = directory.appendingPathComponent("expected-" + UUID().uuidString + ".json")
        try Data(contentsOf: file(in: directory, account: account)).write(to: expectedFile)
        defer { try? FileManager.default.removeItem(at: expectedFile) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--recover", directory.path, account ?? self.account, expectedFile.path]
        try process.run()
        process.waitUntilExit()
        try check(process.terminationReason == .exit && process.terminationStatus == 0)
    }

    private let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func file(in root: URL, account: String? = nil) -> URL {
        let key = SHA256.hash(data: Data((tenant + "\n" + (account ?? self.account)).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key + ".json")
    }
    private func session() -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture-only",
              expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Fixture Person",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!,
                               accessToken: "fixture-only", expiresAt: .distantFuture))
    }
    private func snapshot(at file: URL) throws -> ComposeSnapshot {
        try JSONDecoder().decode(ComposeSnapshot.self, from: Data(contentsOf: file))
    }
    private func identity(of file: URL) throws -> NSNumber {
        try require(FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)
    }
    private func rich(_ text: String = "Hello", italic: Bool = false) -> TeamsRichDraft {
        .init(blocks: [.init(runs: [.init(text: text, bold: !italic, italic: italic)])])
    }

    func identicalPublicationsSkipWritesButStillCancelPreparation() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = TeamsComposeStore(root: directory); store.connect(session())
        store.setDraft("Hello", in: "chat")
        let plainFileID = try identity(of: file(in: directory))
        let revision = try require(store.beginPreparation(in: "chat"))
        store.setDraft("Hello", in: "chat")
        try check(!store.finishPreparation(in: "chat", revision: revision))
        store.setRichDraft(.init(plainText: "Hello"), in: "chat")
        try check(try identity(of: file(in: directory)) == plainFileID)

        let draft = rich()
        store.setRichDraft(draft, in: "chat")
        let reply = TeamsReplyDraft(messageID: "123", preview: "Earlier", author: "Fixture Person")
        store.setReply(reply, in: "chat")
        let richFileID = try identity(of: file(in: directory))
        let richRevision = try require(store.beginPreparation(in: "chat"))
        store.setRichDraft(draft, in: "chat")
        try check(!store.finishPreparation(in: "chat", revision: richRevision))
        store.setReply(reply, in: "chat")
        try check(try identity(of: file(in: directory)) == richFileID)
        try check(try snapshot(at: file(in: directory)).richDrafts?["chat"] == draft)

        store.setRichDraft(rich(italic: true), in: "chat")
        try check(try identity(of: file(in: directory)) != richFileID)
        try check(try snapshot(at: file(in: directory)).richDrafts?["chat"] == rich(italic: true))
    }

    func cachedRichMembersRetainTheJSONSchemaAndEscaping() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = TeamsComposeStore(root: directory); store.connect(session())
        let chatID = "chat\"\\/\n\t👋"
        let mention = TeamsRichDraft.Mention(mri: "8:orgid:fixture", displayName: "Alex \"Example\"")
        let draft = TeamsRichDraft(blocks: [.init(kind: .numberedList, children: [
            .init(kind: .listItem, runs: [.init(text: mention.displayName, mention: mention),
                .init(text: " — \"quotes\", \\slashes/ and\nnewlines\t🙂", italic: true,
                      link: URL(string: "https://example.com/a?b=%22c%22&d=e"))])])])
        store.setRichDraft(draft, in: chatID)
        store.setRichDraft(rich("Another draft"), in: "other")
        store.setRichDraft(rich("Changed", italic: true), in: "other")
        let saved = try snapshot(at: file(in: directory))
        try check(saved.richDrafts?[chatID] == draft)
        try check(saved.drafts[chatID] == draft.plainText)
        let json = try require(JSONSerialization.jsonObject(with: Data(contentsOf: file(in: directory))) as? NSDictionary)
        let conventionalJSON = try require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? NSDictionary)
        try check(json == conventionalJSON)
        try check(Set(json.allKeys.compactMap { $0 as? String }) == ["accountKey", "drafts", "outgoing", "replies", "richDrafts"])

        try verifyRecovery(in: directory)
        store.setDraft("Plain replacement", in: chatID)
        store.setRichDraft(.init(plainText: ""), in: "other")
        let cleared = try snapshot(at: file(in: directory))
        try check(cleared.richDrafts == [:])
        try check(cleared.drafts == [chatID: "Plain replacement"])
        store.setRichDraft(draft, in: chatID)
        let reopened = TeamsComposeStore(root: directory); reopened.connect(session())
        try check(reopened.richDrafts[chatID] == draft)
        try check(reopened.draft(in: "other").isEmpty)
    }

    func completedWritesSurviveAccountSwitchDisconnectAndFreshStore() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = TeamsComposeStore(root: directory); store.connect(session())
        let first = rich("Account A")
        let second = rich("Account B", italic: true)
        store.setRichDraft(first, in: "shared-chat")
        let otherAccount = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        store.restore(accountID: otherAccount, tenantID: tenant)
        store.setRichDraft(second, in: "shared-chat")
        store.disconnect()
        try verifyRecovery(in: directory)
        try verifyRecovery(in: directory, account: otherAccount)
        try check(try snapshot(at: file(in: directory)).richDrafts?["shared-chat"] == first)
        try check(try snapshot(at: file(in: directory, account: otherAccount)).richDrafts?["shared-chat"] == second)
        store.connect(session())
        try check(store.richDrafts["shared-chat"] == first)
        store.setRichDraft(rich("Account A later"), in: "shared-chat")
        let reopened = TeamsComposeStore(root: directory)
        reopened.restore(accountID: otherAccount, tenantID: tenant)
        try check(reopened.richDrafts["shared-chat"] == second)
        reopened.connect(session())
        try check(reopened.richDrafts["shared-chat"] == rich("Account A later"))
        try check(reopened.persistenceError == nil)
        try check((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try check((try FileManager.default.attributesOfItem(atPath: file(in: directory).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    func failedWritesRetryIdenticalInputAndThePreviousSuccessfulState() throws {
        let directory = root(), backup = root()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: backup) }
        let store = TeamsComposeStore(root: directory); store.connect(session())
        store.setRichDraft(rich("Saved"), in: "chat")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("block directory creation".utf8).write(to: directory)
        store.setRichDraft(rich("Changed"), in: "chat")
        try check(store.persistenceError != nil)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        store.setRichDraft(rich("Changed"), in: "chat")
        try check(store.persistenceError == nil)
        try check(try snapshot(at: file(in: directory)).richDrafts?["chat"] == rich("Changed"))

        let previousFileID = try identity(of: file(in: directory))
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("block directory creation".utf8).write(to: directory)
        store.setRichDraft(rich("Unsaved"), in: "chat")
        try check(store.persistenceError != nil)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        store.setRichDraft(rich("Changed"), in: "chat")
        try check(store.persistenceError == nil)
        try check(try identity(of: file(in: directory)) != previousFileID)
        try check(try snapshot(at: file(in: directory)).richDrafts?["chat"] == rich("Changed"))
    }

    func exactSizeLimitPreservesTheLastSavedSnapshotAndRecovers() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = TeamsComposeStore(root: directory); store.connect(session())
        store.setRichDraft(rich("Keep this rich draft"), in: "rich")
        store.setDraft("x", in: "large")
        let overhead = try Data(contentsOf: file(in: directory)).count - 1
        let limit = String(repeating: "x", count: 2_000_000 - overhead)
        store.setDraft(limit, in: "large")
        try check(store.persistenceError == nil)
        let saved = try Data(contentsOf: file(in: directory))
        try check(saved.count == 2_000_000)
        store.setDraft(limit + "x", in: "large")
        try check(store.persistenceError != nil)
        try check(try Data(contentsOf: file(in: directory)) == saved)
        store.setDraft(limit, in: "large")
        try check(store.persistenceError == nil)
        store.setDraft("", in: "large")
        let reopened = TeamsComposeStore(root: directory); reopened.connect(session())
        try check(reopened.richDrafts["rich"] == rich("Keep this rich draft"))
        try check(reopened.draft(in: "large").isEmpty)
    }

    func pendingSendIsSavedBeforeHTTPAndUncertaintySurvivesRestart() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = PersistedSendTransport(file: file(in: directory))
        let store = TeamsComposeStore(root: directory, transport: transport); store.connect(session())
        store.setRichDraft(rich(), in: "chat")
        store.setRichDraft(rich(), in: "chat")
        try check(await store.sendDraft(in: "chat") == nil)
        let sentState = try require(await transport.snapshots.first)
        try check(sentState.outgoing["chat"]?.phase == .sending)
        try check(sentState.outgoing["chat"]?.richDraft == rich())
        try verifyRecovery(in: directory)
        let reopened = TeamsComposeStore(root: directory, transport: transport); reopened.connect(session())
        try check(reopened.outgoing["chat"]?.phase == .uncertain)
        try check(reopened.richDrafts["chat"] == rich())
        reopened.setRichDraft(rich(italic: true), in: "chat")
        let pending = try require(reopened.outgoing["chat"])
        reopened.reconcile([.init(id: "123", from: .string("8:orgid:" + account), clientMessageId: pending.clientMessageID)], in: "chat")
        let final = try snapshot(at: file(in: directory))
        try check(final.outgoing.isEmpty)
        try check(final.richDrafts?["chat"] == rich(italic: true))
    }

    func failedPendingSaveNeverReachesHTTPAfterAnIdenticalPublication() async throws {
        let directory = root(), backup = root()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: backup) }
        let transport = PersistedSendTransport(file: file(in: directory))
        let store = TeamsComposeStore(root: directory, transport: transport); store.connect(session())
        store.setRichDraft(rich(), in: "chat")
        store.setRichDraft(rich(), in: "chat")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("block directory creation".utf8).write(to: directory)
        try check(await store.sendDraft(in: "chat") == nil)
        try check(await transport.snapshots.isEmpty)
        try check(store.persistenceError != nil && store.errors["chat"] != nil)
        try check(store.outgoing.isEmpty && store.richDrafts["chat"] == rich())
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        store.setRichDraft(rich(), in: "chat")
        try check(store.persistenceError == nil && store.errors["chat"] == nil)
        try check(try snapshot(at: file(in: directory)).outgoing.isEmpty)
    }

    func editsAndAccountSwitchDuringSendSurviveRecovery() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = PersistedSendTransport(file: file(in: directory))
        let store = TeamsComposeStore(root: directory, transport: transport); store.connect(session())
        let initial = rich("Original")
        let edited = rich("Edited during request", italic: true)
        store.setRichDraft(initial, in: "chat")
        await transport.setDuringRequest { @MainActor in store.setRichDraft(edited, in: "chat") }
        try check(await store.sendDraft(in: "chat") == nil)
        try check(try snapshot(at: file(in: directory)).richDrafts?["chat"] == edited)
        try check(store.outgoing["chat"]?.richDraft == initial)
        try verifyRecovery(in: directory)
        let pending = try require(store.outgoing["chat"])
        store.reconcile([.init(id: "123", from: .string("8:orgid:" + account), clientMessageId: pending.clientMessageID)], in: "chat")
        try check(store.outgoing.isEmpty && store.richDrafts["chat"] == edited)

        let otherAccount = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let otherDraft = rich("Other account")
        let tenantID = tenant
        await transport.setDuringRequest { @MainActor in
            store.restore(accountID: otherAccount, tenantID: tenantID)
            store.setRichDraft(otherDraft, in: "chat")
        }
        try check(await store.sendDraft(in: "chat") == nil)
        try check(store.outgoing.isEmpty && store.richDrafts["chat"] == otherDraft)
        try check(try snapshot(at: file(in: directory)).outgoing["chat"]?.phase == .sending)
        try verifyRecovery(in: directory, account: otherAccount)
        try verifyRecovery(in: directory)
        store.connect(session())
        try check(store.outgoing["chat"]?.phase == .uncertain)
        try check(store.richDrafts["chat"] == edited)
    }
}

private struct ScenarioFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: Bool, file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition else { throw ScenarioFailure(description: "Failed at \(file):\(line)") }
}

private func require<Value>(_ value: Value?, file: StaticString = #fileID, line: UInt = #line) throws -> Value {
    guard let value else { throw ScenarioFailure(description: "Missing value at \(file):\(line)") }
    return value
}
