import Foundation
import Observation
import TeamsCore

@main struct FixtureStartupConversation {
    static let tenant = "fixture-tenant"

    static func session(_ account: String) -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!,
              accessToken: "fictional-only-" + account, expiresAt: .distantFuture,
              accountID: account, tenantID: tenant, displayName: account,
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!,
                               accessToken: "fictional-only-" + account, expiresAt: .distantFuture))
    }

    @MainActor static func awaitHold(_ gate: TeamsCachedLoadGate) async -> TeamsCachedLoadGate.Request {
        if let held = gate.held { return held }
        return await withCheckedContinuation { continuation in
            withObservationTracking { _ = gate.held } onChange: {
                Task { @MainActor in
                    guard let held = gate.held else { preconditionFailure("Hold ended before observation") }
                    continuation.resume(returning: held)
                }
            }
        }
    }

    @MainActor static func selectStartup(_ startup: PerformanceFixtureStartupConversation, in store: TeamsReaderStore, other: String) async {
        precondition(store.chats.map(\.id) == ["fixture-one", "fixture-two"])
        precondition(store.chats.allSatisfy { $0.lastMessage == nil })
        let legacy = store.chats.first { $0.hidden != true && $0.isConversationDeleted != true }
        let selected = startup.initialChat(in: store.chats)!
        if startup == .project { precondition(selected == legacy) }
        precondition(selected.id == (startup == .planning ? "fixture-two" : "fixture-one"))
        precondition(store.messages(in: other).isEmpty && !store.isLoadingConversation(other))
        await store.loadConversation(selected.id)
        precondition(store.messages(in: selected.id).count == 2000 && store.messages(in: other).isEmpty)
    }

    @MainActor static func main() async throws {
        try await run("project-success", startup: .planning, account: "fixture-a", allowsSend: true)
        try await run("project-rejection", startup: .planning, account: "fixture-a", allowsSend: false)
        try await run("clean-b-planning", startup: .project, account: "fixture-b", allowsSend: true)
        print("FIXTURE_STARTUP_CONVERSATION_OK")
    }

    @MainActor static func run(_ role: String, startup: PerformanceFixtureStartupConversation, account: String, allowsSend: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-startup-e2e-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = startup == .planning ? "fixture-one" : "fixture-two"
        let initial = startup == .planning ? "fixture-two" : "fixture-one"
        let preparationTransport = PerformanceFixtureTransport(allowsSend: allowsSend)
        let preparation = TeamsReaderStore(cacheRoot: root, transport: preparationTransport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        let richDrafts = Dictionary(uniqueKeysWithValues: ["fixture-a", "fixture-b"].map { account in
            (account, TeamsRichDraft(blocks: [.init(runs: [.init(text: "Unique " + role + " " + account + " rich draft 👋", bold: true)])]))
        })
        for owner in ["fixture-a", "fixture-b"] {
            let cache = TeamsReadCache(root: root, accountID: owner, tenantID: tenant)
            let messages = await preparationTransport.cachedMessages(count: 2000, account: owner)
            for chat in ["fixture-one", "fixture-two"] {
                try await cache.save(.init(messages: messages, messageToken: "older"), in: chat)
            }
            await preparation.connect(session: session(owner))
            await selectStartup(startup, in: preparation, other: target)
            await preparation.loadConversation(target)
            preparation.composer.setRichDraft(richDrafts[owner]!, in: target)
            await preparation.loadConversation(initial)
        }
        preparation.disconnect()
        let gate = TeamsCachedLoadGate()
        let transport = PerformanceFixtureTransport(allowsSend: allowsSend, gate: gate)
        let store = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        store.cachedLoadGate = gate
        await store.connect(session: session("fixture-a"))
        await selectStartup(startup, in: store, other: target)
        precondition(store.composer.richDrafts[target] == richDrafts["fixture-a"])
        if account == "fixture-b" {
            await store.connect(session: session(account))
            await selectStartup(startup, in: store, other: target)
        }
        precondition(store.composer.richDrafts[target] == richDrafts[account])
        let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
        for chat in ["fixture-one", "fixture-two"] { await transport.reserveSendIDs(try await cache.history(in: chat).messages) }
        gate.arm(accountScope: store.accountScope, accountRevision: store.accountRevision)
        let load = Task { @MainActor in await store.loadConversation(target) }
        let held = await awaitHold(gate)
        precondition(held.chatID == target && held.accountScope == tenant + ":" + account)
        precondition(store.messages(in: target).isEmpty && store.isLoadingConversation(target) && store.composer.canSend(in: target))
        let before = try await cache.history(in: target)
        precondition(before.messages.count == 2000 && before.messageToken == "older")
        precondition(before.messages.map(\.id) == (81...2080).map { String(1_800_000_000_000 + $0) })
        precondition(before.messages.first { $0.id == "1800000000101" }?.messageType == "RichText/Html")
        let sent = await store.sendDraft(in: target)
        precondition(gate.held == held && store.isLoadingConversation(target))
        let during = try await cache.history(in: target)
        precondition(Array(during.messages.prefix(2000)) == before.messages && during.messageToken == "older")
        precondition(during.messages.count == (allowsSend ? 2001 : 2000))
        let posts = gate.events.filter { $0.name.hasPrefix("post_") }
        precondition(posts.count == 2 && posts.allSatisfy { $0.holdPending && $0.request == held })
        precondition(posts.last?.status == (allowsSend ? 201 : 404))
        if allowsSend {
            let html = try richDrafts[account]!.serialize().html
            precondition(sent == during.messages.last?.id && during.messages.last?.content == html)
            precondition(during.messages.last?.from?.stringValue == "8:orgid:" + account && store.composer.draft(in: target).isEmpty)
        } else { precondition(sent == nil && store.composer.richDrafts[target] == richDrafts[account]) }
        gate.release(held, accountScope: store.accountScope, accountRevision: store.accountRevision)
        await load.value
        let after = try await cache.history(in: target)
        precondition(after.messages == during.messages && after.messageToken == during.messageToken && !store.isLoadingConversation(target))
        let neighbor = try await cache.history(in: initial)
        precondition(neighbor.messages.count == 2000 && neighbor.messageToken == "older")
        let otherAccount = account == "fixture-a" ? "fixture-b" : "fixture-a"
        await store.connect(session: session(otherAccount))
        await selectStartup(startup, in: store, other: target)
        precondition(store.composer.richDrafts[target] == richDrafts[otherAccount])
        store.disconnect()
        let recovered = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        await recovered.connect(session: session(account))
        await selectStartup(startup, in: recovered, other: target)
        precondition(allowsSend ? recovered.composer.draft(in: target).isEmpty : recovered.composer.richDrafts[target] == richDrafts[account])
        await recovered.loadConversation(target)
        precondition(recovered.messages(in: target).map(\.id) == after.messages.map(\.id))
        if let path = ProcessInfo.processInfo.environment["OPENTEAMS_STARTUP_EVIDENCE"] {
            let directory = URL(fileURLWithPath: path)
            try JSONEncoder().encode(before).write(to: directory.appendingPathComponent(role + "-before.json"))
            try JSONEncoder().encode(during).write(to: directory.appendingPathComponent(role + "-held-result.json"))
            try JSONEncoder().encode(after).write(to: directory.appendingPathComponent(role + "-after.json"))
            try JSONEncoder().encode(gate.events).write(to: directory.appendingPathComponent(role + "-trace.json"))
        }
        recovered.disconnect()
        print("role=\(role) startup=\(initial) cold_target=\(target) account=\(account) pre=\(before.messages.count) post=\(after.messages.count) rich_101_preserved=true restored_drafts=true held_posts=2")
    }
}
