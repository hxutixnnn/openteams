import Foundation

/// Tracks new unread messages only after an initial server snapshot for an account.
public struct TeamsNotificationTracker: Sendable {
    private var scope = ""
    private var seen: [String: String] = [:]
    private var seeded = false
    private var seededAt = Date.distantFuture
    public init() {}

    public mutating func reset() { scope = ""; seen = [:]; seeded = false; seededAt = .distantFuture }

    public mutating func update(chats: [TeamsWebChat], accountID: String, accountScope: String, at now: Date = Date()) -> [TeamsWebChat] {
        if scope != accountScope { reset(); scope = accountScope }
        var notifications: [TeamsWebChat] = []
        for chat in chats {
            guard let message = chat.lastMessage, !message.id.isEmpty else { continue }
            let prior = seen[chat.id]
            if let prior, let old = Decimal(string: prior), let new = Decimal(string: message.id), new < old { continue }
            seen[chat.id] = message.id
            let sender = message.senderID ?? ""
            let own = sender == accountID || sender == "8:orgid:" + accountID || sender.hasSuffix("/8:orgid:" + accountID)
            let newConversationMessage = prior != nil || (message.arrivalDate.map { $0 > seededAt } ?? false)
            if seeded, newConversationMessage, prior != message.id, chat.isRead == false, !sender.isEmpty, !own,
               chat.hidden != true, chat.isConversationDeleted != true {
                notifications.append(chat)
            }
        }
        if !seeded { seededAt = now }
        seeded = true
        return notifications
    }
}
