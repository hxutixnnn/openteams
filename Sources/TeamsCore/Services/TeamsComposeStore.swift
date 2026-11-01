import CryptoKit
import Foundation
import Observation

public struct TeamsReplyDraft: Codable, Equatable, Sendable {
    public let messageID: String
    public let preview: String
    public let author: String
    public init(messageID: String, preview: String, author: String) {
        self.messageID = messageID; self.preview = preview; self.author = author
    }
}

public struct TeamsOutgoingMessage: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case sending, uncertain }
    public let clientMessageID: String
    public let text: String
    public let createdAt: Date
    public var phase: Phase
    public var reply: TeamsReplyDraft? = nil
    public var richDraft: TeamsRichDraft? = nil
}

@MainActor @Observable
public final class TeamsComposeStore {
    public private(set) var drafts: [String: String] = [:]
    public private(set) var replies: [String: TeamsReplyDraft] = [:]
    public private(set) var richDrafts: [String: TeamsRichDraft] = [:]
    public private(set) var outgoing: [String: TeamsOutgoingMessage] = [:]
    public private(set) var errors: [String: String] = [:]
    public private(set) var persistenceError: String?
    public private(set) var retryNotBefore: Date?
    public private(set) var preparing: Set<String> = []
    private var draftRevisions: [String: UUID] = [:]
    private var preparationRevisions: [String: UUID] = [:]
    private var session: TeamsWebSession?
    private var accountKey = ""
    private var accountID = ""
    private var generation = UUID()
    private let root: URL
    private let transport: any HTTPTransport
    @ObservationIgnored private var lastSavedState: SavedState?
    @ObservationIgnored private var encodedRichDrafts: [String: EncodedRichDraft] = [:]

    private struct SavedState: Codable, Equatable {
        let accountKey: String
        let drafts: [String: String]
        let outgoing: [String: TeamsOutgoingMessage]
        let replies: [String: TeamsReplyDraft]?
        let richDrafts: [String: TeamsRichDraft]?
    }

    private struct EncodedRichDraft {
        let draft: TeamsRichDraft
        let member: Data
    }

    public init(root: URL, transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.root = root
        self.transport = transport
    }

