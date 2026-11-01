import Foundation

public struct TeamsWebSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let baseURL: URL
    public let accessToken: String
    public let expiresAt: Date
    public let accountID: String
    public let tenantID: String
    public let displayName: String
    public let messaging: TeamsMessagingSession?
    public let searchSession: TeamsSearchSession?
    public let directory: TeamsDirectorySession?
    public let directoryBaseURL: URL?

    public init(
        baseURL: URL, accessToken: String, expiresAt: Date,
        accountID: String, tenantID: String, displayName: String,
        messaging: TeamsMessagingSession? = nil, searchSession: TeamsSearchSession? = nil,
        directory: TeamsDirectorySession? = nil, directoryBaseURL: URL? = nil
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.tenantID = tenantID
        self.displayName = displayName
        self.messaging = messaging
        self.searchSession = searchSession
        self.directory = directory
        self.directoryBaseURL = directoryBaseURL ?? directory?.baseURL
    }

    public func validate(at date: Date = Date()) throws {
        guard TeamsWebClient.validateBaseURL(baseURL) else { throw TeamsWebClientError.unsafeBaseURL }
        guard !accessToken.isEmpty, accessToken.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tenantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TeamsWebClientError.invalidSession
        }
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite, expiresAt > date else {
            throw TeamsWebClientError.expiredSession
        }
    }

    public var description: String { "TeamsWebSession(accessToken: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["accessToken": "<redacted>"]) }
}

public enum TeamsWebJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case object([String: TeamsWebJSONValue])
    case array([TeamsWebJSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Decimal.self) { self = .number(value) }
        else if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}

public struct TeamsWebMember: Codable, Hashable, Sendable {
    public enum Kind: Sendable { case person, agent, agentic, unknown }
    public let mri: String?
    public let objectId: String?
    public let displayName: String?
    public let friendlyName: String?
    public let userIdentityType: String?
    public let avatarETag: String?
    public let tenantId: String?

    public var preferredDisplayName: String? {
        [displayName, friendlyName].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var kind: Kind {
        if userIdentityType?.lowercased() == "agentic" { return .agentic }
        let id = mri?.lowercased() ?? ""
        if id.hasPrefix("28:orgid:") { return .unknown }
        if id.hasPrefix("28:") || id.hasPrefix("8:28:") { return .agent }
        if id.hasPrefix("8:orgid:") { return .person }
        return .unknown
    }

    public init(mri: String? = nil, objectId: String? = nil, displayName: String? = nil, friendlyName: String? = nil, userIdentityType: String? = nil, avatarETag: String? = nil, tenantId: String? = nil) {
        self.mri = mri
        self.objectId = objectId
        self.displayName = displayName
        self.friendlyName = friendlyName
        self.userIdentityType = userIdentityType
        self.avatarETag = avatarETag
        self.tenantId = tenantId
    }
}

public struct TeamsWebMessage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let content: String?
    public let contentType: String?
    public let messageType: String?
    public let imDisplayName: String?
    public let from: TeamsWebJSONValue?
    public let originalArrivalTime: String?
    public let composeTime: String?
    public let version: String?
    public let properties: TeamsWebJSONValue?
    public let clientMessageId: String?
    public let amsReferences: TeamsWebJSONValue?
    public let forwardedMessageContext: TeamsWebJSONValue?
    public let arrivalDate: Date?

