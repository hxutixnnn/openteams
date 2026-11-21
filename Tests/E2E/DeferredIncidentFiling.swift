import Foundation
import TeamsCore

private actor Token: GitHubTokenSource {
    var available = false
    func setAvailable() { available = true }
    func gitHubToken() async throws -> String? { available ? "fictional-github-token" : nil }
}

private actor IssueTransport: HTTPTransport {
    var offline = false
    var limited = false
    var requests: [URLRequest] = []
    func setOffline(_ value: Bool) { offline = value }
    func setLimited(_ value: Bool) { limited = value }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        let url = request.url!
        if limited {
            return (Data(), HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!)
        }
        try await Task.sleep(for: .milliseconds(20))
        let search = request.httpMethod == "GET"
        let payload: [String: Any] = search ? ["items": []] : ["number": 42, "html_url": "https://github.com/hxutixnnn/openteams/issues/42", "state": "open"]
        return (try JSONSerialization.data(withJSONObject: payload), HTTPURLResponse(url: url, statusCode: search ? 200 : 201, httpVersion: nil, headerFields: nil)!)
    }
}

private actor UnavailableToken: GitHubTokenSource {
    let throwsError: Bool
    var available = false
    var waiters: [CheckedContinuation<String?, Never>] = []
    var invocations = 0

    init(throwsError: Bool) { self.throwsError = throwsError }
    func setAvailable() { available = true }
    func finishFirstLookup() {
        waiters.removeFirst().resume(returning: "late-fictional-token")
    }
    func finishLookup() {
        for waiter in waiters { waiter.resume(returning: "late-fictional-token") }
        waiters = []
    }
    func gitHubToken() async throws -> String? {
        invocations += 1
        if available { return "fictional-github-token" }
        if throwsError { throw URLError(.userAuthenticationRequired) }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date()
}

@main struct DeferredIncidentFiling {
    static func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OpenTeams-deferred-filing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graceToken = Token()
        let graceTransport = IssueTransport()
        let graceLog = TeamsIncidentLog(url: root.appending(path: "grace.json"))
        let graceReporter = TeamsIncidentReporter(log: graceLog, client: GitHubIssueClient(tokenSource: graceToken, transport: graceTransport))
        let grace = TeamsDiagnostics(log: graceLog, sentinelURL: root.appending(path: "grace-session"), healGracePeriod: .seconds(60))
        grace.reporter = graceReporter
        let fresh = TeamsIncident(kind: .networkFailure, subsystem: "chatList", signature: "fresh")
        try await graceLog.record(fresh)
        await graceToken.setAvailable()
        await grace.retryPendingEscalations()
        expect(await graceTransport.requests.isEmpty, "Retry must not escalate a fresh incident with no heal result")
        let recurring = TeamsIncident(kind: .networkFailure, subsystem: "conversation", signature: "recurring")
        await graceTransport.setOffline(true)
        try await graceLog.record(recurring)
        expect(await graceReporter.escalate(fingerprint: recurring.fingerprint) == .deferred, "Failed filing must be retryable")
        await graceTransport.setOffline(false)
        let graceRequests = await graceTransport.requests.count
        await grace.report(recurring)
        await grace.retryPendingEscalations()
        expect(await graceTransport.requests.count == graceRequests, "Retry must preserve a new healing window even after an earlier deferral")
        try await graceLog.recordHeal(fingerprint: recurring.fingerprint, succeeded: true)
        await graceReporter.retryDeferred()
        expect(await graceTransport.requests.count == graceRequests, "Retry must skip a deferred incident healed below threshold")
        print("Deferred retry eligibility: fresh incidents, renewed grace windows and healed deferred incidents stay unfiled: PASS")
        for throwsError in [false, true] {
            let token = UnavailableToken(throwsError: throwsError)
            let transport = IssueTransport()
            let log = TeamsIncidentLog(url: root.appending(path: "unavailable-\(throwsError).json"))
            let source = TimedGitHubTokenSource(source: token, timeout: .milliseconds(100))
            let reporter = TeamsIncidentReporter(log: log, client: GitHubIssueClient(tokenSource: source, transport: transport))
            let diagnostics = TeamsDiagnostics(log: log, sentinelURL: root.appending(path: "unavailable-session"))
            diagnostics.reporter = reporter
            let incident = TeamsIncident(kind: .networkFailure, subsystem: "conversation", signature: "network")
            try await log.record(incident)
            let start = ContinuousClock.now
            expect(await reporter.escalate(fingerprint: incident.fingerprint) == .deferred, "Hung or throwing token lookup must defer")
            let elapsed = start.duration(to: .now)
            expect(elapsed < .seconds(2), "Token lookup must return within timeout bound")
            if !throwsError { expect(elapsed >= .milliseconds(100), "Hung lookup must wait for timeout") }
            expect(await transport.requests.isEmpty, "Unavailable token must not send HTTP requests")
            if !throwsError {
                await withTaskGroup(of: String?.self) { group in
                    for _ in 0..<8 { group.addTask { await source.gitHubToken() } }
                    for await token in group { expect(token == nil, "Every joined hung lookup must time out") }
                }
                expect(await source.gitHubToken() == nil, "Later hung lookup must still time out")
                expect(await token.invocations == 1, "Concurrent and repeated timeouts must share one source invocation")
            }
            await token.setAvailable()
            await source.reset()
            let recoveryStart = ContinuousClock.now
            expect(await source.gitHubToken() == "fictional-github-token", "Reset must read the replacement token while the old lookup is hung")
            expect(recoveryStart.duration(to: .now) < .seconds(2), "Replacement token lookup must remain bounded")
            async let first: Void = diagnostics.retryPendingEscalations()
            async let second: Void = diagnostics.retryPendingEscalations()
            _ = await (first, second)
            await diagnostics.retryPendingEscalations()
            let requests = await transport.requests
            expect(requests.count == 2 && requests.filter { $0.httpMethod == "POST" }.count == 1, "Lookup failure must release reservation so retry creates exactly once")
            expect(await log.escalation(for: incident.fingerprint) == .none, "Recovered lookup must mark incident reported")
            await token.finishLookup()
        }
        print("Deferred token lookup: single-flight hung source, bounded joined lookups, throwing source, released reservation and retry recovery: PASS")
        let staleToken = UnavailableToken(throwsError: false)
        let resetSource = TimedGitHubTokenSource(source: staleToken, timeout: .milliseconds(100))
        expect(await resetSource.gitHubToken() == nil, "Original hung lookup must time out")
        await resetSource.reset()
        expect(await resetSource.gitHubToken() == nil, "Reset must allow a new pending lookup")
        expect(await staleToken.invocations == 2, "Reset must start exactly one new source invocation")
        await staleToken.finishFirstLookup()
        for _ in 0..<3 {
            expect(await resetSource.gitHubToken() == nil, "New pending lookup must remain bounded after old completion")
        }
        expect(await staleToken.invocations == 2, "Late old completion must not clear the newer pending lookup")
        await staleToken.setAvailable()
        await resetSource.reset()
        expect(await resetSource.gitHubToken() == "fictional-github-token", "Another reset must recover from the newer hung lookup")
        await staleToken.finishLookup()
        print("Token lookup reset: replacement token recovery, bounded retries and late completion preserving newer single-flight lookup: PASS")
        for missingToken in [false, true] {
            let token = Token()
            let transport = IssueTransport()
            let log = TeamsIncidentLog(url: root.appending(path: "pending-\(missingToken).json"))
            let reporter = TeamsIncidentReporter(log: log, client: GitHubIssueClient(tokenSource: token, transport: transport))
            let diagnostics = TeamsDiagnostics(log: log, sentinelURL: root.appending(path: "session"))
            diagnostics.reporter = reporter
            await diagnostics.retryPendingEscalations()
            expect(await transport.requests.isEmpty, "Empty log must not send requests")
            if !missingToken {
                await token.setAvailable()
                await transport.setOffline(true)
            }
            let incident = TeamsIncident(kind: .networkFailure, subsystem: "conversation", signature: "network")
            try await log.record(incident)
            expect(await reporter.escalate(fingerprint: incident.fingerprint) == .deferred, "Unavailable filing must defer")
            expect(await log.escalation(for: incident.fingerprint) == .file, "Deferred incident must stay eligible")
            let failedRequests = await transport.requests
            expect(failedRequests.count == (missingToken ? 0 : 1), "Missing token must not send; offline transport must be attempted")
            await token.setAvailable()
            await transport.setOffline(false)
            async let first: Void = diagnostics.retryPendingEscalations()
            async let second: Void = diagnostics.retryPendingEscalations()
            _ = await (first, second)
            await diagnostics.retryPendingEscalations()
            await diagnostics.retryPendingEscalations()
            let requests = await transport.requests
            let creates = requests.filter { $0.httpMethod == "POST" }
            expect(creates.count == 1, "Concurrent and repeated retries must create exactly one issue")
            expect(requests.count == failedRequests.count + 2, "Reported occurrences must not send more requests")
            expect(creates[0].url!.path == "/repos/hxutixnnn/openteams/issues", "Retry must create an issue, not a comment")
            let payload = try JSONSerialization.jsonObject(with: creates[0].httpBody!) as! [String: Any]
            expect(payload["labels"] as? [String] == ["auto", "bug"], "Retry must preserve automatic labels")
            expect(await log.escalation(for: incident.fingerprint) == .none, "Retry must persist reported occurrences")
            let healed = TeamsIncident(kind: .brokenUIState, subsystem: "chatList", signature: "invalidResponse")
            try await log.record(healed)
            try await log.recordHeal(fingerprint: healed.fingerprint, succeeded: true)
            await diagnostics.retryPendingEscalations()
            expect(await transport.requests.count == requests.count, "Healed incident below threshold must not file")
        }
        let clock = Clock()
        let token = Token()
        await token.setAvailable()
        let transport = IssueTransport()
        await transport.setLimited(true)
        let log = TeamsIncidentLog(url: root.appending(path: "limited.json"), now: { clock.now })
        let reporter = TeamsIncidentReporter(log: log, client: GitHubIssueClient(tokenSource: token, transport: transport), now: { clock.now })
        let diagnostics = TeamsDiagnostics(log: log, sentinelURL: root.appending(path: "limited-session"))
        diagnostics.reporter = reporter
        let incident = TeamsIncident(kind: .expiredAuth, subsystem: "chatList", signature: "http 401")
        try await log.record(incident)
        expect(await reporter.escalate(fingerprint: incident.fingerprint) == .deferred, "Rate limit must defer")
        let limitedCount = await transport.requests.count
        await transport.setLimited(false)
        await diagnostics.retryPendingEscalations()
        expect(await transport.requests.count == limitedCount, "Retry must honor rate-limit pause")
        clock.now += 61
        await diagnostics.retryPendingEscalations()
        await diagnostics.retryPendingEscalations()
        expect(await transport.requests.count == limitedCount + 2, "Retry after pause must search and create once")
        print("Deferred incident filing: offline recovery, token availability, concurrent and repeated retry, empty log, healed suppression, rate-limit pause and recovery: PASS")
    }
}