    public func restore(accountID: String, tenantID: String) {
        let key = SHA256.hash(data: Data((tenantID + "\n" + accountID).utf8)).map { String(format: "%02x", $0) }.joined()
        guard key != accountKey else { return }
        generation = UUID()
        accountKey = key
        self.accountID = accountID
        session = nil
        drafts = [:]; replies = [:]; richDrafts = [:]; outgoing = [:]; errors = [:]; preparing = []; draftRevisions = [:]; preparationRevisions = [:]
        retryNotBefore = nil; persistenceError = nil
        lastSavedState = nil; encodedRichDrafts = [:]
        let file = root.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            guard (size?.intValue ?? 0) <= 2_000_000 else { throw TeamsWebClientError.invalidResponse }
            let saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
            guard saved.accountKey == key else { throw TeamsWebClientError.invalidResponse }
            drafts = saved.drafts
            replies = saved.replies ?? [:]
            richDrafts = [:]
            for (chatID, rich) in saved.richDrafts ?? [:] {
                if drafts[chatID] == rich.plainText { richDrafts[chatID] = rich }
                else if drafts[chatID] == rich.legacyPlainText { drafts[chatID] = rich.plainText; richDrafts[chatID] = rich }
            }
            outgoing = saved.outgoing.mapValues {
                var value = $0
                value.phase = .uncertain
                if let rich = value.richDraft, value.text == rich.legacyPlainText, value.text != rich.plainText {
                    value = TeamsOutgoingMessage(clientMessageID: value.clientMessageID, text: rich.plainText, createdAt: value.createdAt, phase: .uncertain, reply: value.reply, richDraft: rich)
                }
                return value
            }
            persist()
        } catch {
            persistenceError = "Saved drafts could not be read."
        }
    }

    public func connect(_ session: TeamsWebSession) {
        restore(accountID: session.accountID, tenantID: session.tenantID)
        self.session = session
        retryNotBefore = nil
    }

    public func disconnect() { session = nil; preparing = []; preparationRevisions = [:] }

    public func draft(in chatID: String) -> String { drafts[chatID] ?? "" }

    public func setReply(_ reply: TeamsReplyDraft?, in chatID: String) {
        replies[chatID] = reply
        draftRevisions[chatID] = UUID()
        persist()
    }

    public func setDraft(_ text: String, in chatID: String) {
        if draft(in: chatID) != text { richDrafts[chatID] = nil }
        if text.isEmpty { drafts.removeValue(forKey: chatID) } else { drafts[chatID] = text }
        errors[chatID] = nil
        draftRevisions[chatID] = UUID()
        persist()
    }

    public func setRichDraft(_ rich: TeamsRichDraft, in chatID: String) {
        let text = rich.plainText
        if text.isEmpty { drafts[chatID] = nil; richDrafts[chatID] = nil }
        else { drafts[chatID] = text; richDrafts[chatID] = rich.isPlain ? nil : rich }
        errors[chatID] = nil; draftRevisions[chatID] = UUID(); persist()
    }

    public func connectionIssue(at now: Date = Date()) -> String? {
        guard let session, let messaging = session.messaging else { return TeamsWebClientError.sendingUnavailable.localizedDescription }
        guard messaging.expiresAt > now, session.expiresAt > now else { return "Reconnect to Teams to continue sending. Your draft is saved." }
        if let retryNotBefore, retryNotBefore > now {
            return "Teams is limiting requests. Try again in \(Int(ceil(retryNotBefore.timeIntervalSince(now)))) seconds."
        }
        return nil
    }

    public func canSend(in chatID: String, at now: Date = Date()) -> Bool {
        connectionIssue(at: now) == nil && outgoing[chatID] == nil && !preparing.contains(chatID)
            && !(richDrafts[chatID]?.contentText ?? draft(in: chatID)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func beginPreparation(in chatID: String) -> UUID? {
        guard canSend(in: chatID) else { return nil }
        let revision = draftRevisions[chatID] ?? UUID()
        draftRevisions[chatID] = revision
        preparing.insert(chatID)
        preparationRevisions[chatID] = revision
        return revision
    }

    public func finishPreparation(in chatID: String, revision: UUID) -> Bool {
        guard preparationRevisions[chatID] == revision else { return false }
        let valid = draftRevisions[chatID] == revision
        preparing.remove(chatID)
        preparationRevisions[chatID] = nil
        return valid
    }

    public func acknowledgeUncertainDelivery(in chatID: String) {
        guard outgoing[chatID]?.phase == .uncertain else { return }
        outgoing[chatID] = nil
        errors[chatID] = nil
        persist()
    }

    public func reconcile(_ messages: [TeamsWebMessage], in chatID: String) {
        guard let pending = outgoing[chatID],
              messages.contains(where: {
                  let raw = $0.senderID ?? ""
                  let sender = raw.hasPrefix("https://") ? URL(string: raw)?.lastPathComponent ?? raw : raw
                  return $0.clientMessageId == pending.clientMessageID && (sender == accountID || sender == "8:orgid:" + accountID)
              }) else { return }
        if draft(in: chatID) == pending.text && replies[chatID] == pending.reply && richDrafts[chatID] == pending.richDraft {
            drafts[chatID] = nil; replies[chatID] = nil; richDrafts[chatID] = nil
        }
        outgoing[chatID] = nil
        errors[chatID] = nil
        persist()
    }

    public func sendDraft(in chatID: String, replyingTo: TeamsWebMessage? = nil, preview: String = "") async -> TeamsWebMessage? {
        guard canSend(in: chatID), let session else { return nil }
        let current = generation
        let pending = TeamsOutgoingMessage(clientMessageID: TeamsMessagingClient.newClientMessageID(),
                                           text: draft(in: chatID), createdAt: Date(), phase: .sending, reply: replies[chatID], richDraft: richDrafts[chatID])
        outgoing[chatID] = pending
        errors[chatID] = nil
        persist()
        guard persistenceError == nil else {
            outgoing[chatID] = nil
            errors[chatID] = "This message could not be saved before sending. Check storage space and try again."
            return nil
        }
        do {
            let sent = try await TeamsMessagingClient(session: session, transport: transport)
                .sendText(pending.text, in: chatID, clientMessageID: pending.clientMessageID, composedAt: pending.createdAt, replyingTo: replyingTo, preview: preview, richDraft: pending.richDraft)
            guard current == generation else { return nil }
            guard outgoing[chatID]?.clientMessageID == pending.clientMessageID else { return sent }
            if draft(in: chatID) == pending.text && replies[chatID] == pending.reply && richDrafts[chatID] == pending.richDraft {
            drafts[chatID] = nil; replies[chatID] = nil; richDrafts[chatID] = nil
        }
            outgoing[chatID] = nil
            errors[chatID] = nil
            persist()
            return sent
        } catch {
            guard current == generation else { return nil }
            guard outgoing[chatID]?.clientMessageID == pending.clientMessageID else { return nil }
            if error is TeamsChatActionError {
                outgoing[chatID] = nil
                errors[chatID] = "This message cannot be quoted. Your draft is saved."
                persist()
                return nil
            }
            let failure = error as? TeamsWebClientError ?? .sendOutcomeUnknown
            if failure == .sendOutcomeUnknown {
                if outgoing[chatID] != nil { outgoing[chatID]?.phase = .uncertain }
            } else {
                outgoing[chatID] = nil
            }
            errors[chatID] = failure.localizedDescription
            switch failure {
            case .expiredSession, .http(status: 401, retryAfter: _):
                if self.session?.accessToken == session.accessToken && self.session?.messaging?.accessToken == session.messaging?.accessToken {
                    self.session = nil
                }
            case let .http(status: 429, retryAfter: delay): retryNotBefore = Date().addingTimeInterval(delay ?? 30)
            default: break
            }
            persist()
            return nil
        }
    }

    private func persist() {
        guard !accountKey.isEmpty else { return }
        let state = SavedState(accountKey: accountKey, drafts: drafts, outgoing: outgoing, replies: replies, richDrafts: richDrafts)
        guard state != lastSavedState || persistenceError != nil else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try encodedState(state)
            guard data.count <= 2_000_000 else { throw TeamsWebClientError.messageTooLarge }
            let file = root.appendingPathComponent(accountKey + ".json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            lastSavedState = state
            persistenceError = nil
        } catch {
            encodedRichDrafts = [:]
            persistenceError = "Draft changes could not be saved on this Mac."
        }
    }

    private func encodedState(_ state: SavedState) throws -> Data {
        let encoder = JSONEncoder()
        var data = try encoder.encode(SavedState(accountKey: state.accountKey, drafts: state.drafts,
                                                outgoing: state.outgoing, replies: state.replies, richDrafts: nil))
        data.removeLast()
        data.append(contentsOf: ",\"richDrafts\":{".utf8)
        let richDrafts = state.richDrafts ?? [:]
        for key in encodedRichDrafts.keys.filter({ richDrafts[$0] == nil }) { encodedRichDrafts[key] = nil }
        var first = true
        for (chatID, rich) in richDrafts {
            let member: Data
            if let cached = encodedRichDrafts[chatID], cached.draft == rich { member = cached.member }
            else {
                member = Data(try encoder.encode([chatID: rich]).dropFirst().dropLast())
                encodedRichDrafts[chatID] = EncodedRichDraft(draft: rich, member: member)
            }
            if !first { data.append(UInt8(ascii: ",")) }
            data.append(member)
            first = false
        }
        data.append(contentsOf: "}}".utf8)
        return data
    }
}
