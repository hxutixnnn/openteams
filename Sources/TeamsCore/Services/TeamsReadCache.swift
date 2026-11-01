import Foundation
import CryptoKit
import Darwin

public struct TeamsCachedChats: Codable, Sendable {
    public var chats: [TeamsWebChat]
    public var continuationToken: String?
    public var refreshedAt: Date?
    public init(chats: [TeamsWebChat] = [], continuationToken: String? = nil, refreshedAt: Date? = nil) {
        self.chats = chats; self.continuationToken = continuationToken; self.refreshedAt = refreshedAt
    }
}

public struct TeamsPendingReadIntent: Codable, Sendable {
    public enum Stage: String, Codable, Sendable { case prepared, bookmarkDispatched, bookmarkAccepted, bookmarkRejected, horizonDispatched, horizonAccepted, horizonRejected }
    public let id: UUID
    public var targetHorizon: UInt64
    public var bookmarkRequired: Bool
    public var minimumVersion: String?
    public var stage: Stage
    public init(targetHorizon: UInt64, bookmarkRequired: Bool = true, minimumVersion: String? = nil) { self.id = UUID(); self.targetHorizon = targetHorizon; self.bookmarkRequired = bookmarkRequired; self.minimumVersion = minimumVersion; self.stage = .prepared }
    private enum CodingKeys: String, CodingKey { case id, targetHorizon, stage, bookmarkRequired, minimumVersion }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); targetHorizon = try c.decode(UInt64.self, forKey: .targetHorizon)
        bookmarkRequired = try c.decodeIfPresent(Bool.self, forKey: .bookmarkRequired) ?? true
        minimumVersion = try c.decodeIfPresent(String.self, forKey: .minimumVersion)
        stage = try c.decodeIfPresent(Stage.self, forKey: .stage) ?? .bookmarkDispatched
    }
}

public struct TeamsPendingEdit: Codable, Sendable {
    public enum Stage: String, Codable, Sendable { case prepared, dispatched, rejected, uncertain, accepted }
    public let id: UUID
    public let original: TeamsWebMessage
    public var document: TeamsRichDraft
    public var stage: Stage
    public init(original: TeamsWebMessage, document: TeamsRichDraft) {
        id = UUID(); self.original = original; self.document = document; stage = .prepared
    }
}

public struct TeamsPendingDeletion: Codable, Sendable {
    public enum Stage: String, Codable, Sendable { case prepared, dispatched, accepted, uncertain, rejected }
    public let id: UUID
    public let original: TeamsWebMessage
    public var stage: Stage
    public init(original: TeamsWebMessage) { id = UUID(); self.original = original; stage = .prepared }
}

private struct TeamsPendingDeletionRecord: Codable { let intent: TeamsPendingDeletion? }
private struct TeamsPendingEditRecord: Codable { let intent: TeamsPendingEdit? }

public final class TeamsReadLease: @unchecked Sendable {
    private let descriptor: Int32
    fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

private struct TeamsPendingReadRecord: Codable {
    let intent: TeamsPendingReadIntent?
}

public struct TeamsCachedHistory: Codable, Sendable {
    public var messages: [TeamsWebMessage]
    public var messageToken: String?
    public var refreshedAt: Date?
    public init(messages: [TeamsWebMessage] = [], messageToken: String? = nil, refreshedAt: Date? = nil) {
        self.messages = messages; self.messageToken = messageToken; self.refreshedAt = refreshedAt
    }

    public mutating func merge(_ incoming: [TeamsWebMessage]) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        for message in incoming {
            if let existing = byID[message.id],
               let old = Decimal(string: existing.version ?? ""), let new = Decimal(string: message.version ?? ""), new < old { continue }
            byID[message.id] = message
        }
        messages = byID.values.sorted {
            let left = $0.arrivalDate ?? .distantPast, right = $1.arrivalDate ?? .distantPast
            return left == right ? $0.id < $1.id : left < right
        }
    }
}

