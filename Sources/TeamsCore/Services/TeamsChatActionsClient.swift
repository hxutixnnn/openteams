import Foundation

public enum TeamsChatActionError: Error, Equatable, Sendable {
    case invalidMessage
    case ownMessageRequired
    case unsupportedMessage
    case invalidReaction
    case missingArrivalTime
    case outcomeUnknown
}

public struct TeamsChatActionsClient: Sendable {
    private let session: TeamsWebSession
    private let transport: any HTTPTransport

    public init(session: TeamsWebSession, transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    public func editText(_ text: String, in chatID: String, message: TeamsWebMessage, at now: Date = Date()) async throws {
        try requireOwnMessage(message)
        guard message.messageType == "Text" || message.messageType == "RichText/Html" else {
            throw TeamsChatActionError.unsupportedMessage
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TeamsWebClientError.emptyMessage }
        guard text.utf8.count <= 28_000 else { throw TeamsWebClientError.messageTooLarge }
        let timestamp = ISO8601DateFormatter().string(from: now)
        var properties: [String: TeamsWebJSONValue] = [:]
        if case let .object(existing)? = message.properties { properties = existing }
        properties["edittime"] = .number(Decimal(Self.milliseconds(now)))
        properties["formatVariant"] = .string("TEAMS")
        let sender = "8:orgid:\(session.accountID)"
        let body: [String: TeamsWebJSONValue] = [
            "id": .string(message.id), "type": .string("Message"), "conversationid": .string(chatID),
            "conversationLink": .string("blah/" + chatID), "from": .string(sender), "fromUserId": .string(sender),
            "composetime": .string(message.composeTime ?? timestamp),
            "originalarrivaltime": .string(message.originalArrivalTime ?? timestamp),
            "content": .string(text), "messagetype": .string("Text"), "contenttype": .string("Text"),
            "imdisplayname": .string(message.imDisplayName ?? session.displayName),
            "clientmessageid": .string(message.clientMessageId ?? message.id), "callId": .string(""),
            "state": .number(0), "version": .string(timestamp), "amsreferences": .array([]),
            "properties": .object(properties)
        ]
        try await perform(in: chatID, suffix: "/messages/" + message.id, method: "PUT", body: body)
    }

    public func editDocument(_ document: TeamsRichDraft, in chatID: String, message: TeamsWebMessage, at now: Date = Date()) async throws {
        try requireOwnMessage(message)
        guard let composeTime = message.composeTime, !composeTime.isEmpty,
              let arrivalTime = message.originalArrivalTime, !arrivalTime.isEmpty else { throw TeamsChatActionError.missingArrivalTime }
        let original = try Self.editableContent(message)
        guard !document.contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TeamsWebClientError.emptyMessage }
        var existing: [String: TeamsWebJSONValue] = [:]
        if case let .object(properties)? = message.properties { existing = properties }
        let rich = message.messageType == "RichText/Html" || !document.isPlain || original.reply != nil
        var properties: [String: TeamsWebJSONValue] = [:]
        for key in ["pinned", "draftId"] { properties[key] = existing[key] }
        properties["edittime"] = .number(Decimal(Self.milliseconds(now)))
        properties["formatVariant"] = .string("TEAMS")
        var content: String
        if rich {
            let serialized = try document.serialize()
            content = serialized.html
            properties["mentions"] = .string(serialized.mentionsJSON)
            if let reply = original.reply {
                let quoted = TeamsWebMessage(id: reply.messageID, imDisplayName: reply.name, from: .string(reply.sender), originalArrivalTime: String(reply.timestamp))
                let prefix = try Self.quotedReplyPrefix(replyingTo: quoted, preview: reply.preview)
                content = prefix.content + content
                properties.merge(prefix.properties) { _, new in new }
            }
        } else { content = document.contentText }
        guard content.utf8.count <= 28_000 else { throw TeamsWebClientError.messageTooLarge }
        let timestamp = ISO8601DateFormatter().string(from: now), sender = "8:orgid:\(session.accountID)"
        let body: [String: TeamsWebJSONValue] = [
            "id": .string(message.id), "type": .string("Message"), "conversationid": .string(chatID),
            "conversationLink": .string("blah/" + chatID), "from": .string(sender), "fromUserId": .string(sender),
            "composetime": .string(composeTime), "originalarrivaltime": .string(arrivalTime),
            "content": .string(content), "messagetype": .string(rich ? "RichText/Html" : "Text"), "contenttype": .string("Text"),
            "imdisplayname": .string(message.imDisplayName ?? session.displayName), "clientmessageid": .string(message.clientMessageId ?? message.id),
            "callId": .string(""), "state": .number(0), "version": .string(timestamp), "amsreferences": .array([]), "properties": .object(properties)
        ]
        try await perform(in: chatID, suffix: "/messages/" + message.id, method: "PUT", body: body)
    }

