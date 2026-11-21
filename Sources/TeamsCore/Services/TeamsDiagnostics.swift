import CryptoKit
import Foundation
import Observation

public enum TeamsIncidentKind: String, Codable, Sendable {
    case crash, renderError, stalledSync, expiredAuth, networkFailure, brokenUIState
}

public struct TeamsIncident: Codable, Sendable {
    public let kind: TeamsIncidentKind
    public let subsystem: String
    public let signature: String
    public let occurredAt: Date

    public init(kind: TeamsIncidentKind, subsystem: String, signature: String, occurredAt: Date = Date()) {
        self.kind = kind; self.subsystem = subsystem; self.signature = signature; self.occurredAt = occurredAt
    }

    public init?(error: any Error, subsystem: String, occurredAt: Date = Date()) {
        if error is CancellationError { return nil }
        let kind: TeamsIncidentKind
        let signature: String
        if let failure = error as? TeamsWebClientError {
            switch failure {
            case .expiredSession, .invalidSession: kind = .expiredAuth; signature = String(describing: failure)
            case let .http(status, _):
                kind = status == 401 ? .expiredAuth : (status == 408 || (500...599).contains(status) ? .networkFailure : .brokenUIState)
                signature = "http \(status)"
            case .network: kind = .networkFailure; signature = "network"
            default: kind = .brokenUIState; signature = String(describing: failure)
            }
        } else if let failure = error as? URLError {
            kind = .networkFailure; signature = "network \(failure.code.rawValue)"
        } else {
            kind = .brokenUIState; signature = String(describing: type(of: error))
        }
        self.init(kind: kind, subsystem: subsystem, signature: signature, occurredAt: occurredAt)
    }

    public var fingerprint: String {
        SHA256.hash(data: Data("\(kind.rawValue)|\(subsystem)|\(signature)".utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

public struct TeamsIncidentRecord: Codable, Sendable {
    public let fingerprint: String
    public let kind: TeamsIncidentKind
    public let subsystem: String
    public let signature: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var occurrences: Int
    public var healAttempts: Int
    public var heals: Int
    public var issueNumber: Int?
    public var reportedOccurrences: Int
    public var lastHealSucceeded: Bool?
}

public enum TeamsIncidentEscalation: Equatable, Sendable {
    case none, file, bump(Int)
}

public actor TeamsIncidentLog {
    public static var defaultURL: URL { URL.applicationSupportDirectory.appending(path: "OpenTeams/incidents.json") }
    private let url: URL
    private let retention: TimeInterval
    private let capacity: Int
    private let repeatThreshold: Int
    private let now: @Sendable () -> Date
    private var entries: [TeamsIncidentRecord]

    public init(url: URL = TeamsIncidentLog.defaultURL, retention: TimeInterval = 30 * 24 * 60 * 60,
                capacity: Int = 200, repeatThreshold: Int = 3, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url; self.retention = max(0, retention); self.capacity = max(1, capacity)
        self.repeatThreshold = max(1, repeatThreshold); self.now = now
        entries = (try? JSONDecoder().decode([TeamsIncidentRecord].self, from: Data(contentsOf: url))) ?? []
    }

    @discardableResult public func record(_ incident: TeamsIncident) throws -> TeamsIncidentRecord {
        prune()
        let record: TeamsIncidentRecord
        if let index = entries.firstIndex(where: { $0.fingerprint == incident.fingerprint }) {
            entries[index].occurrences += 1
            entries[index].firstSeen = min(entries[index].firstSeen, incident.occurredAt)
            entries[index].lastSeen = max(entries[index].lastSeen, incident.occurredAt)
            record = entries[index]
        } else {
            record = TeamsIncidentRecord(fingerprint: incident.fingerprint, kind: incident.kind, subsystem: incident.subsystem,
                signature: incident.signature, firstSeen: incident.occurredAt, lastSeen: incident.occurredAt,
                occurrences: 1, healAttempts: 0, heals: 0, reportedOccurrences: 0)
            entries.append(record)
        }
        try save()
        return record
    }

    public func recordHeal(fingerprint: String, succeeded: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        entries[index].healAttempts += 1
        entries[index].heals += succeeded ? 1 : 0
        entries[index].lastHealSucceeded = succeeded
        try save()
    }

    public func linkIssue(fingerprint: String, number: Int) throws {
        guard let index = entries.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        entries[index].issueNumber = number
        entries[index].reportedOccurrences = entries[index].occurrences
        try save()
    }

    public func markReported(fingerprint: String) throws {
        guard let index = entries.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        entries[index].reportedOccurrences = entries[index].occurrences
        try save()
    }

    public func records() -> [TeamsIncidentRecord] { prune(); return entries }

    public func escalation(for fingerprint: String) -> TeamsIncidentEscalation {
        prune()
        guard let record = entries.first(where: { $0.fingerprint == fingerprint }) else { return .none }
        if let number = record.issueNumber {
            return record.occurrences > record.reportedOccurrences ? .bump(number) : .none
        }
        return record.lastHealSucceeded != true || record.occurrences >= repeatThreshold ? .file : .none
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-retention)
        entries = Array(entries.filter { $0.lastSeen >= cutoff }.sorted {
            $0.lastSeen == $1.lastSeen ? $0.fingerprint < $1.fingerprint : $0.lastSeen > $1.lastSeen
        }.prefix(capacity))
    }

    private func save() throws {
        prune()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

@MainActor @Observable
public final class TeamsDiagnostics {
    public let log: TeamsIncidentLog
    public var onIncident: ((TeamsIncidentRecord) -> Void)?
    public private(set) var persistenceFailed = false
    private let sentinelURL: URL
    private var sessionStarted = false

    public init(log: TeamsIncidentLog = TeamsIncidentLog(), sentinelURL: URL = TeamsIncidentLog.defaultURL.deletingLastPathComponent().appending(path: "session-active")) {
        self.log = log; self.sentinelURL = sentinelURL
    }

    public func report(_ incident: TeamsIncident) async {
        do { onIncident?(try await log.record(incident)) }
        catch { persistenceFailed = true }
    }

    public func recordHeal(fingerprint: String, succeeded: Bool) async {
        do { try await log.recordHeal(fingerprint: fingerprint, succeeded: succeeded) }
        catch { persistenceFailed = true }
    }

    public func beginSession() async {
        guard !sessionStarted else { return }
        sessionStarted = true
        let unclean = FileManager.default.fileExists(atPath: sentinelURL.path)
        do {
            try FileManager.default.createDirectory(at: sentinelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: sentinelURL, options: .atomic)
        } catch { persistenceFailed = true }
        if unclean { await report(TeamsIncident(kind: .crash, subsystem: "app", signature: "uncleanExit")) }
    }

    public func endSession() {
        guard sessionStarted else { return }
        do {
            if FileManager.default.fileExists(atPath: sentinelURL.path) { try FileManager.default.removeItem(at: sentinelURL) }
            sessionStarted = false
        } catch { persistenceFailed = true }
    }
}
