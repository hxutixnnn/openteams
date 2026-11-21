import Foundation
import TeamsCore

private actor IssueTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var openIssueBody: String?
    var failure: Int?
    func setOpenIssue(_ body: String?) { openIssueBody = body }
    func setFailure(_ status: Int?) { failure = status }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        if let failure {
            return (Data(), HTTPURLResponse(url: url, statusCode: failure, httpVersion: nil, headerFields: ["Retry-After": "60"])!)
        }
        try await Task.sleep(for: .milliseconds(20))
        let payload: Any
        let status: Int
        if url.path == "/search/issues" {
            payload = ["items": openIssueBody.map { [["number": 7, "html_url": "https://github.com/hxutixnnn/openteams/issues/7", "state": "open", "body": $0]] } ?? []]
            status = 200
        } else if url.path.hasSuffix("/comments") {
            payload = ["id": 1]; status = 201
        } else {
            payload = ["number": 42, "html_url": "https://github.com/hxutixnnn/openteams/issues/42", "state": "open"]; status = 201
        }
        return (try JSONSerialization.data(withJSONObject: payload), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct Token: GitHubTokenSource {
    let value: String?
    func gitHubToken() async throws -> String? { value }
}

private struct LeakyFailure: Error, CustomStringConvertible {
    var description: String { "skypetoken=abc.def.ghi minh.tran@contoso.com Lunch with Minh" }
}

private final class Clock: @unchecked Sendable {
    var now = Date()
}

@main struct IncidentIssueFiling {
    static func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

    static func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    @MainActor static func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 where !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
        expect(await condition(), "Timed out waiting for escalation")
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OpenTeams-incident-filing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = GitHubIssueEnvironment(appVersion: "0.2.13 (16)", appRevision: String(repeating: "b", count: 40), osVersion: "macOS 27.0")
        let clock = Clock()
        let transport = IssueTransport()
        let log = TeamsIncidentLog(url: root.appending(path: "incidents.json"), now: { clock.now })
        let client = GitHubIssueClient(tokenSource: Token(value: "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz"), transport: transport)
        let reporter = TeamsIncidentReporter(log: log, client: client, environment: environment, bumpInterval: 3600, now: { clock.now })

        let unconfiguredLog = TeamsIncidentLog(url: root.appending(path: "unconfigured.json"))
        let unconfigured = TeamsIncidentReporter(log: unconfiguredLog, client: GitHubIssueClient(tokenSource: Token(value: nil), transport: transport), environment: environment)
        let pending = try await unconfiguredLog.record(TeamsIncident(kind: .crash, subsystem: "app", signature: "uncleanExit"))
        expect(await unconfigured.escalate(fingerprint: pending.fingerprint) == .deferred, "Missing token must defer filing")
        expect(await transport.requests.isEmpty, "Missing token must not send requests")
        expect(await unconfiguredLog.escalation(for: pending.fingerprint) == .file, "Deferred incident must stay unreported")

        let healed = try await log.record(TeamsIncident(kind: .networkFailure, subsystem: "chatList", signature: "network"))
        try await log.recordHeal(fingerprint: healed.fingerprint, succeeded: true)
        expect(await reporter.escalate(fingerprint: healed.fingerprint) == .skipped, "Healed incident below the repeat threshold must not file")
        expect(await transport.requests.isEmpty, "Healed incident sent a request")
        try await log.record(TeamsIncident(kind: .networkFailure, subsystem: "chatList", signature: "network"))
        expect(await log.escalation(for: healed.fingerprint) == .file, "A fresh failure after a heal must be unhealed again")
        try await log.recordHeal(fingerprint: healed.fingerprint, succeeded: true)

        let diagnostics = TeamsDiagnostics(log: log, sentinelURL: root.appending(path: "session-active"), healGracePeriod: .milliseconds(30))
        diagnostics.reporter = reporter
        let incident = TeamsIncident(error: LeakyFailure(), subsystem: "conversation")!
        await diagnostics.report(incident)
        await diagnostics.report(incident)
        try await waitFor { await log.records().first { $0.fingerprint == incident.fingerprint }?.issueNumber == 42 }
        var requests = await transport.requests
        expect(requests.map { $0.httpMethod! + " " + $0.url!.path } == ["GET /search/issues", "POST /repos/hxutixnnn/openteams/issues"], "Unhealed incident must search once then file once: \(requests.map(\.url))")
        let issue = body(requests[1])
        let title = issue["title"] as! String
        let text = title + (issue["body"] as! String)
        expect(issue["labels"] as! [String] == ["auto", "bug"], "Automatic issues must be labeled auto and bug")
        expect(title == "Broken view state in conversation: LeakyFailure", title)
        for expected in ["## Summary", "2 occurrences of brokenUIState in conversation", "No automatic heal was attempted", "## Steps to reproduce",
                         "1. Sign in to Teams in OpenTeams", "- App version: 0.2.13 (16)", "- OS: macOS 27.0", "## Error",
                         "Fingerprint: `openteams-fingerprint-" + incident.fingerprint + "`"] {
            expect(text.contains(expected), "Missing \(expected) in:\n\(text)")
        }
        for leak in ["skypetoken", "abc.def", "minh", "Minh", "contoso", "Lunch"] {
            expect(!text.contains(leak), "Leaked \(leak) in:\n\(text)")
        }

        await diagnostics.report(incident)
        try await Task.sleep(for: .milliseconds(150))
        expect(await transport.requests.count == 2, "A repeat inside the bump interval must not comment again")
        expect(await log.escalation(for: incident.fingerprint) == .bump(42), "Throttled repeat must stay pending")
        let relaunched = TeamsIncidentReporter(log: TeamsIncidentLog(url: root.appending(path: "incidents.json"), now: { clock.now }), client: client,
                                               environment: environment, bumpInterval: 3600, now: { clock.now })
        expect(await relaunched.escalate(fingerprint: incident.fingerprint) == .deferred, "A relaunch must keep the bump cooldown")

        clock.now += 3601
        await transport.setOpenIssue(issue["body"] as? String)
        expect(await reporter.escalate(fingerprint: incident.fingerprint) == .bumped(7), "Repeat after the interval must bump the open issue")
        requests = await transport.requests
        expect(requests.count == 4 && requests[3].url!.path == "/repos/hxutixnnn/openteams/issues/7/comments", "Bump must comment instead of filing")
        let comment = body(requests[3])["body"] as! String
        expect(comment.hasPrefix("Seen again: ") && comment.contains("3 occurrences"), comment)
        expect(await log.escalation(for: incident.fingerprint) == .none, "Bump must mark occurrences reported")
        expect(await reporter.escalate(fingerprint: incident.fingerprint) == .skipped, "Reported incident must not escalate again")

        clock.now += 3601
        await transport.setOpenIssue(nil)
        try await log.record(incident)
        expect(await reporter.escalate(fingerprint: incident.fingerprint) == .created(42), "Closed issue must be filed again on regression")

        let stall = try await log.record(TeamsIncident(kind: .stalledSync, subsystem: "refresh", signature: "stalledSync"))
        try await log.recordHeal(fingerprint: stall.fingerprint, succeeded: true)
        let before = await transport.requests.count
        await diagnostics.recordHeal(fingerprint: stall.fingerprint, succeeded: false)
        try await waitFor { await log.records().first { $0.fingerprint == stall.fingerprint }?.issueNumber != nil }
        let afterHeal = await transport.requests
        expect(afterHeal.count == before + 2 && body(afterHeal.last!)["title"] as? String == "Stalled sync in refresh: stalledSync", "Failed heal must file right away")
        expect((body(afterHeal.last!)["body"] as! String).contains("succeeded 1 of 2 times; the last attempt failed"), "Report must record heal outcomes")

        let concurrent = try await log.record(TeamsIncident(kind: .expiredAuth, subsystem: "chatList", signature: "http 401"))
        let countBefore = await transport.requests.count
        async let first = reporter.escalate(fingerprint: concurrent.fingerprint)
        async let second = reporter.escalate(fingerprint: concurrent.fingerprint)
        let outcomes = await [first, second]
        expect(outcomes.filter { $0 == .created(42) }.count == 1 && outcomes.contains(.skipped), "Concurrent escalations must file once: \(outcomes)")
        expect(await transport.requests.count == countBefore + 2, "Concurrent escalations sent duplicate requests")

        let racing = TeamsIncident(kind: .networkFailure, subsystem: "conversation", signature: "http 503")
        try await log.record(racing)
        async let racingOutcome = reporter.escalate(fingerprint: racing.fingerprint)
        try await Task.sleep(for: .milliseconds(10))
        try await log.record(racing)
        expect(await racingOutcome == .created(42), "Racing incident must file")
        expect(await log.escalation(for: racing.fingerprint) == .bump(42), "A repeat during filing must stay pending")

        let limited = try await log.record(TeamsIncident(kind: .renderError, subsystem: "timeline", signature: "layout"))
        await transport.setFailure(429)
        expect(await reporter.escalate(fingerprint: limited.fingerprint) == .deferred, "Rate limit must defer")
        let countLimited = await transport.requests.count
        await transport.setFailure(nil)
        expect(await reporter.escalate(fingerprint: limited.fingerprint) == .deferred, "Rate limit must pause filing")
        expect(await transport.requests.count == countLimited, "Paused reporter sent a request")
        clock.now += 61
        expect(await reporter.escalate(fingerprint: limited.fingerprint) == .created(42), "Filing must resume after Retry-After")

        let relaunchLog = TeamsIncidentLog(url: root.appending(path: "relaunch.json"))
        let leftover = try await relaunchLog.record(TeamsIncident(kind: .networkFailure, subsystem: "refresh", signature: "network -1009"))
        let relaunch = TeamsDiagnostics(log: relaunchLog, sentinelURL: root.appending(path: "relaunch-active"), healGracePeriod: .milliseconds(10))
        relaunch.reporter = TeamsIncidentReporter(log: relaunchLog, client: client, environment: environment)
        await relaunch.beginSession()
        try await waitFor { await relaunchLog.records().first { $0.fingerprint == leftover.fingerprint }?.issueNumber == 42 }
        relaunch.endSession()
        print("Incident issue filing: defer without token, skip healed, file unhealed, throttle and bump repeats, refile regressions, file failed heals, dedupe concurrent, honor rate limits, file leftovers on launch: PASS")
    }
}
