import Foundation

/// Tracks new unread messages only after an initial server snapshot for an account.
public struct TeamsNotificationTracker: Sendable {
    private struct SeenMessages: Sendable {
        var latestNumericID: String?
        var latestArrival: Date?
        var opaqueIDs: Set<String> = []

        mutating func observe(_ message: TeamsWebMessage) -> Bool {
            let arrival = message.arrivalDate
            if message.id.utf8.allSatisfy({ (48...57).contains($0) }) {
                let id = String(message.id.drop(while: { $0 == "0" }))
                if let latestNumericID,
                   id.count < latestNumericID.count || (id.count == latestNumericID.count && id <= latestNumericID) { return false }
                if let arrival, let latestArrival, arrival < latestArrival { return false }
                latestNumericID = id
            } else {
                guard opaqueIDs.insert(message.id).inserted else { return false }
                if let arrival, let latestArrival, arrival < latestArrival { return false }
            }
            if let arrival { latestArrival = arrival }
            return true
        }
    }

    private var scope = ""
    private var seen: [String: SeenMessages] = [:]
    private var seeded = false
    private var seededAt = Date.distantFuture
    public init() {}

    public mutating func reset() { scope = ""; seen = [:]; seeded = false; seededAt = .distantFuture }

    public mutating func update(chats: [TeamsWebChat], accountID: String, accountScope: String, at now: Date = Date()) -> [TeamsWebChat] {
        if scope != accountScope { reset(); scope = accountScope }
        var notifications: [TeamsWebChat] = []
        let ownID = accountID.lowercased()
        let ownMRI = "8:orgid:" + ownID
        for chat in chats {
            guard let message = chat.lastMessage, !message.id.isEmpty else { continue }
            let knownChat = seen[chat.id] != nil
            guard seen[chat.id, default: .init()].observe(message) else { continue }
            let sender = message.senderID?.lowercased() ?? ""
            let own = sender == ownID || sender == ownMRI || sender.hasSuffix("/" + ownMRI)
            let newConversationMessage = knownChat || (message.arrivalDate.map { $0 > seededAt } ?? false)
            if seeded, newConversationMessage, chat.isRead == false, !sender.isEmpty, !own,
               chat.hidden != true, chat.isConversationDeleted != true {
                notifications.append(chat)
            }
        }
        if !seeded { seededAt = now }
        seeded = true
        return notifications
    }
}
