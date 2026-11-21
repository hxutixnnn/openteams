import Foundation
import TeamsCore

actor FlakyTransport: HTTPTransport {
    var chatFailures: Int
    var messageFailures: Int
    let status: Int
    var chatRequests = 0
    var chatDelay: Duration = .zero
    func slowChats(_ delay: Duration) { chatDelay = delay }
    init(chatFailures: Int = 0, messageFailures: Int = 0, status: Int = 503) {
        self.chatFailures = chatFailures; self.messageFailures = messageFailures; self.status = status
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        var code = 200
        let data: Data
        if url.path.hasSuffix("/chats") {
            chatRequests += 1
            if chatDelay > .zero { try await Task.sleep(for: chatDelay) }
            if chatFailures > 0 { chatFailures -= 1; code = status }
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "fixture", title: "Healing", isOneOnOne: true)]))
        } else if url.path.hasSuffix("/messages") {
            if messageFailures > 0 { messageFailures -= 1; code = status }
            let message = TeamsWebMessage(id: "1800000000002", content: "Fresh", messageType: "Text")
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [message], messageToken: nil))
        } else { throw URLError(.unsupportedURL) }
        return (data, HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct HealingWorkflow {
    static func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

    static func session() -> TeamsWebSession {
        TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!,
                        accessToken: "fictional", expiresAt: .distantFuture, accountID: "fixture-a", tenantID: "fixture-tenant",
                        displayName: "Healing", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!,
                                                              accessToken: "fictional", expiresAt: .distantFuture))
    }

    @MainActor static func store(_ transport: FlakyTransport, root: URL) -> TeamsReaderStore {
        TeamsReaderStore(cacheRoot: root.appending(path: UUID().uuidString), transport: transport, mediaFactory: { _ in throw TeamsMediaError.unavailable })
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OpenTeams-healing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mapping: [(TeamsIncidentKind, TeamsHealAction)] = [(.networkFailure, .retryWithBackoff), (.expiredAuth, .refreshAuth),
            (.stalledSync, .reconnectSync), (.brokenUIState, .resetView), (.renderError, .resetView), (.crash, .restartSubsystem)]
        for (kind, action) in mapping { expect(TeamsHealAction(kind) == action, "\(kind) must heal with \(action)") }

        try await diagnosticsRecordsHealOutcomes(root: root)
        try await readerHealsRecoverableFailures(root: root)
        try await liveIncidentIsHealedInPlace(root: root)
        print("Heal mapping, outcome recording, in-flight suppression, retry, view reset, resync, and live heal workflows: PASS")
    }

    @MainActor static func diagnosticsRecordsHealOutcomes(root: URL) async throws {
        let log = TeamsIncidentLog(url: root.appending(path: "outcomes.json"))
        let diagnostics = TeamsDiagnostics(log: log, sentinelURL: root.appending(path: "outcomes-session"))
        var delivered: [TeamsIncidentRecord] = []
        diagnostics.onIncident = { delivered.append($0) }

        let unhealable = TeamsIncident(kind: .crash, subsystem: "app", signature: "uncleanExit")
        await diagnostics.report(unhealable)
        expect(delivered.last?.healAttempts == 0 && delivered.last?.lastHealSucceeded == nil, "Incidents without a healer must be delivered unhealed")
        expect(await log.escalation(for: unhealable.fingerprint) == .file, "Unhealed incident must escalate")

        var healerCalls = 0
        var healResult = true
        diagnostics.healers[.retryWithBackoff] = { incident in
            healerCalls += 1
            expect(diagnostics.healingFingerprints.contains(incident.fingerprint), "Heal must be marked in flight")
            await diagnostics.report(incident)
            return healResult
        }
        let failure = TeamsIncident(kind: .networkFailure, subsystem: "chatList", signature: "http 503")
        await diagnostics.report(failure)
        expect(healerCalls == 1, "Healer must run once per incident")
        expect(delivered.count == 2, "Reports during an in-flight heal must not be delivered")
        let healed = delivered.last!
        expect(healed.occurrences == 1, "Reports during an in-flight heal must not count as new occurrences")
        expect(healed.healAttempts == 1 && healed.heals == 1 && healed.lastHealSucceeded == true, "Delivered record must carry the heal outcome")
        expect(diagnostics.healingFingerprints.isEmpty, "Finished heal must clear the in-flight mark")
        expect(await log.escalation(for: failure.fingerprint) == .none, "Healed incident below the repeat threshold must not escalate")

        healResult = false
        await diagnostics.report(failure)
        expect(delivered.last?.healAttempts == 2 && delivered.last?.heals == 1 && delivered.last?.lastHealSucceeded == false, "Failed heal must be recorded")
        expect(await log.escalation(for: failure.fingerprint) == .file, "Failed heal must escalate")
        let persisted = await TeamsIncidentLog(url: root.appending(path: "outcomes.json")).records().first { $0.fingerprint == failure.fingerprint }
        expect(persisted?.healAttempts == 2 && persisted?.lastHealSucceeded == false, "Heal outcomes must persist")
    }

    @MainActor static func readerHealsRecoverableFailures(root: URL) async throws {
        let flaky = FlakyTransport(chatFailures: 3)
        let reader = store(flaky, root: root)
        await reader.connect(session: session())
        expect(reader.chatListError != nil, "Chat list failure must surface")
        expect(await reader.retryFailedReads(in: "chatList", delays: [0.05, 0.05, 0.05]), "Retry with backoff must heal a transient chat list failure")
        expect(reader.chatListError == nil && reader.chats.count == 1, "Healed chat list must show chats")
        reader.disconnect()

        let forbidden = store(FlakyTransport(chatFailures: 10, status: 403), root: root)
        await forbidden.connect(session: session())
        expect(!(await forbidden.retryFailedReads(in: "chatList", delays: [0.01, 0.01])), "Retry must report a persistent failure as unhealed")
        expect(!(await forbidden.resetFailedViews(in: "chatList")), "View reset must report a persistent failure as unhealed")
        forbidden.disconnect()
        expect(!(await forbidden.retryFailedReads(in: "chatList", delays: [0.01])), "Disconnected reader cannot heal")
        expect(!(await forbidden.resync()), "Disconnected reader cannot resync")

        let conversation = FlakyTransport(messageFailures: 1, status: 404)
        let broken = store(conversation, root: root)
        await broken.connect(session: session())
        await broken.loadConversation("fixture")
        expect(broken.chatErrors["fixture"] != nil, "Conversation failure must surface")
        expect(await broken.resetFailedViews(in: "conversation"), "Resetting the broken conversation view must heal it")
        expect(broken.chatErrors.isEmpty && broken.messages(in: "fixture").map(\.id) == ["1800000000002"], "Reset view must show fresh messages")
        let before = broken.lastRefreshedAt
        expect(await broken.resync(), "Resync must succeed when the chat list refreshes")
        expect(broken.lastRefreshedAt != before, "Resync must advance the refresh time")
        broken.disconnect()

        let slow = FlakyTransport()
        let busy = store(slow, root: root)
        await busy.connect(session: session())
        await slow.slowChats(.milliseconds(300))
        let scheduled = Task { await busy.refreshChats() }
        while !busy.isLoadingChats { await Task.yield() }
        expect(await busy.resync(), "Resync must wait for an in-flight list refresh instead of failing")
        await scheduled.value
        busy.disconnect()

        let retried = store(FlakyTransport(messageFailures: 2), root: root)
        await retried.connect(session: session())
        await retried.loadConversation("fixture")
        expect(retried.chatErrors["fixture"] != nil, "Transient conversation failure must surface")
        expect(await retried.retryFailedReads(in: "conversation", delays: [0.05, 0.05, 0.05]), "Retry must heal transient conversation failures")
        expect(retried.chatErrors.isEmpty, "Healed conversation must clear its error")
        retried.disconnect()
    }

    @MainActor static func liveIncidentIsHealedInPlace(root: URL) async throws {
        let log = TeamsIncidentLog(url: root.appending(path: "live.json"))
        let diagnostics = TeamsDiagnostics(log: log, sentinelURL: root.appending(path: "live-session"))
        let transport = FlakyTransport(chatFailures: 2)
        let reader = store(transport, root: root)
        reader.diagnostics = diagnostics
        var delivered: [TeamsIncidentRecord] = []
        diagnostics.onIncident = { delivered.append($0) }
        diagnostics.healers[.retryWithBackoff] = { incident in await reader.retryFailedReads(in: incident.subsystem, delays: [0.05, 0.05, 0.05]) }
        await reader.connect(session: session())
        let deadline = Date().addingTimeInterval(10)
        while delivered.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        expect(delivered.count == 1, "Live incident must be delivered once after healing")
        let record = delivered[0]
        expect(record.kind == .networkFailure && record.subsystem == "chatList", "Live incident must be classified")
        expect(record.occurrences == 1 && record.lastHealSucceeded == true && record.heals == 1, "Live heal must succeed and be recorded once")
        expect(reader.chatListError == nil && reader.chats.count == 1, "Reader must recover in place")
        expect(await log.escalation(for: record.fingerprint) == .none, "Healed live incident must not escalate")
        reader.disconnect()
    }
}