    public static func editableContent(_ message: TeamsWebMessage) throws -> TeamsRichEditImport {
        let original = try TeamsRichEditImport(message: message)
        var existing: [String: TeamsWebJSONValue] = [:]
        if let properties = message.properties {
            guard case let .object(value) = properties else { throw TeamsChatActionError.unsupportedMessage }
            existing = value
        }
        for key in ["cards", "files", "links", "amsreferences", "forwardedMessageContext", "onBehalfOf", "onbehalfof", "subject", "title", "replyPermission", "policyViolation", "meeting", "crossPostId", "sharedInfo", "emaildetails", "sendAt", "blurhash"] {
            guard isEmptyContentProperty(existing[key]) else { throw TeamsChatActionError.unsupportedMessage }
        }
        if let importance = existing["importance"], importance != .string("Standard"), !isEmptyContentProperty(importance) { throw TeamsChatActionError.unsupportedMessage }
        guard isEmptyContentProperty(message.amsReferences), isEmptyContentProperty(message.forwardedMessageContext) else { throw TeamsChatActionError.unsupportedMessage }
        if original.reply == nil, !isEmptyContentProperty(existing["qtdMsgs"]) { throw TeamsChatActionError.unsupportedMessage }
        if message.messageType == "Text", !isEmptyContentProperty(existing["mentions"]) { throw TeamsChatActionError.unsupportedMessage }
        return original
    }

    private static func isEmptyContentProperty(_ value: TeamsWebJSONValue?) -> Bool {
        switch value {
        case nil, .null: return true
        case let .string(text): return text.isEmpty || text == "[]" || text == "{}"
        case let .array(items): return items.isEmpty
        case let .object(items): return items.isEmpty
        default: return false
        }
    }

    public func delete(in chatID: String, message: TeamsWebMessage) async throws {
        try requireOwnMessage(message)
        try await perform(in: chatID, suffix: "/messages/" + message.id, method: "DELETE",
                          query: [.init(name: "behavior", value: "softDelete")])
    }

    public func setReaction(
        _ key: String, in chatID: String, message: TeamsWebMessage,
        replaceExisting: Bool = true, at now: Date = Date()
    ) async throws {
        try Self.validateMessage(message)
        try Self.validateReaction(key)
        var query = [URLQueryItem(name: "name", value: "emotions")]
        if replaceExisting { query.append(.init(name: "replace", value: "true")) }
        try await perform(in: chatID, suffix: "/messages/" + message.id + "/properties", method: "PUT",
                          query: query, body: ["emotions": .object([
                            "key": .string(key), "value": .number(Decimal(Self.milliseconds(now)))
                          ])])
    }

    public func removeReaction(_ key: String, in chatID: String, message: TeamsWebMessage) async throws {
        try Self.validateMessage(message)
        try Self.validateReaction(key)
        try await perform(in: chatID, suffix: "/messages/" + message.id + "/properties", method: "DELETE",
                          query: [.init(name: "name", value: "emotions")],
                          body: ["emotions": .object(["key": .string(key)])])
    }

    public func markRead(in chatID: String, through message: TeamsWebMessage, at now: Date = Date()) async throws {
        try Self.validateMessage(message)
        guard let arrival = Self.arrivalMilliseconds(message.originalArrivalTime) else {
            throw TeamsChatActionError.missingArrivalTime
        }
        let clientID = message.clientMessageId.map { String($0.split(separator: "_", maxSplits: 1).last ?? "0") } ?? "0"
        guard clientID.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil else {
            throw TeamsChatActionError.invalidMessage
        }
        let value = "\(arrival);\(Self.milliseconds(now));\(clientID)"
        try await perform(in: chatID, suffix: "/properties", method: "PUT",
                          query: [.init(name: "name", value: "consumptionhorizon")],
                          body: ["consumptionhorizon": .string(value)])
    }

    public func markUnread(in chatID: String, before message: TeamsWebMessage, at now: Date = Date()) async throws {
        try Self.validateMessage(message)
        guard let arrival = Self.arrivalMilliseconds(message.originalArrivalTime), arrival > 0 else {
            throw TeamsChatActionError.missingArrivalTime
        }
        let clientID = message.clientMessageId ?? message.id
        guard clientID.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil else {
            throw TeamsChatActionError.invalidMessage
        }
        try await perform(in: chatID, suffix: "/properties", method: "PUT",
                          query: [.init(name: "name", value: "consumptionHorizonBookmark")],
                          body: ["consumptionHorizonBookmark": .string("\(arrival - 1);\(Self.milliseconds(now));\(clientID)")])
    }