    public init(
        id: String, content: String? = nil, contentType: String? = nil,
        messageType: String? = nil, imDisplayName: String? = nil, from: TeamsWebJSONValue? = nil,
        originalArrivalTime: String? = nil, composeTime: String? = nil,
        version: String? = nil, properties: TeamsWebJSONValue? = nil, clientMessageId: String? = nil,
        amsReferences: TeamsWebJSONValue? = nil, forwardedMessageContext: TeamsWebJSONValue? = nil
    ) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.messageType = messageType
        self.imDisplayName = imDisplayName
        self.from = from
        self.originalArrivalTime = originalArrivalTime
        self.composeTime = composeTime
        self.version = version
        self.properties = properties
        self.clientMessageId = clientMessageId
        self.amsReferences = amsReferences
        self.forwardedMessageContext = forwardedMessageContext
        arrivalDate = Self.resolveArrivalDate(id: id, originalArrivalTime: originalArrivalTime, composeTime: composeTime)
    }

    enum CodingKeys: String, CodingKey {
        case id, content, contentType, messageType, imDisplayName, from
        case originalArrivalTime, composeTime, version, properties, clientMessageId, amsReferences, forwardedMessageContext
    }
    private enum AliasKeys: String, CodingKey { case clientmessageid, amsreferences }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = try container.scalarStringIfPresent(forKey: .id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Missing message ID.")
        }
        self.id = id
        content = try container.decodeIfPresent(String.self, forKey: .content)
        contentType = try container.scalarStringIfPresent(forKey: .contentType)
        messageType = try container.scalarStringIfPresent(forKey: .messageType)
        imDisplayName = try container.decodeIfPresent(String.self, forKey: .imDisplayName)
        from = try container.decodeIfPresent(TeamsWebJSONValue.self, forKey: .from)
        originalArrivalTime = try container.scalarStringIfPresent(forKey: .originalArrivalTime)
        composeTime = try container.scalarStringIfPresent(forKey: .composeTime)
        version = try container.scalarStringIfPresent(forKey: .version)
        properties = try container.decodeIfPresent(TeamsWebJSONValue.self, forKey: .properties)
        clientMessageId = try container.scalarStringIfPresent(forKey: .clientMessageId)
            ?? decoder.container(keyedBy: AliasKeys.self).scalarStringIfPresent(forKey: .clientmessageid)
        amsReferences = try container.decodeIfPresent(TeamsWebJSONValue.self, forKey: .amsReferences)
            ?? decoder.container(keyedBy: AliasKeys.self).decodeIfPresent(TeamsWebJSONValue.self, forKey: .amsreferences)
        forwardedMessageContext = try container.decodeIfPresent(TeamsWebJSONValue.self, forKey: .forwardedMessageContext)
        arrivalDate = Self.resolveArrivalDate(id: id, originalArrivalTime: originalArrivalTime, composeTime: composeTime)
    }

    public var senderID: String? {
        if let value = from?.stringValue { return value }
        if case let .object(value)? = from {
            return value["mri"]?.stringValue ?? value["id"]?.stringValue ?? value["objectId"]?.stringValue
        }
        return nil
    }

    private static func resolveArrivalDate(id: String, originalArrivalTime: String?, composeTime: String?) -> Date? {
        for value in [originalArrivalTime, composeTime].compactMap({ $0 }) {
            if let date = Self.parseDate(value) { return date }
        }
        guard let numericID = Double(id), numericID >= 946_684_800 else { return nil }
        return Self.parseDate(id)
    }

    private static func parseDate(_ value: String) -> Date? {
        if let timestamp = Double(value), timestamp.isFinite, timestamp > 0 {
            let seconds = timestamp > 100_000_000_000 ? timestamp / 1_000 : timestamp
            guard seconds <= Date.distantFuture.timeIntervalSince1970 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct TeamsWebChat: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String?
    public let chatType: String?
    public let threadType: String?
    public let isOneOnOne: Bool?
    public let isRead: Bool?
    public let hidden: Bool?
    public let isConversationDeleted: Bool?
    public let isDisabled: Bool?
    public let members: [TeamsWebMember]?
    public let lastMessage: TeamsWebMessage?
    public let picture: String?
    public let pictureMetadataPresent: Bool
    public let threadVersion: String?

    public init(
        id: String, title: String? = nil, chatType: String? = nil, threadType: String? = nil,
        isOneOnOne: Bool? = nil, isRead: Bool? = nil, hidden: Bool? = nil,
        isConversationDeleted: Bool? = nil, isDisabled: Bool? = nil,
        members: [TeamsWebMember]? = nil, lastMessage: TeamsWebMessage? = nil,
        picture: String? = nil, pictureMetadataPresent: Bool? = nil, threadVersion: String? = nil
    ) {
        self.id = id
        self.title = title
        self.chatType = chatType
        self.threadType = threadType
        self.isOneOnOne = isOneOnOne
        self.isRead = isRead
        self.hidden = hidden
        self.isConversationDeleted = isConversationDeleted
        self.isDisabled = isDisabled
        self.members = members
        self.lastMessage = lastMessage
        self.picture = picture
        self.pictureMetadataPresent = pictureMetadataPresent ?? (picture != nil)
        self.threadVersion = threadVersion
    }

    public func retainingPicture(from previous: TeamsWebChat?) -> TeamsWebChat {
        guard !pictureMetadataPresent, let previous, previous.pictureMetadataPresent else { return self }
        return TeamsWebChat(id: id, title: title, chatType: chatType, threadType: threadType, isOneOnOne: isOneOnOne,
                            isRead: isRead, hidden: hidden, isConversationDeleted: isConversationDeleted, isDisabled: isDisabled,
                            members: members, lastMessage: lastMessage, picture: previous.picture, pictureMetadataPresent: true, threadVersion: threadVersion ?? previous.threadVersion)
    }

    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        let names = members?.compactMap(\.preferredDisplayName).filter { !$0.isEmpty }.joined(separator: ", ") ?? ""
        return names.isEmpty ? "Teams chat" : names
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, chatType, threadType, isOneOnOne, isRead, hidden
        case isConversationDeleted, isDisabled, members, lastMessage, picture, pictureMetadataPresent, threadVersion
    }
    private enum PreviewKeys: String, CodingKey { case id }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        chatType = try container.decodeIfPresent(String.self, forKey: .chatType)
        threadType = try container.decodeIfPresent(String.self, forKey: .threadType)
        isOneOnOne = try container.decodeIfPresent(Bool.self, forKey: .isOneOnOne)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        isConversationDeleted = try container.decodeIfPresent(Bool.self, forKey: .isConversationDeleted)
        isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled)
        picture = try? container.decodeIfPresent(String.self, forKey: .picture)
        let validPictureField = container.contains(.picture) && ((try? container.decodeNil(forKey: .picture)) == true || picture != nil)
        pictureMetadataPresent = (try? container.decodeIfPresent(Bool.self, forKey: .pictureMetadataPresent)) ?? validPictureField
        threadVersion = try? container.scalarStringIfPresent(forKey: .threadVersion)
        members = try container.decodeIfPresent([TeamsWebMember].self, forKey: .members)
        if container.contains(.lastMessage), try !container.decodeNil(forKey: .lastMessage) {
            let preview = try container.nestedContainer(keyedBy: PreviewKeys.self, forKey: .lastMessage)
            if try preview.scalarStringIfPresent(forKey: .id)?.isEmpty == false {
                lastMessage = try container.decode(TeamsWebMessage.self, forKey: .lastMessage)
            } else { lastMessage = nil }
        } else { lastMessage = nil }
    }
}