public actor TeamsReadCache {
    private struct Envelope<Value: Codable>: Codable {
        let version: Int
        let accountID: String
        let tenantID: String
        let payload: Value
    }
    private let directory: URL
    private let accountID: String
    private let tenantID: String

    public init(root: URL, accountID: String, tenantID: String) {
        self.accountID = accountID
        self.tenantID = tenantID
        directory = root.appendingPathComponent(Self.digest(tenantID + "\n" + accountID), isDirectory: true)
    }

    public func chats() throws -> TeamsCachedChats {
        try read("chats", as: TeamsCachedChats.self) ?? TeamsCachedChats()
    }

    public func creationReview() throws -> TeamsReaderStore.CreationReview? {
        try read("creation-review", as: CreationRecord.self)?.review
    }
    private struct CreationRecord: Codable { let review: TeamsReaderStore.CreationReview? }
    public func acquireCreationLease() throws -> TeamsReadLease? { try acquireReadLease(in: "account-creation") }
    public func updateCreationReview(expectedID: UUID?, review: TeamsReaderStore.CreationReview?) throws -> Bool {
        try withReadIntentLock("account-creation") {
            guard try creationReview()?.operationID == expectedID else { return false }
            try write(CreationRecord(review: review), name: "creation-review")
            let url = directory.appendingPathComponent("creation-review.json")
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize(); try handle.close()
            let fd = open(directory.path, O_RDONLY)
            guard fd >= 0 else { throw CacheError.lockUnavailable }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw CacheError.lockUnavailable }
            return true
        }
    }

    public func pendingRead(in chatID: String) throws -> TeamsPendingReadIntent? {
        try read("read-intent-" + Self.digest(chatID), as: TeamsPendingReadRecord.self)?.intent
    }
    private func editKey(_ chatID: String, _ messageID: String) -> String { "edit\n" + chatID + "\n" + messageID }
    private func deletionName(_ chatID: String, _ messageID: String) -> String { "delete-intent-" + Self.digest(editKey(chatID, messageID)) }
    public func pendingDeletion(in chatID: String, messageID: String) throws -> TeamsPendingDeletion? {
        try read(deletionName(chatID, messageID), as: TeamsPendingDeletionRecord.self)?.intent
    }
    public func installPendingDeletion(_ intent: TeamsPendingDeletion, in chatID: String) throws -> Bool {
        let key = editKey(chatID, intent.original.id)
        return try withReadIntentLock(key) {
            guard try pendingDeletion(in: chatID, messageID: intent.original.id) == nil,
                  try pendingEdit(in: chatID, messageID: intent.original.id) == nil else { return false }
            try writeDeletion(intent, in: chatID, messageID: intent.original.id); return true
        }
    }
    public func updatePendingDeletion(id: UUID, in chatID: String, messageID: String, expected: TeamsPendingDeletion.Stage, stage: TeamsPendingDeletion.Stage?) throws -> Bool {
        let key = editKey(chatID, messageID)
        return try withReadIntentLock(key) {
            guard var intent = try pendingDeletion(in: chatID, messageID: messageID), intent.id == id, intent.stage == expected else { return false }
            if let stage { intent.stage = stage; try writeDeletion(intent, in: chatID, messageID: messageID) }
            else { try writeDeletion(nil, in: chatID, messageID: messageID) }
            return true
        }
    }
    private func writeDeletion(_ intent: TeamsPendingDeletion?, in chatID: String, messageID: String) throws {
        let name = deletionName(chatID, messageID)
        try write(TeamsPendingDeletionRecord(intent: intent), name: name)
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(name + ".json"))
        try handle.synchronize(); try handle.close()
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw CacheError.lockUnavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CacheError.lockUnavailable }
    }
    public func pendingEdit(in chatID: String, messageID: String) throws -> TeamsPendingEdit? {
        try read("edit-intent-" + Self.digest(editKey(chatID, messageID)), as: TeamsPendingEditRecord.self)?.intent
    }
    public func acquireEditLease(in chatID: String, messageID: String) throws -> TeamsReadLease? {
        try acquireReadLease(in: editKey(chatID, messageID))
    }
    public func installPendingEdit(_ intent: TeamsPendingEdit, in chatID: String) throws -> Bool {
        let key = editKey(chatID, intent.original.id)
        return try withReadIntentLock(key) {
            guard try pendingEdit(in: chatID, messageID: intent.original.id) == nil,
                  try pendingDeletion(in: chatID, messageID: intent.original.id) == nil else { return false }
            try write(TeamsPendingEditRecord(intent: intent), name: "edit-intent-" + Self.digest(key)); return true
        }
    }
    public func updatePendingEdit(id: UUID, in chatID: String, messageID: String, expected: TeamsPendingEdit.Stage, document: TeamsRichDraft? = nil, stage: TeamsPendingEdit.Stage) throws -> Bool {
        let key = editKey(chatID, messageID)
        return try withReadIntentLock(key) {
            guard var intent = try pendingEdit(in: chatID, messageID: messageID), intent.id == id, intent.stage == expected else { return false }
            let allowed = (expected == .prepared && [.prepared, .dispatched, .rejected].contains(stage)) ||
                (expected == .dispatched && [.uncertain, .rejected, .accepted].contains(stage)) || (expected == .rejected && stage == .prepared)
            guard allowed, document == nil || (stage == .prepared && expected != .dispatched) else { return false }
            if let document { intent.document = document }
            intent.stage = stage
            try write(TeamsPendingEditRecord(intent: intent), name: "edit-intent-" + Self.digest(key)); return true
        }
    }
    public func clearPendingEdit(id: UUID, in chatID: String, messageID: String) throws -> Bool {
        let key = editKey(chatID, messageID)
        return try withReadIntentLock(key) {
            guard let intent = try pendingEdit(in: chatID, messageID: messageID), intent.id == id,
                  intent.stage == .prepared || intent.stage == .rejected || intent.stage == .accepted else { return false }
            try write(TeamsPendingEditRecord(intent: nil), name: "edit-intent-" + Self.digest(key)); return true
        }
    }
    public func confirmPendingEdit(id: UUID, in chatID: String, messageID: String) throws -> Bool {
        let key = editKey(chatID, messageID)
        return try withReadIntentLock(key) {
            guard let intent = try pendingEdit(in: chatID, messageID: messageID), intent.id == id,
                  intent.stage == .dispatched || intent.stage == .uncertain else { return false }
            try write(TeamsPendingEditRecord(intent: nil), name: "edit-intent-" + Self.digest(key)); return true
        }
    }
    public func restoreUndispatchedEdit(id: UUID, in chatID: String, messageID: String) throws -> Bool {
        let key = editKey(chatID, messageID)
        return try withReadIntentLock(key) {
            guard var intent = try pendingEdit(in: chatID, messageID: messageID), intent.id == id, intent.stage == .dispatched else { return false }
            intent.stage = .prepared
            try write(TeamsPendingEditRecord(intent: intent), name: "edit-intent-" + Self.digest(key)); return true
        }
    }
    private func savePendingRead(_ intent: TeamsPendingReadIntent?, in chatID: String) throws {
        try write(TeamsPendingReadRecord(intent: intent), name: "read-intent-" + Self.digest(chatID))
    }
    public func installPendingRead(_ intent: TeamsPendingReadIntent, in chatID: String) throws -> Bool {
        try withReadIntentLock(chatID) {
            guard try pendingRead(in: chatID) == nil else { return false }
            try savePendingRead(intent, in: chatID)
            return true
        }
    }
    public func advancePendingRead(id: UUID, stage: TeamsPendingReadIntent.Stage, in chatID: String) throws -> Bool {
        try withReadIntentLock(chatID) {
            guard var intent = try pendingRead(in: chatID), intent.id == id else { return false }
            intent.stage = stage
            try savePendingRead(intent, in: chatID)
            return true
        }
    }
    public func retargetPendingRead(id: UUID, target: UInt64, bookmarkRequired: Bool, minimumVersion: String?, in chatID: String) throws -> TeamsPendingReadIntent? {
        try withReadIntentLock(chatID) {
            guard var intent = try pendingRead(in: chatID), intent.id == id,
                  intent.stage == .bookmarkAccepted || (intent.stage == .horizonRejected && intent.bookmarkRequired) else { return nil }
            intent.targetHorizon = max(intent.targetHorizon, target)
            intent.bookmarkRequired = intent.bookmarkRequired || bookmarkRequired
            intent.minimumVersion = minimumVersion
            intent.stage = .bookmarkAccepted
            try savePendingRead(intent, in: chatID)
            return intent
        }
    }
    public func acquireReadLease(in chatID: String) throws -> TeamsReadLease? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("read-intent-" + Self.digest(chatID) + ".lease").path
        let descriptor = open(path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw CacheError.lockUnavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        return TeamsReadLease(descriptor)
    }
    @discardableResult public func clearPendingRead(id: UUID, in chatID: String) throws -> Bool {
        try withReadIntentLock(chatID) {
            guard try pendingRead(in: chatID)?.id == id else { return false }
            try savePendingRead(nil, in: chatID)
            return true
        }
    }
    private func withReadIntentLock<T>(_ chatID: String, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("read-intent-" + Self.digest(chatID) + ".lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw CacheError.lockUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CacheError.lockUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    public func folders() throws -> TeamsConversationFolders? { try read("folders", as: TeamsConversationFolders.self) }
    public func save(_ folders: TeamsConversationFolders) throws { try write(folders, name: "folders") }

    public func history(in chatID: String) throws -> TeamsCachedHistory {
        try read("chat-" + Self.digest(chatID), as: TeamsCachedHistory.self) ?? TeamsCachedHistory()
    }

    public func save(_ chats: TeamsCachedChats) throws { try write(chats, name: "chats") }
    public func save(_ history: TeamsCachedHistory, in chatID: String) throws {
        try write(history, name: "chat-" + Self.digest(chatID))
    }

    private func read<Value: Codable>(_ name: String, as: Value.Type) throws -> Value? {
        let url = directory.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 25_000_000 else { throw CacheError.tooLarge }
        let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: Data(contentsOf: url))
        guard envelope.version == 1, envelope.accountID == accountID, envelope.tenantID == tenantID else {
            throw CacheError.incompatible
        }
        return envelope.payload
    }

    private func write<Value: Codable>(_ value: Value, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Envelope(version: 1, accountID: accountID, tenantID: tenantID, payload: value))
        guard data.count <= 25_000_000 else { throw CacheError.tooLarge }
        let url = directory.appendingPathComponent(name + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private enum CacheError: Error { case incompatible, tooLarge, lockUnavailable }
}