    public func clearUnreadBookmark(in chatID: String, at now: Date = Date()) async throws {
        try await perform(in: chatID, suffix: "/properties", method: "PUT",
                          query: [.init(name: "name", value: "consumptionHorizonBookmark")],
                          body: ["consumptionHorizonBookmark": .string("0;\(Self.milliseconds(now));0")])
    }

    public static func quotedReplyProperties(for message: TeamsWebMessage) throws -> [String: TeamsWebJSONValue] {
        try validateMessage(message)
        guard let sender = message.senderID, !sender.isEmpty,
              let arrival = arrivalMilliseconds(message.originalArrivalTime) else {
            throw TeamsChatActionError.missingArrivalTime
        }
        let quote: [String: TeamsWebJSONValue] = [
            "messageId": .string(message.id), "sender": .string(sender), "time": .number(Decimal(arrival))
        ]
        let encoded = try JSONEncoder().encode([quote])
        return ["qtdMsgs": .string(String(decoding: encoded, as: UTF8.self))]
    }

    public static func quotedReplyContent(
        _ text: String, replyingTo message: TeamsWebMessage, preview: String
    ) throws -> (content: String, properties: [String: TeamsWebJSONValue]) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TeamsWebClientError.emptyMessage }
        let quote = try quotedReplyPrefix(replyingTo: message, preview: preview)
        let paragraphs = text.components(separatedBy: "\n").map { "<p>\(escapeHTML($0))</p>" }.joined()
        let content = quote.content + paragraphs
        guard content.utf8.count <= 28_000 else { throw TeamsWebClientError.messageTooLarge }
        return (content, quote.properties)
    }

    public static func quotedReplyPrefix(replyingTo message: TeamsWebMessage, preview: String) throws -> (content: String, properties: [String: TeamsWebJSONValue]) {
        let properties = try quotedReplyProperties(for: message)
        guard let sender = message.senderID, let arrival = arrivalMilliseconds(message.originalArrivalTime) else { throw TeamsChatActionError.missingArrivalTime }
        let name = message.imDisplayName ?? sender
        let block = "<blockquote itemscope=\"\" itemtype=\"http://schema.skype.com/Reply\" itemid=\"\(message.id)\"><strong itemprop=\"mri\" itemid=\"\(escapeHTML(sender))\">\(escapeHTML(name))</strong><span itemprop=\"time\" itemid=\"\(arrival)\"></span><p itemprop=\"preview\">\(escapeHTML(preview))</p></blockquote>"
        return (block, properties)
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func requireOwnMessage(_ message: TeamsWebMessage) throws {
        try Self.validateMessage(message)
        guard let sender = message.senderID,
              sender.caseInsensitiveCompare("8:orgid:" + session.accountID) == .orderedSame ||
              sender.caseInsensitiveCompare(session.accountID) == .orderedSame else {
            throw TeamsChatActionError.ownMessageRequired
        }
    }

    private static func validateMessage(_ message: TeamsWebMessage) throws {
        guard message.id.range(of: "^[0-9]+$", options: .regularExpression) != nil else {
            throw TeamsChatActionError.invalidMessage
        }
    }

    private static func validateReaction(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 128, key.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TeamsChatActionError.invalidReaction
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    static func arrivalMilliseconds(_ value: String?) -> Int64? {
        guard let value else { return nil }
        if let number = Int64(value), number > 0 { return number }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value),
              date.timeIntervalSince1970 > 0 else { return nil }
        return milliseconds(date)
    }

    private func perform(
        in chatID: String, suffix: String, method: String,
        query: [URLQueryItem] = [], body: [String: TeamsWebJSONValue]? = nil
    ) async throws {
        try session.validate()
        guard let messaging = session.messaging else { throw TeamsWebClientError.sendingUnavailable }
        try messaging.validate()
        guard !chatID.isEmpty, chatID != ".", chatID != "..",
              chatID.rangeOfCharacter(from: .controlCharacters) == nil else { throw TeamsWebClientError.invalidChatID }
        try Task.checkCancellation()
        var components = URLComponents(url: messaging.baseURL, resolvingAgainstBaseURL: false)!
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + "/v1/users/ME/conversations/" + TeamsWebClient.escapedID(chatID) + suffix
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw TeamsWebClientError.unsafeBaseURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(messaging.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("10", forHTTPHeaderField: "x-ms-request-priority")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-ms-client-request-id")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response: HTTPURLResponse
        do { (_, response) = try await transport.data(for: request) }
        catch { throw TeamsChatActionError.outcomeUnknown }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode >= 500 || response.statusCode == 408 { throw TeamsChatActionError.outcomeUnknown }
            throw TeamsWebClientError.http(status: response.statusCode,
                                           retryAfter: TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        }
    }
}