public struct TeamsWebChatPage: Codable, Hashable, Sendable {
    public let items: [TeamsWebChat]
    public let continuationToken: String?

    public init(items: [TeamsWebChat], continuationToken: String? = nil) {
        self.items = items
        self.continuationToken = continuationToken
    }
}

public struct TeamsWebMessagePage: Codable, Hashable, Sendable {
    public let messages: [TeamsWebMessage]
    public let messageToken: String?

    public init(messages: [TeamsWebMessage], messageToken: String? = nil) {
        self.messages = messages
        self.messageToken = messageToken
    }
}

public enum TeamsWebClientError: Error, LocalizedError, Equatable, Sendable {
    case unsafeBaseURL
    case invalidSession
    case expiredSession
    case invalidPageSize
    case invalidChatID
    case invalidMessageID
    case invalidPaginationToken
    case invalidResponse
    case network
    case sendingUnavailable
    case emptyMessage
    case messageTooLarge
    case invalidClientMessageID
    case sendOutcomeUnknown
    case http(status: Int, retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .unsafeBaseURL: "The Teams service address is invalid. Sign in again."
        case .invalidSession: "The Teams session is invalid. Sign in again."
        case .expiredSession: "Your Teams session has expired. Sign in again."
        case .invalidPageSize: "The requested Teams page size must be between 1 and 200."
        case .invalidChatID: "The selected Teams chat is invalid."
        case .invalidMessageID: "The selected Teams message is invalid."
        case .invalidPaginationToken: "The Teams page token is invalid. Refresh the conversation."
        case .invalidResponse: "Teams returned an unexpected response."
        case .network: "Could not reach Teams. Check your connection and try again."
        case .sendingUnavailable: "Reconnect to Teams to enable sending. Your draft is saved."
        case .emptyMessage: "Write a message before sending."
        case .messageTooLarge: "This message is too long. Shorten it before sending."
        case .invalidClientMessageID: "This message could not be prepared. Keep the draft and try again."
        case .sendOutcomeUnknown: "Delivery could not be confirmed. Check the conversation before sending this message again."
        case let .http(status, retryAfter):
            switch status {
            case 401: "Teams rejected this session. Sign in again."
            case 403: "This Teams account does not have access to the requested conversation."
            case 429: "Teams is limiting requests. Try again\(retryAfter.map { " in \(String(format: "%.0f", ceil($0))) seconds" } ?? " later")."
            default: "Teams returned HTTP \(status). Try again later."
            }
        }
    }
}

private extension KeyedDecodingContainer {
    func scalarStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Decimal.self, forKey: key) { return NSDecimalNumber(decimal: value).stringValue }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath + [key], debugDescription: "Expected a string or number."))
    }
}
