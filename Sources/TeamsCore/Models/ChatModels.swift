import Foundation

public struct Person: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var role: String
    public var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
    public init(id: String, name: String, role: String = "") {
        self.id = id
        self.name = name
        self.role = role
    }
}

public struct ChatAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var detail: String
    public var symbol: String
    public init(id: String, name: String, detail: String, symbol: String = "doc.text") {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbol = symbol
    }
}

public struct MessageReaction: Codable, Hashable, Sendable {
    public var emoji: String
    public var count: Int
    public var includesMe: Bool
    public init(_ emoji: String, count: Int, includesMe: Bool = false) {
        self.emoji = emoji
        self.count = count
        self.includesMe = includesMe
    }
}

public struct QuotedMessage: Codable, Hashable, Sendable {
    public let author: String
    public let text: String
    public init(author: String, text: String) {
        self.author = author
        self.text = text
    }
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let conversationID: String
    public let authorID: String
    public var text: String
    public let createdAt: Date
    public var quote: QuotedMessage?
    public var attachment: ChatAttachment?
    public var code: String?
    public var reactions: [MessageReaction]
    public var isEdited: Bool
    public init(
        id: String = UUID().uuidString, conversationID: String, authorID: String,
        text: String, createdAt: Date = Date(), quote: QuotedMessage? = nil,
        attachment: ChatAttachment? = nil, code: String? = nil,
        reactions: [MessageReaction] = [], isEdited: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.authorID = authorID
        self.text = text
        self.createdAt = createdAt
        self.quote = quote
        self.attachment = attachment
        self.code = code
        self.reactions = reactions
        self.isEdited = isEdited
    }
}

public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var subtitle: String
    public var memberIDs: [String]
    public var symbol: String
    public var colorIndex: Int
    public var isFavorite: Bool
    public var unreadCount: Int
    public init(
        id: String, title: String, subtitle: String, memberIDs: [String],
        symbol: String = "person.2.fill", colorIndex: Int = 0,
        isFavorite: Bool = false, unreadCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.memberIDs = memberIDs
        self.symbol = symbol
        self.colorIndex = colorIndex
        self.isFavorite = isFavorite
        self.unreadCount = unreadCount
    }
}

public enum MessageSearch {
    public static func matches(_ message: ChatMessage, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = [message.text, message.quote?.text, message.attachment?.name, message.code]
            .compactMap { $0 }.joined(separator: " ")
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
