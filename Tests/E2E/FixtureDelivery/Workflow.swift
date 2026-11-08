@main struct FixtureDelivery {
    static func session(_ account: String) -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!,
              accessToken: "fictional-only-" + account, expiresAt: .distantFuture,
              accountID: account, tenantID: "fixture-tenant", displayName: account,
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!,
                               accessToken: "fictional-only-" + account, expiresAt: .distantFuture))
    }

    @MainActor static func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("Fixture did not reach its controlled hold")
    }

    @MainActor static func guards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-delivery-guards-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let observation = root.appendingPathComponent("send-observation.json")
        let transport = PerformanceFixtureTransport(allowsSend: true, sendObservationURL: observation, holdReply: true, holdSend: true)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        let chat = "fixture-one"
        await store.connect(session: session("fixture-a"))
        await store.loadConversation(chat)
        store.composer.setDraft("Fictional guarded reply", in: chat)
        store.composer.setReply(.init(messageID: "1800000000050", preview: "Context-only message 50", author: "Ada Example"), in: chat)
        let sending = Task { await store.sendDraft(in: chat) }
        try await waitUntil { await transport.replyRequests == 1 }
        precondition(store.composer.preparing.contains(chat) && !store.composer.canSend(in: chat))
        precondition(store.composer.draft(in: chat) == "Fictional guarded reply")
        let preparingDuplicate = await store.sendDraft(in: chat)
        precondition(preparingDuplicate == nil)
        let preparingAttempts = await transport.sendAttempts
        precondition(preparingAttempts == 0)
        await transport.releaseReply()
        try await waitUntil { await transport.sendAttempts == 1 }
        precondition(store.composer.outgoing[chat]?.phase == .sending && !store.composer.canSend(in: chat))
        for _ in 0..<3 {
            let duplicate = await store.sendDraft(in: chat)
            precondition(duplicate == nil)
        }
        let held = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: Data(contentsOf: observation))
        precondition(held["attempts"] == .number(1) && held["accepted"] == .number(0))
        precondition(held["replyRequests"] == .number(1))
        await transport.releaseSend()
        let sent = await sending.value
        precondition(sent != nil && store.composer.draft(in: chat).isEmpty && store.composer.replies[chat] == nil)
        let finalAttempts = await transport.sendAttempts
        let accepted = await transport.acceptedSends
        precondition(finalAttempts == 1 && accepted == 1)
        print("preparing_reply=true preparing_duplicate_blocked=true held_send_duplicates=3 attempts=1 accepted=1 draft_retained_until_acceptance=true native_ui=false")
        store.composer.setDraft("Fictional disconnected draft", in: chat)
        store.disconnect()
        let disconnected = await store.sendDraft(in: chat)
        precondition(disconnected == nil && !store.composer.canSend(in: chat))
        precondition(store.composer.draft(in: chat) == "Fictional disconnected draft")
        let disconnectedAttempts = await transport.sendAttempts
        precondition(disconnectedAttempts == finalAttempts)
        let closedTransport = PerformanceFixtureTransport(allowsSend: true, closedChat: true)
        let closedStore = TeamsReaderStore(cacheRoot: root.appendingPathComponent("closed"), transport: closedTransport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        await closedStore.connect(session: session("fixture-a"))
        await closedStore.loadConversation(chat)
        precondition(closedStore.conversation(chat)?.isDisabled == true)
        closedStore.composer.setDraft("Fictional closed draft", in: chat)
        let closed = await closedStore.sendDraft(in: chat)
        let closedAttempts = await closedTransport.sendAttempts
        precondition(closed == nil && closedAttempts == 0)
        precondition(closedStore.composer.draft(in: chat) == "Fictional closed draft")
        closedStore.disconnect()
        print("disconnected_send_blocked=true closed_send_blocked=true additional_posts=0 drafts_retained=true native_ui=false")
    }

    @MainActor static func main() async throws {
        try await guards()
        for outcome in [PerformanceFixtureTransport.SendOutcome.accepted, .uncertainAccepted, .uncertainAbsent] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-delivery-workflow-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let observation = root.appendingPathComponent("send-observation.json")
            let transport = PerformanceFixtureTransport(allowsSend: true, sendOutcome: outcome, sendDelay: 0.2, sendObservationURL: observation)
            let store = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
            let chat = "fixture-one"
            await store.connect(session: session("fixture-a"))
            await store.loadConversation(chat)
            store.composer.setDraft("Fictional delivery check", in: chat)
            let sending = Task { await store.composer.sendDraft(in: chat) }
            for _ in 0..<100 {
                if await transport.sendAttempts == 1 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            precondition(store.composer.outgoing[chat]?.phase == .sending)
            precondition(!store.composer.canSend(in: chat))
            _ = await store.composer.sendDraft(in: chat)
            _ = await sending.value
            let attempts = await transport.sendAttempts
            precondition(attempts == 1)
            if outcome == .accepted {
                precondition(store.composer.outgoing[chat] == nil && store.composer.draft(in: chat).isEmpty)
            } else {
                precondition(store.composer.outgoing[chat]?.phase == .uncertain)
                precondition(store.composer.draft(in: chat) == "Fictional delivery check")
                _ = await store.composer.sendDraft(in: chat)
                await store.refreshConversation(chat)
                if outcome == .uncertainAccepted {
                    precondition(store.composer.outgoing[chat] == nil && store.composer.draft(in: chat).isEmpty)
                } else {
                    precondition(store.composer.outgoing[chat]?.phase == .uncertain)
                    precondition(!store.composer.canSend(in: chat))
                    store.composer.acknowledgeUncertainDelivery(in: chat)
                    precondition(store.composer.canSend(in: chat))
                    precondition(store.composer.draft(in: chat) == "Fictional delivery check")
                }
            }
            let finalAttempts = await transport.sendAttempts
            let accepted = await transport.acceptedSends
            precondition(finalAttempts == 1 && accepted == (outcome == .uncertainAbsent ? 0 : 1))
            let recorded = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: Data(contentsOf: observation))
            precondition(recorded["attempts"] == .number(1))
            print("outcome=\(outcome.rawValue) held_guard=true attempts=\(finalAttempts) accepted=\(accepted) reconciliation=true production_store_transport=true native_ui=false")
            store.disconnect()
        }
    }
}
