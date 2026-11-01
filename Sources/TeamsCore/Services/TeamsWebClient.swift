import Foundation

public struct TeamsWebClient: Sendable {
    private let session: TeamsWebSession
    private let transport: any HTTPTransport

    public init(session: TeamsWebSession, transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    public static func validateBaseURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "teams.cloud.microsoft",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        let path = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return segments.count == 4 && segments[0].isEmpty && segments[1] == "api" && segments[2] == "csa"
            && segments[3].range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    public static func escapedID(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    public func chats(pageSize: Int = 50, continuationToken: String? = nil) async throws -> TeamsWebChatPage {
        var query = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let continuationToken { query.append(URLQueryItem(name: "continuationToken", value: continuationToken)) }
        let request = try makeRequest(path: "api/v2/teams/users/me/chats", pageSize: pageSize, query: query)
        return try await execute(request)
    }

    public func knownChat(_ id: String) async throws -> TeamsWebChat {
        guard !id.isEmpty, id != ".", id != "..", id.utf8.count <= 1024, id.rangeOfCharacter(from: .controlCharacters) == nil else { throw TeamsWebClientError.invalidChatID }
        struct Member: Decodable {
            let mri: String?; let objectId: String?; let displayName: String?; let friendlyName: String?; let userIdentityType: String?; let avatarETag: String?; let tenantId: String?
        }
        struct Metadata: Decodable {
            let id: String; let title: String?; let chatType: String?; let isOneOnOne: Bool?; let isRead: Bool?
            let hidden: Bool?; let isDisabled: Bool?; let isConversationDeleted: Bool?; let members: [Member]?
            let picture: String?; let picturePresent: Bool; let threadVersion: String?
            enum CodingKeys: String, CodingKey { case id, title, chatType, isOneOnOne, isRead, hidden, isDisabled, isConversationDeleted, members, picture, threadVersion }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id); title = try c.decodeIfPresent(String.self, forKey: .title)
                chatType = try c.decodeIfPresent(String.self, forKey: .chatType); isOneOnOne = try c.decodeIfPresent(Bool.self, forKey: .isOneOnOne)
                isRead = try c.decodeIfPresent(Bool.self, forKey: .isRead); hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
                isDisabled = try c.decodeIfPresent(Bool.self, forKey: .isDisabled); isConversationDeleted = try c.decodeIfPresent(Bool.self, forKey: .isConversationDeleted)
                members = try c.decodeIfPresent([Member].self, forKey: .members)
                picture = try? c.decodeIfPresent(String.self, forKey: .picture)
                picturePresent = c.contains(.picture) && ((try? c.decodeNil(forKey: .picture)) == true || picture != nil)
                if let value = try? c.decode(String.self, forKey: .threadVersion) { threadVersion = value }
                else if let value = try? c.decode(Int64.self, forKey: .threadVersion) { threadVersion = String(value) }
                else { threadVersion = nil }
            }
        }
        let request = try makeRequest(path: "api/v1/teams/users/me/chats/" + Self.escapedID(id), pageSize: 50, query: [])
        let value: Metadata = try await execute(request)
        guard value.id == id else { throw TeamsWebClientError.invalidResponse }
        return TeamsWebChat(id: value.id, title: value.title, chatType: value.chatType, isOneOnOne: value.isOneOnOne,
                            isRead: value.isRead, hidden: value.hidden, isConversationDeleted: value.isConversationDeleted,
                            isDisabled: value.isDisabled, members: value.members?.map { .init(mri: $0.mri, objectId: $0.objectId, displayName: $0.displayName, friendlyName: $0.friendlyName, userIdentityType: $0.userIdentityType, avatarETag: $0.avatarETag, tenantId: $0.tenantId) }, picture: value.picture, pictureMetadataPresent: value.picturePresent, threadVersion: value.threadVersion)
    }

    public func conversationFolders() async throws -> TeamsConversationFolders {
        let request = try makeRequest(path: "api/v1/teams/users/me/conversationFolders", pageSize: 50,
                                      query: [URLQueryItem(name: "supportsAdditionalSystemGeneratedFolders", value: "true"),
                                              URLQueryItem(name: "supportsSliceItems", value: "true")])
        let result: TeamsConversationFolders = try await execute(request)
        guard result.conversationFolders.count <= 1000, result.conversationFolderOrder.count <= 1000,
              result.conversationFolders.allSatisfy({ $0.conversationFolderItems.count <= 5000 }) else { throw TeamsWebClientError.invalidResponse }
        return result
    }

    public func messages(
        in chatID: String, pageSize: Int = 50, messageToken: String? = nil
    ) async throws -> TeamsWebMessagePage {
        guard !chatID.isEmpty, chatID != ".", chatID != ".." else { throw TeamsWebClientError.invalidChatID }
        guard messageToken?.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TeamsWebClientError.invalidPaginationToken
        }
        var request = try makeRequest(
            path: "api/v1/chats/\(Self.escapedID(chatID))/messages", pageSize: pageSize,
            query: [URLQueryItem(name: "messagePageSize", value: String(pageSize))]
        )
        if let messageToken { request.setValue(messageToken, forHTTPHeaderField: "x-ms-messageToken") }
        return try await execute(request)
    }

    public func message(in chatID: String, id: String) async throws -> TeamsWebMessage {
        guard !chatID.isEmpty, chatID != ".", chatID != ".." else { throw TeamsWebClientError.invalidChatID }
        guard !id.isEmpty, id.utf8.count <= 32, id.utf8.allSatisfy({ (48...57).contains($0) }) else { throw TeamsWebClientError.invalidMessageID }
        let request = try makeRequest(path: "api/v1/chats/\(Self.escapedID(chatID))/messages/\(id)", pageSize: 50, query: [])
        let message: TeamsWebMessage = try await execute(request)
        guard message.id == id else { throw TeamsWebClientError.invalidResponse }
        return message
    }

    private func makeRequest(path: String, pageSize: Int, query: [URLQueryItem]) throws -> URLRequest {
        try session.validate()
        guard (1...200).contains(pageSize) else { throw TeamsWebClientError.invalidPageSize }
        guard var components = URLComponents(url: session.baseURL, resolvingAgainstBaseURL: false) else {
            throw TeamsWebClientError.unsafeBaseURL
        }
        let base = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = "\(base)/\(path)"
        components.queryItems = query.isEmpty ? nil : query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw TeamsWebClientError.unsafeBaseURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func execute<Value: Decodable & Sendable>(_ request: URLRequest) async throws -> Value {
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw TeamsWebClientError.network }
        guard (200..<300).contains(response.statusCode) else {
            throw TeamsWebClientError.http(
                status: response.statusCode,
                retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            )
        }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw TeamsWebClientError.invalidResponse }
    }

    public static func retryAfter(_ value: String?, at now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Int(value), seconds >= 0 { return TimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
