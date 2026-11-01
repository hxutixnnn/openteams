import Foundation

public struct TeamsMessageContext: Sendable {
    public struct Entry: Sendable {
        public let message: TeamsWebMessage
        public let sequenceID: Int64?
    }
    public let messages: [Entry]
    public let backwardToken: String?
    public let forwardToken: String?
}

public struct TeamsMessageContextClient: Sendable {
    public enum Direction: String, Sendable { case backward = "BACKWARD", forward = "FORWARD", bidirectional = "BIDIRECTIONAL" }
    private let session: TeamsWebSession
    private let transport: any HTTPTransport

    public init(session: TeamsWebSession, transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    public func messages(in chatID: String, pivot: String, direction: Direction = .bidirectional, pageSize: Int = 20) async throws -> TeamsMessageContext {
        try session.validate()
        guard let messaging = session.messaging else { throw TeamsWebClientError.sendingUnavailable }
        try messaging.validate()
        guard !chatID.isEmpty, chatID != ".", chatID != "..", chatID.utf8.count <= 1024,
              chatID.rangeOfCharacter(from: .controlCharacters) == nil else { throw TeamsWebClientError.invalidChatID }
        guard Self.validToken(pivot) else { throw TeamsWebClientError.invalidMessageID }
        guard (1...100).contains(pageSize) else { throw TeamsWebClientError.invalidPageSize }
        guard var components = URLComponents(url: messaging.baseURL, resolvingAgainstBaseURL: false) else { throw TeamsWebClientError.unsafeBaseURL }
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + "/v1/users/ME/conversations/\(TeamsWebClient.escapedID(chatID))/messages/epochTimeStamp/\(pivot)"
        components.queryItems = [URLQueryItem(name: "pageSize", value: String(pageSize)), URLQueryItem(name: "direction", value: direction.rawValue), URLQueryItem(name: "includeMetadata", value: "true"), URLQueryItem(name: "locationType", value: "Primary")]
        guard let url = components.url else { throw TeamsWebClientError.unsafeBaseURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue("Bearer " + messaging.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw TeamsWebClientError.network }
        guard (200..<300).contains(response.statusCode) else { throw TeamsWebClientError.http(status: response.statusCode, retryAfter: TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))) }
        let page: Page
        do { page = try JSONDecoder().decode(Page.self, from: data) } catch { throw TeamsWebClientError.invalidResponse }
        guard page.messages.count <= 200, page.messages.allSatisfy({ Self.validToken($0.id) }) else { throw TeamsWebClientError.invalidResponse }
        var unique: [String: Message] = [:]
        for item in page.messages {
            if let prior = unique[item.id], Self.compareDecimal(item.version ?? "", prior.version ?? "") == .orderedAscending { continue }
            unique[item.id] = item
        }
        let useSequence = unique.values.allSatisfy { $0.sequenceId != nil }
        let ordered = unique.values.sorted { left, right in
            if useSequence, let a = left.sequenceId, let b = right.sequenceId, a != b { return a < b }
            return Self.compareDecimal(left.id, right.id) == .orderedAscending
        }
        return TeamsMessageContext(messages: ordered.map { .init(message: $0.message, sequenceID: $0.sequenceId) }, backwardToken: Self.token(in: page.metadata?.backwardLink), forwardToken: Self.token(in: page.metadata?.forwardLink))
    }

    private static func validToken(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy { (48...57).contains($0) } }
    private static func compareDecimal(_ left: String, _ right: String) -> ComparisonResult {
        guard validToken(left), validToken(right) else { return left.compare(right) }
        let a = String(left.drop(while: { $0 == "0" })), b = String(right.drop(while: { $0 == "0" }))
        if a.count != b.count { return a.count < b.count ? .orderedAscending : .orderedDescending }
        return a.compare(b)
    }
    private static func token(in link: String?) -> String? {
        guard let link, let path = URLComponents(string: link)?.percentEncodedPath,
              let range = path.range(of: "/epochTimeStamp/", options: .backwards) else { return nil }
        let value = String(path[range.upperBound...])
        return validToken(value) ? value : nil
    }
    private struct Page: Decodable {
        struct Metadata: Decodable { let backwardLink: String?; let forwardLink: String? }
        let messages: [Message]
        let metadata: Metadata?
        enum CodingKeys: String, CodingKey { case messages; case metadata = "_metadata" }
    }
    private struct Message: Decodable {
        let id: String
        let content: String?
        let contenttype: String?
        let messagetype: String?
        let imdisplayname: String?
        let from: TeamsWebJSONValue?
        let originalarrivaltime: String?
        let composetime: String?
        let version: String?
        let properties: TeamsWebJSONValue?
        let clientmessageid: String?
        let sequenceId: Int64?
        var message: TeamsWebMessage { .init(id: id, content: content, contentType: contenttype, messageType: messagetype, imDisplayName: imdisplayname, from: from, originalArrivalTime: originalarrivaltime, composeTime: composetime, version: version, properties: properties, clientMessageId: clientmessageid) }
    }
}
