import Foundation

public struct TeamsConversationMember: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case admin = "Admin", guest = "Guest", user = "User" }
    public let id: String
    public let role: Role

    public init(id: String, role: Role = .admin) {
        self.id = id
        self.role = role
    }
}

public struct TeamsConversationCreation: Sendable {
    public let threadID: String
    public let status: Int
    public let responseBody: TeamsWebJSONValue?
    public var hasPartialFailures: Bool { status == 207 }

    public init(threadID: String, status: Int, responseBody: TeamsWebJSONValue?) {
        self.threadID = threadID
        self.status = status
        self.responseBody = responseBody
    }
}

public enum TeamsConversationError: Error, LocalizedError, Equatable, Sendable {
    case invalidMembers
    case tooManyMembers
    case creationOutcomeUnknown

    public var errorDescription: String? {
        switch self {
        case .invalidMembers: "Choose at least one other Teams participant."
        case .tooManyMembers: "Choose no more than 199 other participants for this chat."
        case .creationOutcomeUnknown: "Chat creation could not be confirmed. Refresh your chats before trying again."
        }
    }
}

public struct TeamsConversationClient: Sendable {
    private let session: TeamsWebSession
    private let transport: any HTTPTransport

    public init(session: TeamsWebSession, transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    public func createChat(with participants: [TeamsConversationMember], title: String? = nil) async throws -> TeamsConversationCreation {
        try session.validate()
        guard let messaging = session.messaging else { throw TeamsWebClientError.sendingUnavailable }
        try messaging.validate()
        let ownID = "8:orgid:\(session.accountID)"
        var seen = Set([ownID])
        var members = [TeamsConversationMember(id: ownID)]
        for member in participants {
            guard !member.id.isEmpty, member.id.contains(":"),
                  member.id.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw TeamsConversationError.invalidMembers
            }
            if seen.insert(member.id).inserted { members.append(member) }
        }
        guard members.count >= 2 else { throw TeamsConversationError.invalidMembers }
        guard members.count <= 200 else { throw TeamsConversationError.tooManyMembers }
        let topic = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var properties: [String: TeamsWebJSONValue] = ["threadType": .string("chat")]
        if members.count == 2 {
            properties["fixedRoster"] = .bool(true)
            if topic.isEmpty { properties["uniquerosterthread"] = .bool(true) }
        }
        if !topic.isEmpty { properties["topic"] = .string(topic) }
        struct Payload: Encodable {
            let members: [TeamsConversationMember]
            let properties: [String: TeamsWebJSONValue]
        }
        var components = URLComponents(url: messaging.baseURL, resolvingAgainstBaseURL: false)!
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + "/v1/threads"
        guard let url = components.url else { throw TeamsWebClientError.unsafeBaseURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = try JSONEncoder().encode(Payload(members: members, properties: properties))
        request.setValue("Bearer \(messaging.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-ms-client-request-id")
        try Task.checkCancellation()
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch { throw TeamsConversationError.creationOutcomeUnknown }
        guard [201, 207].contains(response.statusCode) else {
            if response.statusCode >= 500 || response.statusCode == 408 || (200..<300).contains(response.statusCode) {
                throw TeamsConversationError.creationOutcomeUnknown
            }
            throw TeamsWebClientError.http(status: response.statusCode,
                                           retryAfter: TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        }
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let locationURL = URL(string: location, relativeTo: url),
              let threadID = locationURL.lastPathComponent.removingPercentEncoding,
              !threadID.isEmpty, threadID.utf8.count <= 1024, threadID != "threads", threadID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TeamsConversationError.creationOutcomeUnknown
        }
        return TeamsConversationCreation(threadID: threadID, status: response.statusCode,
                                         responseBody: try? JSONDecoder().decode(TeamsWebJSONValue.self, from: data))
    }
}
