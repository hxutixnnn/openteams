@main struct FixtureDeletion {
    static func session(_ account: String) -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!,
              accessToken: "fictional-only-" + account, expiresAt: .distantFuture,
              accountID: account, tenantID: "fixture-tenant", displayName: account,
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!,
                               accessToken: "fictional-only-" + account, expiresAt: .distantFuture))
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-deletion-workflow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PerformanceFixtureTransport()
        let store = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        let chat = "fixture-one"
        let plainID = "1800000000101"
        let editedID = "1800000000100"
        let neighborID = "1800000000098"
        let cache = TeamsReadCache(root: root, accountID: "fixture-a", tenantID: "fixture-tenant")
        await store.connect(session: session("fixture-a"))
        await store.loadConversation(chat)
        await transport.append()
        await store.refreshConversation(chat)
        precondition(store.messages(in: chat).last?.id == plainID)
        store.composer.setDraft("Fictional deletion workflow draft", in: chat)
        let before = try await cache.history(in: chat)
        let neighbor = before.messages.first { $0.id == neighborID }!
        let edit = try await store.beginMessageEdit(in: chat, messageID: editedID, accountScope: store.accountScope)
        edit.document = .init(plainText: "Fictional edited row before deletion")
        await store.saveMessageEdit(edit)
        precondition(edit.completed)
        for (id, expectedVersion) in [(plainID, "2"), (editedID, "3")] {
            await store.messageAction("delete", chatID: chat, messageID: id,
                                      accountScope: store.accountScope, accountRevision: store.accountRevision)
            for _ in 0..<50 {
                await store.checkDeletion(in: chat, messageID: id)
                if store.messages(in: chat).first(where: { $0.id == id })?.isDeleted == true,
                   store.deletionStage(in: chat, messageID: id) == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let saved = try await cache.history(in: chat)
            let target = saved.messages.first { $0.id == id }!
            precondition(target.version == expectedVersion && TeamsRenderedMessage(target).isDeleted)
            let pending = try await cache.pendingDeletion(in: chat, messageID: id)
            precondition(pending == nil && store.deletionStage(in: chat, messageID: id) == nil)
            precondition(store.deletionMessage(in: chat, messageID: id) == nil)
            precondition(!store.canDelete(in: chat, messageID: id))
            precondition(saved.messages.first { $0.id == neighborID } == neighbor)
            precondition(saved.messages.count == before.messages.count)
            precondition(store.composer.draft(in: chat) == "Fictional deletion workflow draft")
            print("deleted=\(id) version=\(expectedVersion) tombstone=true pending=false neighbor_unchanged=true draft_retained=true")
        }
        await store.loadConversation("fixture-two")
        precondition(!store.messages(in: "fixture-two").contains(where: \.isDeleted))
        await store.connect(session: session("fixture-b"))
        await store.loadConversation(chat)
        precondition(!store.messages(in: chat).contains(where: \.isDeleted))
        precondition(store.composer.draft(in: chat).isEmpty)
        await store.connect(session: session("fixture-a"))
        await store.loadConversation(chat)
        precondition(store.messages(in: chat).filter(\.isDeleted).count == 2)
        precondition(store.composer.draft(in: chat) == "Fictional deletion workflow draft")
        let pendingEdit = try await cache.pendingEdit(in: chat, messageID: editedID)
        precondition(pendingEdit == nil)
        store.disconnect()
        print("account_conversation_isolation=true reconnect_tombstones=true production_transport_store_cache=true native_ui=false")
    }
}
