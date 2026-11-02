import Foundation
import TeamsCore
import Observation

@main struct CachedLoadHold {
    static let tenant = "fixture-tenant"
    static let chat = "fixture-two"
    static let rich = TeamsRichDraft(blocks: [.init(runs: [.init(text: "Held fictional draft Xin chào 👋", bold: true)])])

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
            withObservationTracking {
                _ = gate.held
            } onChange: {
                Task { @MainActor in
                    guard let held = gate.held else { preconditionFailure("Hold ended before observation") }
                    continuation.resume(returning: held)
                }
            }
        }
    }

    @MainActor static func main() async throws {
        for mode in ["success", "rejection", "cancel", "account", "disconnect", "quit", "concurrent", "unarmed", "disabled"] {
            try await run(mode)
        }
        print("CACHED_LOAD_HOLD_OK")
    }

    @MainActor static func run(_ mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-hold-workflow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = TeamsCachedLoadGate(traceURL: root.appendingPathComponent("trace.jsonl"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = PerformanceFixtureTransport(allowsSend: mode != "rejection", gate: mode == "disabled" ? nil : gate)
        let cache = TeamsReadCache(root: root, accountID: "fixture-a", tenantID: tenant)
        let other = TeamsReadCache(root: root, accountID: "fixture-b", tenantID: tenant)
        let originals = await transport.cachedMessages(count: 2000, account: "fixture-a")
        let originalsB = await transport.cachedMessages(count: 2000, account: "fixture-b")
        for id in ["fixture-one", chat] {
            try await cache.save(.init(messages: originals, messageToken: "older"), in: id)
            try await other.save(.init(messages: originalsB, messageToken: "older"), in: id)
        }
        let store = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        store.cachedLoadGate = mode == "disabled" ? nil : gate
        await store.connect(session: session("fixture-a"))
        store.composer.setRichDraft(rich, in: chat)
        if !["disabled", "unarmed"].contains(mode) { gate.arm(accountScope: store.accountScope, accountRevision: store.accountRevision) }
        let load = Task { @MainActor in await store.loadConversation(chat) }
        if ["disabled", "unarmed"].contains(mode) {
            await load.value
            precondition(gate.held == nil && !gate.armed && store.messages(in: chat).count == 2000)
            precondition(!store.isLoadingConversation(chat))
            if mode == "disabled" { precondition(gate.events.isEmpty) }
        } else {
            let held = await awaitHold(gate)
            precondition(held.accountScope == store.accountScope && held.chatID == chat)
            precondition(store.isLoadingConversation(chat) && store.messages(in: chat).isEmpty)
            precondition(store.composer.canSend(in: chat))
            gate.arm(accountScope: "fixture-tenant:fixture-b", accountRevision: UUID())
            precondition(gate.held == held && !gate.armed)
            gate.release(held, accountScope: "fixture-tenant:fixture-b", accountRevision: UUID())
            precondition(gate.held == held)
            switch mode {
            case "success", "rejection":
                let sent = await store.sendDraft(in: chat)
                precondition(gate.held == held && store.isLoadingConversation(chat))
                let postEvents = gate.events.filter { $0.name.hasPrefix("post_") }
                precondition(postEvents.count == 2 && postEvents.allSatisfy { $0.holdPending && $0.request == held })
                precondition(postEvents[0].name == "post_attempt" && postEvents[1].status == (mode == "success" ? 201 : 404))
                let during = try await cache.history(in: chat)
                precondition(during.messages.count == (mode == "success" ? 2001 : 2000) && during.messageToken == "older")
                if mode == "success" {
                    precondition(sent != nil && store.composer.draft(in: chat).isEmpty)
                    precondition(during.messages.last?.from?.stringValue == "8:orgid:fixture-a")
                    let html = try rich.serialize().html
                    precondition(during.messages.last?.content == html)
                } else {
                    precondition(sent == nil && store.composer.richDrafts[chat] == rich)
                    precondition(store.composer.errors[chat] != nil)
                }
                gate.release(held, accountScope: store.accountScope, accountRevision: store.accountRevision)
            case "cancel":
                load.cancel()
            case "account":
                await store.connect(session: session("fixture-b"))
            case "disconnect":
                store.disconnect()
            case "quit":
                gate.invalidate(reason: "quit")
            case "concurrent":
                await store.loadConversation("fixture-one")
                precondition(gate.held == held && store.messages(in: "fixture-one").count == 2000)
                gate.release(held, accountScope: store.accountScope, accountRevision: store.accountRevision)
            default: preconditionFailure(mode)
            }
            await load.value
            precondition(gate.held == nil && !gate.armed && !store.isLoadingConversation(chat))
            if ["cancel", "disconnect", "account", "quit"].contains(mode) {
                precondition(store.messages(in: chat).isEmpty)
                if mode == "account" {
                    await store.loadConversation(chat)
                    precondition(store.accountID == "fixture-b" && store.messages(in: chat).map(\.id) == originalsB.map(\.id))
                    let savedB = try await other.history(in: chat)
                    precondition(savedB.messages.count == 2000)
                    precondition(savedB.messages.filter { Int64($0.id)! > 1_800_000_000_100 } == Array(originalsB.dropFirst(20)))
                } else if mode == "disconnect" {
                    await store.connect(session: session("fixture-a"))
                    await store.loadConversation(chat)
                    precondition(store.messages(in: chat).count == 2000)
                } else {
                    gate.arm(accountScope: store.accountScope, accountRevision: store.accountRevision)
                    let retry = Task { @MainActor in await store.loadConversation(chat) }
                    let retried = await awaitHold(gate)
                    precondition(retried.id != held.id)
                    gate.release(held, accountScope: store.accountScope, accountRevision: store.accountRevision)
                    precondition(gate.held == retried)
                    gate.release(retried, accountScope: store.accountScope, accountRevision: store.accountRevision)
                    await retry.value
                    precondition(store.messages(in: chat).count == 2000)
                }
            }
        }
        let saved = try await cache.history(in: chat)
        let count = mode == "success" ? 2001 : 2000
        precondition(saved.messages.count == count && Set(saved.messages.map(\.id)).count == count && saved.messageToken == "older")
        precondition(Array(saved.messages.prefix(2000)).map(\.id) == originals.map(\.id))
        precondition(saved.messages.filter { Int64($0.id)! > 1_800_000_000_100 && Int64($0.id)! <= 1_800_000_002_080 } == Array(originals.dropFirst(20)))
        var recent = URLRequest(url: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture/v1/users/ME/conversations/fixture-two/messages")!)
        recent.setValue("Bearer fictional-only-fixture-a", forHTTPHeaderField: "Authorization")
        let (recentData, _) = try await transport.data(for: recent)
        let replacements = try JSONDecoder().decode(TeamsWebMessagePage.self, from: recentData).messages
        for original in originals {
            let actual = saved.messages.first { $0.id == original.id }
            precondition(actual == original || actual == replacements.first { $0.id == original.id })
        }
        let neighbor = try await cache.history(in: "fixture-one")
        precondition(neighbor.messages.count == 2000 && neighbor.messageToken == "older")
        let recovery = TeamsReaderStore(cacheRoot: root, transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
        await recovery.connect(session: session("fixture-a"))
        await recovery.loadConversation(chat)
        precondition(recovery.messages(in: chat).map(\.id) == saved.messages.map(\.id))
        precondition(mode == "success" ? recovery.composer.draft(in: chat).isEmpty : recovery.composer.richDrafts[chat] == rich)
        precondition(gate.events.enumerated().allSatisfy { $0.element.sequence == $0.offset + 1 && $0.element.runID == gate.runID })
        precondition(zip(gate.events, gate.events.dropFirst()).allSatisfy { $0.uptime <= $1.uptime })
        precondition(gate.traceError == nil && store.cacheWarning == nil)
        if !gate.events.isEmpty {
            let lines = try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8).split(separator: "\n")
            precondition(lines.count == gate.events.count)
            for line in lines { _ = try JSONDecoder().decode(TeamsCachedLoadGate.Event.self, from: Data(line.utf8)) }
        }
        if let path = ProcessInfo.processInfo.environment["OPENTEAMS_HOLD_EVIDENCE"] {
            let output = URL(fileURLWithPath: path).appendingPathComponent(mode + "-trace.json")
            precondition(!FileManager.default.fileExists(atPath: output.path))
            try JSONEncoder().encode(gate.events).write(to: output)
        }
        print("mode=\(mode) saved=\(saved.messages.count) recovered=\(recovery.messages(in: chat).count) ordered_trace_events=\(gate.events.count)")
        for event in gate.events { print(String(decoding: try JSONEncoder().encode(event), as: UTF8.self)) }
        store.disconnect(); recovery.disconnect()
    }
}
