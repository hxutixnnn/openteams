import Foundation

public enum TeamsIncidentFilingOutcome: Equatable, Sendable {
    case skipped, deferred, created(Int), bumped(Int)
}

public actor TeamsIncidentReporter {
    private let log: TeamsIncidentLog
    private let client: any GitHubIssueFiling
    private let environment: GitHubIssueEnvironment
    private let bumpInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var inFlight: Set<String> = []
    private var pausedUntil: Date?

    public init(log: TeamsIncidentLog, client: any GitHubIssueFiling, environment: GitHubIssueEnvironment = .current(),
                bumpInterval: TimeInterval = 6 * 60 * 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.log = log; self.client = client; self.environment = environment
        self.bumpInterval = max(0, bumpInterval); self.now = now
    }

    @discardableResult public func escalate(fingerprint: String) async -> TeamsIncidentFilingOutcome {
        let escalation = await log.escalation(for: fingerprint)
        let record = await log.records().first { $0.fingerprint == fingerprint }
        guard escalation != .none, let record, !inFlight.contains(fingerprint) else { return .skipped }
        if let pausedUntil, now() < pausedUntil { return .deferred }
        if case .bump = escalation, let last = record.lastReportedAt, now().timeIntervalSince(last) < bumpInterval { return .deferred }
        inFlight.insert(fingerprint)
        defer { inFlight.remove(fingerprint) }
        do {
            let result = try await client.fileOrBump(Self.report(for: record, environment: environment))
            try await log.linkIssue(fingerprint: fingerprint, number: result.issue.number, reportedOccurrences: record.occurrences)
            switch result {
            case .created(let issue): return .created(issue.number)
            case .bumped(let issue): return .bumped(issue.number)
            }
        } catch GitHubIssueError.rateLimited(let retryAfter) {
            pausedUntil = now().addingTimeInterval(retryAfter ?? 15 * 60)
            return .deferred
        } catch {
            return .deferred
        }
    }

    private static func lastHeal(_ succeeded: Bool?) -> String {
        switch succeeded {
        case true?: "the last attempt succeeded."
        case false?: "the last attempt failed."
        case nil: "it recurred after the last attempt."
        }
    }

    public static func report(for record: TeamsIncidentRecord, environment: GitHubIssueEnvironment) -> GitHubIssueReport {
        let dates = ISO8601DateFormatter()
        let healing = record.healAttempts == 0 ? "No automatic heal was attempted."
            : "Automatic healing succeeded \(record.heals) of \(record.healAttempts) times; \(lastHeal(record.lastHealSucceeded))"
        return GitHubIssueReport(
            title: "\(record.kind.issueTitle) in \(record.subsystem): \(record.signature)",
            summary: "OpenTeams recorded \(record.occurrences) occurrence\(record.occurrences == 1 ? "" : "s") of \(record.kind.rawValue) in \(record.subsystem) between \(dates.string(from: record.firstSeen)) and \(dates.string(from: record.lastSeen)). \(healing)",
            reproSteps: record.kind.reproSteps(subsystem: record.subsystem, signature: record.signature),
            environment: environment,
            errorText: "\(record.kind.rawValue) in \(record.subsystem): \(record.signature)",
            labels: GitHubIssueReport.automaticLabels,
            fingerprint: record.fingerprint)
    }
}

private extension TeamsIncidentKind {
    var issueTitle: String {
        switch self {
        case .crash: "Unexpected quit"
        case .renderError: "Render error"
        case .stalledSync: "Stalled sync"
        case .expiredAuth: "Expired sign-in"
        case .networkFailure: "Network failure"
        case .brokenUIState: "Broken view state"
        }
    }

    func reproSteps(subsystem: String, signature: String) -> [String] {
        switch self {
        case .crash: ["Launch OpenTeams", "Use the app until it quits unexpectedly", "Relaunch OpenTeams"]
        case .stalledSync: ["Sign in to Teams in OpenTeams", "Leave the app open while background refresh runs", "Observe that \(subsystem) stops updating"]
        case .expiredAuth: ["Sign in to Teams in OpenTeams", "Keep the app open until the Teams session expires", "Observe that \(subsystem) fails with \(signature)"]
        case .networkFailure, .renderError, .brokenUIState: ["Sign in to Teams in OpenTeams", "Open \(subsystem)", "Observe that it fails with \(signature)"]
        }
    }
}
