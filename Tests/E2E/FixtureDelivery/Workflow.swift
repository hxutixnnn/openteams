@main struct FixtureDelivery {
    static func session(_ account: String) -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!,
              accessToken: "fictional-only-" + account, expiresAt: .distantFuture,
              accountID: account, tenantID: "fixture-tenant", displayName: account,
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!,
                               accessToken: "fictional-only-" + account, expiresAt: .distantFuture))
    }

    @MainActor static func main() async throws {
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
