import Foundation
import TeamsCore

private actor ThrottlingTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "5"])!)
    }
}

@main @MainActor
struct ComposerConnectionClock {
    private static let chatID = "19:fixture@thread.v2"
    private static let samplingStep: TimeInterval = 0.05

    static func main() async throws {
        let idle = try idleConnectedComposerNeverWakes()
        let throttled = try await throttledComposerWakesOncePerCountdownSecond()
        let expiring = try expiringSessionWakesOnceAtExpiry()
        try disconnectedComposerNeverWakes()
        print("ComposerConnectionClock passed: composer wakeups per idle minute 60 -> \(idle), 5 s throttle \(throttled), session expiry \(expiring)")
    }

    private static func idleConnectedComposerNeverWakes() throws -> Int {
        let now = Date()
        let store = composer(session: session(expiresAt: now.addingTimeInterval(3_600)))
        let wakeups = scheduledWakeups(store.connectionIssueClock, after: now, through: now.addingTimeInterval(60))
        try check(wakeups.isEmpty)
        try check(observableChanges(store, after: now, through: now.addingTimeInterval(60)).isEmpty)
        return wakeups.count
    }

    private static func throttledComposerWakesOncePerCountdownSecond() async throws -> Int {
        let store = composer(session: session(expiresAt: Date().addingTimeInterval(3_600)), transport: ThrottlingTransport())
        store.setDraft("Hello", in: chatID)
        try check(await store.sendDraft(in: chatID) == nil)
        let now = Date()
        let retryNotBefore = try require(store.retryNotBefore)
        try check(store.connectionIssueClock.retryNotBefore == retryNotBefore)
        let end = retryNotBefore.addingTimeInterval(1)
        let wakeups = scheduledWakeups(store.connectionIssueClock, after: now, through: end)
        try check((4...5).contains(wakeups.count) && wakeups.last == retryNotBefore)
        let changes = observableChanges(store, after: now, through: end)
        try check(!changes.isEmpty && covered(changes, by: wakeups))
        try check(store.canSend(in: chatID, at: end) && !store.canSend(in: chatID, at: now))
        return wakeups.count
    }

    private static func expiringSessionWakesOnceAtExpiry() throws -> Int {
        let now = Date()
        let expiresAt = now.addingTimeInterval(2)
        let store = composer(session: session(expiresAt: expiresAt))
        let wakeups = scheduledWakeups(store.connectionIssueClock, after: now, through: now.addingTimeInterval(60))
        try check(wakeups == [expiresAt])
        let changes = observableChanges(store, after: now, through: now.addingTimeInterval(4))
        try check(changes.count == 1 && covered(changes, by: wakeups))
        try check(store.connectionIssue(at: expiresAt) != nil && store.connectionIssueClock.nextChange(after: expiresAt) == nil)
        return wakeups.count
    }

    private static func disconnectedComposerNeverWakes() throws {
        let store = TeamsComposeStore(root: root())
        try check(store.connectionIssueClock.expiresAt == nil && store.connectionIssueClock.retryNotBefore == nil)
        try check(store.connectionIssueClock.nextChange(after: Date()) == nil)
    }

    private static func scheduledWakeups(_ clock: TeamsConnectionIssueClock, after start: Date, through end: Date) -> [Date] {
        var wakeups: [Date] = []
        var current = start
        while let next = clock.nextChange(after: current), next <= end {
            wakeups.append(next)
            current = next
        }
        return wakeups
    }

    private static func observableChanges(_ store: TeamsComposeStore, after start: Date, through end: Date) -> [Date] {
        func state(at date: Date) -> String { (store.connectionIssue(at: date) ?? "") + "|\(store.canSend(in: chatID, at: date))" }
        var changes: [Date] = []
        var previous = state(at: start)
        var date = start.addingTimeInterval(samplingStep)
        while date <= end {
            let current = state(at: date)
            if current != previous { changes.append(date) }
            previous = current
            date = date.addingTimeInterval(samplingStep)
        }
        return changes
    }

    private static func covered(_ changes: [Date], by wakeups: [Date]) -> Bool {
        changes.allSatisfy { change in wakeups.contains { $0 > change.addingTimeInterval(-samplingStep) && $0 <= change } }
    }

    private static func composer(session: TeamsWebSession, transport: any HTTPTransport = ThrottlingTransport()) -> TeamsComposeStore {
        let store = TeamsComposeStore(root: root(), transport: transport)
        store.connect(session)
        return store
    }

    private static func session(expiresAt: Date) -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture-only",
              expiresAt: .distantFuture, accountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", tenantID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
              displayName: "Fixture Person",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!,
                               accessToken: "fixture-only", expiresAt: expiresAt))
    }

    private static func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
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
