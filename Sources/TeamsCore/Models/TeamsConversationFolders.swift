import Foundation

public struct TeamsConversationFolderItem: Codable, Hashable, Sendable {
    public let conversationId: String
    public let itemType: String?
    public init(conversationId: String, itemType: String? = nil) { self.conversationId = conversationId; self.itemType = itemType }
}

public struct TeamsConversationFolder: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let folderType: String
    public let sortType: String?
    public let emojiMetadataId: String?
    public let isExpanded: Bool?
    public let isDeleted: Bool?
    public let conversationFolderItems: [TeamsConversationFolderItem]
    public var chatIDs: [String] {
        var seen = Set<String>()
        return conversationFolderItems.filter { $0.itemType == nil || $0.itemType == "Conversation" }.map(\.conversationId)
            .filter { !$0.isEmpty && $0.utf8.count <= 1024 && $0.rangeOfCharacter(from: .controlCharacters) == nil && seen.insert($0).inserted }
    }
    public init(id: String, name: String? = nil, folderType: String, sortType: String? = nil, emojiMetadataId: String? = nil, isExpanded: Bool? = nil,
                isDeleted: Bool? = nil, conversationFolderItems: [TeamsConversationFolderItem] = []) {
        self.id = id; self.name = name; self.folderType = folderType; self.sortType = sortType
        self.emojiMetadataId = emojiMetadataId
        self.isExpanded = isExpanded; self.isDeleted = isDeleted; self.conversationFolderItems = conversationFolderItems
    }
}

public struct TeamsConversationFolders: Codable, Hashable, Sendable {
    public let conversationFolders: [TeamsConversationFolder]
    public let conversationFolderOrder: [String]
    public let isPartialResponse: Bool?
    public init(conversationFolders: [TeamsConversationFolder], conversationFolderOrder: [String], isPartialResponse: Bool?) {
        self.conversationFolders = conversationFolders; self.conversationFolderOrder = conversationFolderOrder; self.isPartialResponse = isPartialResponse
    }
    public var isComplete: Bool { isPartialResponse == false }
    public var orderedChatFolders: [TeamsConversationFolder] {
        let eligible = conversationFolders.filter { folder in
            ["Favorites", "UserCreated"].contains(folder.folderType) && folder.isDeleted != true && !folder.id.isEmpty && folder.id.utf8.count <= 1024
        }
        var seen = Set<String>()
        let unique = eligible.filter { seen.insert($0.id).inserted }
        let ranks = Dictionary(conversationFolderOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let fallback = Dictionary(unique.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return unique.sorted { (ranks[$0.id] ?? conversationFolderOrder.count + (fallback[$0.id] ?? 0)) < (ranks[$1.id] ?? conversationFolderOrder.count + (fallback[$1.id] ?? 0)) }
    }
}
