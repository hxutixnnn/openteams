import Foundation

public struct TeamsMessagingClient: Sendable {
    private let session: TeamsWebSession
    private let transport: any HTTPTransport

    public init(session: TeamsWebSession, transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    public static func newClientMessageID() -> String {
        String((String(UInt32.random(in: .min ... .max)) + String(UInt32.random(in: .min ... .max))).prefix(19))
    }

    public func verifyAccess(to chatID: String) async throws {
        var request = try request(in: chatID, method: "GET")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "pageSize", value: "1"), .init(name: "startTime", value: "1")]
        request.url = components.url
        let (_, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw TeamsWebClientError.http(status: response.statusCode, retryAfter: nil)
        }
    }

    public func sendText(
        _ text: String, in chatID: String, clientMessageID: String,
        composedAt: Date = Date(), replyingTo: TeamsWebMessage? = nil, preview: String = "", richDraft: TeamsRichDraft? = nil
    ) async throws -> TeamsWebMessage {
        guard !(richDraft?.contentText ?? text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TeamsWebClientError.emptyMessage }
        guard text.utf8.count <= 28_000 else { throw TeamsWebClientError.messageTooLarge }
        guard clientMessageID.range(of: "^[0-9]{1,19}$", options: .regularExpression) != nil else {
            throw TeamsWebClientError.invalidClientMessageID
        }
        try Task.checkCancellation()
        var request = try request(in: chatID, method: "POST")
        let timestamp = ISO8601DateFormatter().string(from: composedAt)
        let sender = "8:orgid:\(session.accountID)"
        guard richDraft == nil || richDraft?.plainText == text else { throw TeamsWebClientError.invalidResponse }
        let rich = try richDraft?.serialize()
        let reply = try replyingTo.map { message in
            if let rich {
                let quote = try TeamsChatActionsClient.quotedReplyPrefix(replyingTo: message, preview: preview)
                return (content: quote.content + rich.html, properties: quote.properties)
            }
            return try TeamsChatActionsClient.quotedReplyContent(text, replyingTo: message, preview: preview)
        }
        let content = reply?.content ?? rich?.html ?? text
        guard content.utf8.count <= 28_000 else { throw TeamsWebClientError.messageTooLarge }
        var properties: [String: TeamsWebJSONValue] = [
            "importance": .string(""), "links": .string("[]"), "mentions": .string("[]"),
            "onbehalfof": .null, "files": .string("[]"), "formatVariant": .string("TEAMS")
        ]
        if let reply { properties.merge(reply.properties) { _, new in new } }
        if let rich { properties["mentions"] = .string(rich.mentionsJSON) }
        let body: [String: TeamsWebJSONValue] = [
            "id": .string("-1"), "type": .string("Message"), "conversationid": .string(chatID),
            "conversationLink": .string("blah/" + chatID), "from": .string(sender), "fromUserId": .string(sender),
            "composetime": .string(timestamp), "originalarrivaltime": .string(timestamp),
            "content": .string(content), "messagetype": .string(reply == nil && rich == nil ? "Text" : "RichText/Html"), "contenttype": .string("Text"),
            "imdisplayname": .string(session.displayName), "clientmessageid": .string(clientMessageID),
            "callId": .string(""), "state": .number(0), "version": .string("0"), "amsreferences": .array([]),
            "properties": .object(properties)
        ]
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("10", forHTTPHeaderField: "x-ms-request-priority")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-ms-client-request-id")
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch { throw TeamsWebClientError.sendOutcomeUnknown }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode >= 500 || response.statusCode == 408 {
                throw TeamsWebClientError.sendOutcomeUnknown
            }
            throw TeamsWebClientError.http(status: response.statusCode,
                                           retryAfter: TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        }
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location, relativeTo: request.url),
              url.lastPathComponent.range(of: "^[0-9]+$", options: .regularExpression) != nil else {
            throw TeamsWebClientError.sendOutcomeUnknown
        }
        let fields = try? JSONDecoder().decode([String: TeamsWebJSONValue].self, from: data)
        let arrival: String
        switch fields?["OriginalArrivalTime"] {
        case .string(let value): arrival = value
        case .number(let value): arrival = NSDecimalNumber(decimal: value).stringValue
        default: arrival = timestamp
        }
        return TeamsWebMessage(id: url.lastPathComponent, content: content, contentType: "Text", messageType: reply == nil && rich == nil ? "Text" : "RichText/Html",
                               imDisplayName: session.displayName, from: .string(sender),
                               originalArrivalTime: arrival, composeTime: timestamp,
                               properties: .object(properties), clientMessageId: clientMessageID)
    }

    private func request(in chatID: String, method: String) throws -> URLRequest {
        try session.validate()
        guard let messaging = session.messaging else { throw TeamsWebClientError.sendingUnavailable }
        try messaging.validate()
        guard !chatID.isEmpty, chatID != ".", chatID != ".." else { throw TeamsWebClientError.invalidChatID }
        var components = URLComponents(url: messaging.baseURL, resolvingAgainstBaseURL: false)!
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + "/v1/users/ME/conversations/" + TeamsWebClient.escapedID(chatID) + "/messages"
        guard let url = components.url else { throw TeamsWebClientError.unsafeBaseURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(messaging.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
