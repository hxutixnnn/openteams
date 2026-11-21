import Foundation
import TeamsCore

private struct SensitiveFailure: Error, CustomStringConvertible {
    var description: String { "fake-token-123 https://secret.example/chat/user-id" }
}

@main struct IncidentLogWorkflow {
    static func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OpenTeams-incidents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "incidents.json")
        let log = TeamsIncidentLog(url: url)
        expect(await log.records().isEmpty, "Missing file must start empty")
        let failure = TeamsIncident(error: TeamsWebClientError.http(status: 503, retryAfter: nil), subsystem: "chatList")!
        let first = try await log.record(failure)
        expect(first.fingerprint.count == 32, "Fingerprint must be a stable SHA256 hex prefix")
        let second = try await log.record(failure)
        expect(second.fingerprint == first.fingerprint && second.occurrences == 2, "Repeated incident must deduplicate")
        expect(await log.records().count == 1, "Duplicate created another record")
        let other = TeamsIncident(error: TeamsWebClientError.http(status: 502, retryAfter: nil), subsystem: "chatList")!
        try await log.record(other)
        expect(await log.records().count == 2, "Different signature must remain separate")
        let restored = TeamsIncidentLog(url: url)
        expect(await restored.records().first(where: { $0.fingerprint == first.fingerprint })?.occurrences == 2, "Persistence lost occurrences")
        expect(await log.escalation(for: first.fingerprint) == .file, "Unhealed incident should file")
        try await log.recordHeal(fingerprint: first.fingerprint, succeeded: false)
        expect(await log.escalation(for: first.fingerprint) == .file, "Failed heal should file")
        try await log.recordHeal(fingerprint: first.fingerprint, succeeded: true)
        expect(await log.escalation(for: first.fingerprint) == .none, "Successful heal below threshold should suppress filing")
        try await log.recordHeal(fingerprint: first.fingerprint, succeeded: false)
        expect(await log.escalation(for: first.fingerprint) == .file, "Last failed heal must override earlier success")
        try await log.recordHeal(fingerprint: first.fingerprint, succeeded: true)
        try await log.record(failure)
        expect(await log.escalation(for: first.fingerprint) == .file, "Repeat threshold should file even after success")
        try await log.linkIssue(fingerprint: first.fingerprint, number: 42)
        expect(await log.escalation(for: first.fingerprint) == .none, "Linking should capture reported count")
        try await log.record(failure)
        expect(await log.escalation(for: first.fingerprint) == .bump(42), "New occurrence should bump linked issue")
        try await log.markReported(fingerprint: first.fingerprint)
        expect(await log.escalation(for: first.fingerprint) == .none, "Marking reported should suppress bump")
        expect(await log.escalation(for: "missing") == .none, "Unknown fingerprint should not escalate")
        try await log.recordHeal(fingerprint: "missing", succeeded: false)
        try await log.linkIssue(fingerprint: "missing", number: 1)
        try await log.markReported(fingerprint: "missing")

        let clock = Date(timeIntervalSince1970: 2_000_000_000)
        let rolling = TeamsIncidentLog(url: root.appending(path: "rolling.json"), retention: 100, capacity: 2, now: { clock })
        for (signature, age) in [("expired", 101.0), ("oldest", 50.0), ("middle", 30.0), ("newest", 10.0)] {
            try await rolling.record(TeamsIncident(kind: .stalledSync, subsystem: "refresh", signature: signature, occurredAt: clock.addingTimeInterval(-age)))
        }
        expect(await rolling.records().map(\.signature) == ["newest", "middle"], "Retention and capacity must evict oldest lastSeen")
        let expired = TeamsIncidentLog(url: root.appending(path: "rolling.json"), retention: 1, now: { clock })
        expect(await expired.records().isEmpty, "Loaded records must obey retention")

        let redacted = TeamsIncident(error: SensitiveFailure(), subsystem: "conversation")!
        expect(redacted.signature == "SensitiveFailure", "Unknown errors must use only their type name")
        expect(TeamsIncident(error: CancellationError(), subsystem: "refresh") == nil, "Cancellation is not an incident")
        expect(TeamsIncident(error: TeamsWebClientError.expiredSession, subsystem: "chatList")?.kind == .expiredAuth, "Expired session mapping")
        expect(TeamsIncident(error: TeamsWebClientError.http(status: 401, retryAfter: nil), subsystem: "chatList")?.kind == .expiredAuth, "HTTP 401 mapping")
        expect(TeamsIncident(error: URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLStringErrorKey: SensitiveFailure().description]), subsystem: "refresh")?.signature == "network -1009", "URL error must only retain code")
        try await log.record(redacted)
        let json = try String(contentsOf: url, encoding: .utf8)
        expect(!json.contains("fake-token") && !json.contains("secret.example") && !json.contains("user-id"), "Persisted diagnostics leaked error details")

        let sentinel = root.appending(path: "session-active")
        let sessions = TeamsIncidentLog(url: root.appending(path: "sessions.json"))
        let clean = TeamsDiagnostics(log: sessions, sentinelURL: sentinel)
        await clean.beginSession()
        await clean.beginSession()
        expect(await sessions.records().isEmpty, "First launch or repeated begin must not report a crash")
        clean.endSession()
        expect(!FileManager.default.fileExists(atPath: sentinel.path), "Clean exit must remove sentinel")
        await clean.beginSession()
        let crashed = TeamsDiagnostics(log: sessions, sentinelURL: sentinel)
        var hookCalls = 0
        crashed.onIncident = { record in
            expect(record.kind == .crash && record.signature == "uncleanExit", "Crash hook payload")
            hookCalls += 1
        }
        await crashed.beginSession()
        expect(await sessions.records().first?.occurrences == 1 && hookCalls == 1, "Unclean exit must report exactly one crash")
        let crashRecord = await sessions.records()[0]
        await crashed.recordHeal(fingerprint: crashRecord.fingerprint, succeeded: true)
        expect(await sessions.records()[0].heals == 1, "Diagnostics must forward heal outcomes")
        crashed.endSession()
        let next = TeamsDiagnostics(log: sessions, sentinelURL: sentinel)
        await next.beginSession()
        expect(await sessions.records().first?.occurrences == 1, "Clean relaunch must not report a crash")
        next.endSession()

        let corruptURL = root.appending(path: "corrupt.json")
        try Data("not json".utf8).write(to: corruptURL)
        let corrupt = TeamsIncidentLog(url: corruptURL)
        expect(await corrupt.records().isEmpty, "Corrupt file must start empty")
        try await corrupt.record(failure)
        expect(await TeamsIncidentLog(url: corruptURL).records().count == 1, "Corrupt log must recover on write")
        let blocked = root.appending(path: "blocked")
        try Data().write(to: blocked)
        let unavailable = TeamsDiagnostics(log: TeamsIncidentLog(url: blocked.appending(path: "incidents.json")), sentinelURL: blocked.appending(path: "sentinel"))
        await unavailable.report(failure)
        expect(unavailable.persistenceFailed, "Persistence failures must be observable without crashing")
        print("Incident dedup, persistence, rolling retention, escalation, redaction, sentinel, and corrupt-file workflows: PASS")
    }
}
