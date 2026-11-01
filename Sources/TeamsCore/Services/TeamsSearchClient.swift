import Foundation

public struct TeamsSearchSession: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let baseURL: URL
    public let accessToken: String
    public let expiresAt: Date
    public let accountID: String
    public let tenantID: String
    public let useMigratedEndpoint: Bool

    public init(
        baseURL: URL = URL(string: "https://substrate.office.com")!, accessToken: String, expiresAt: Date,
        accountID: String, tenantID: String, useMigratedEndpoint: Bool = false
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.tenantID = tenantID
        self.useMigratedEndpoint = useMigratedEndpoint
    }

    public func validate(at now: Date = Date()) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              let host = components.host, ["substrate.office.com", "teams.microsoft.com"].contains(host),
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              ["", "/"].contains(components.percentEncodedPath) else { throw TeamsSearchError.unsafeServiceAddress }
        guard !accessToken.isEmpty, accessToken.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              UUID(uuidString: accountID) != nil, UUID(uuidString: tenantID) != nil else {
            throw TeamsSearchError.invalidSession
        }
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite, expiresAt > now else { throw TeamsSearchError.expiredSession }
    }

    public var description: String { "TeamsSearchSession(accessToken: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["accessToken": "<redacted>"]) }
}

public struct TeamsMessageSearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let messageID: String?
    public let chatID: String?
    public let preview: String
    public let senderName: String?
    public let senderID: String?
    public let sentAt: String?
    public let conversationTitle: String?
}

public struct TeamsMessageSearchPage: Sendable {
    public let results: [TeamsMessageSearchResult]
    public let total: Int?
    public let hasMore: Bool
}

public enum TeamsSearchError: Error, LocalizedError, Equatable, Sendable {
    case unsafeServiceAddress
    case invalidSession
    case expiredSession
    case invalidQuery
    case invalidPage
    case invalidChatID
    case invalidResponse
    case network
    case http(status: Int, retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .unsafeServiceAddress: return "The Teams search service address is invalid. Reconnect to Teams."
        case .invalidSession, .expiredSession: return "Reconnect to Teams to search messages on the server."
        case .invalidQuery: return "Enter a search phrase of up to 4,096 characters."
        case .invalidPage: return "The requested search page is invalid."
        case .invalidChatID: return "The selected conversation is invalid."
        case .invalidResponse: return "Teams search returned an unexpected response."
        case .network: return "Could not reach Teams search. Check your connection and try again."
        case .http(let status, let retryAfter):
            if status == 401 { return "Teams server search could not authenticate. You can still search downloaded messages." }
            if status == 403 { return "This account cannot access Teams server search." }
            if status == 429 {
                return "Teams search is limiting requests. Try again\(retryAfter.map { " in \(Int(ceil($0))) seconds" } ?? " later")."
            }
            return "Teams search returned HTTP \(status). Try again later."
        }
    }
}

public struct TeamsSearchClient: Sendable {
    private let session: TeamsSearchSession
    private let transport: any HTTPTransport

    public init(session: TeamsSearchSession, transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    public func searchMessages(
        query: String, in chatID: String? = nil, page: Int = 0, pageSize: Int = 25
    ) async throws -> TeamsMessageSearchPage {
        try session.validate()
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase.count <= 4_096 else { throw TeamsSearchError.invalidQuery }
        guard (0...1_000).contains(page), (1...50).contains(pageSize) else { throw TeamsSearchError.invalidPage }
        if let chatID {
            guard !chatID.isEmpty, chatID.utf8.count <= 2_048,
                  chatID.rangeOfCharacter(from: .controlCharacters) == nil else { throw TeamsSearchError.invalidChatID }
        }
        try Task.checkCancellation()
        let request = try makeRequest(query: phrase, chatID: chatID, page: page, pageSize: pageSize)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw TeamsSearchError.network }
        guard (200..<300).contains(response.statusCode) else {
            throw TeamsSearchError.http(status: response.statusCode,
                                         retryAfter: TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        }
        return try Self.decodePage(data)
    }

    private func makeRequest(query: String, chatID: String?, page: Int, pageSize: Int) throws -> URLRequest {
        let path = session.useMigratedEndpoint ? "/searchservice/api/v2/query" : "/search/api/v2/query"
        var components = URLComponents(url: session.baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        guard let url = components.url else { throw TeamsSearchError.unsafeServiceAddress }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        let correlationID = UUID().uuidString
        let clientSessionID = UUID().uuidString
        let headers = [
            "Authorization": "Bearer " + session.accessToken,
            "Accept": "application/json", "Content-Type": "application/json",
            "X-Client-Flights": "SearchV2Flight,SubstrateSearchFanoutFlight,lutmsearchmsg,TMSParseRefiningQueries",
            "X-Client-UI-Language": "en-US",
            "x-anchormailbox": "OID:\(session.accountID)@\(session.tenantID)",
            "X-Client-LocalTime": ISO8601DateFormatter().string(from: Date()),
            "clientRequestId": correlationID, "client-request-id": correlationID,
            "client-session-id": clientSessionID, "x-ms-request-id": correlationID,
            "x-ms-session-id": clientSessionID, "X-CafeLatencyHeaderEnabled": "1"
        ]
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if session.useMigratedEndpoint {
            request.setValue("OID:\(session.accountID)@\(session.tenantID)", forHTTPHeaderField: "X-RoutingParameter-SessionKey")
        }
        let literal = "\"" + Self.escapePhrase(query) + "\""
        let scope = chatID.map { "clientconversationid:\"\(Self.escapePhrase($0))\" AND " } ?? ""
        let body: [String: TeamsWebJSONValue] = [
            "entityRequests": .array([.object([
                "entityType": .string("Message"), "contentSources": .array([.string("Teams")]),
                "fields": .array([
                    .string("Extension_SkypeSpaces_ConversationPost_Extension_FromSkypeInternalId_String"),
                    .string("Extension_SkypeSpaces_ConversationPost_Extension_ThreadType_String"),
                    .string("Extension_SkypeSpaces_ConversationPost_Extension_SkypeGroupId_String"),
                    .string("Extension_SkypeSpaces_ConversationPost_Extension_SenderTenantId_String")
                ]),
                "propertySet": .string("Optimized"),
                "query": .object([
                    "queryString": .string(scope + literal + " AND NOT (isClientSoftDeleted:TRUE)"),
                    "displayQueryString": .string(query)
                ]),
                "from": .number(Decimal(page * pageSize)), "size": .number(Decimal(pageSize))
            ])]),
            "QueryAlterationOptions": .object([
                "EnableAlteration": .bool(true), "EnableSuggestion": .bool(true),
                "SupportedRecourseDisplayTypes": .array([.string("Suggestion")])
            ]),
            "cvid": .string(clientSessionID), "logicalId": .string(correlationID),
            "scenario": .object([
                "Dimensions": .array([
                    .object(["DimensionName": .string("QueryType"), "DimensionValue": .string("Messages")]),
                    .object(["DimensionName": .string("FormFactor"), "DimensionValue": .string("TeamsChat.macOS.reactSearch")])
                ]),
                "Name": .string("powerbar")
            ]),
            "timezone": .string(TimeZone.current.identifier)
        ]
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func escapePhrase(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func decodePage(_ data: Data) throws -> TeamsMessageSearchPage {
        guard let root = try? JSONDecoder().decode([String: TeamsWebJSONValue].self, from: data),
              case let .array(entitySets)? = root["EntitySets"] else { throw TeamsSearchError.invalidResponse }
        var matches: [TeamsMessageSearchResult] = []
        var total: Int?
        var hasMore = false
        for case let .object(entitySet) in entitySets {
            guard case let .array(resultSets)? = entitySet["ResultSets"] else { continue }
            for case let .object(resultSet) in resultSets {
                if case let .number(value)? = resultSet["Total"] { total = NSDecimalNumber(decimal: value).intValue }
                if case let .bool(value)? = resultSet["MoreResultsAvailable"] { hasMore = hasMore || value }
                guard case let .array(results)? = resultSet["Results"] else { continue }
                for case let .object(hit) in results {
                    guard case let .object(source)? = hit["Source"] ?? hit["S"] else { continue }
                    let messageID = scalar(source["InternetMessageId"])
                    guard let id = scalar(hit["Id"]) ?? messageID, !id.isEmpty else { continue }
                    let conversation = scalar(source["ClientThreadId"]) ?? scalar(source["ClientConversationId"])
                    let chatID = conversation?.components(separatedBy: ";messageid=").first
                    let rawPreview = scalar(source["Preview"]) ?? scalar(hit["HitHighlightedSummary"]) ?? ""
                    let preview = TeamsBodyParser.parse(rawPreview.replacingOccurrences(of: "\u{e000}", with: "")
                        .replacingOccurrences(of: "\u{e001}", with: "")).text
                    let sender = object(object(source["Sender"])["EmailAddress"])
                    let from = object(object(source["From"])["EmailAddress"])
                    let extensions = object(source["Extensions"])
                    matches.append(.init(
                        id: id, messageID: messageID, chatID: chatID, preview: preview,
                        senderName: scalar(sender["Name"]) ?? scalar(from["Name"]),
                        senderID: scalar(extensions["SkypeSpaces_ConversationPost_Extension_FromSkypeInternalId"]),
                        sentAt: scalar(source["DateTimeSent"]),
                        conversationTitle: scalar(source["ConversationTopic"]) ?? scalar(source["Subject"])
                    ))
                }
            }
        }
        var seen: Set<String> = []
        matches = matches.filter { seen.insert($0.id).inserted }
        return .init(results: matches, total: total, hasMore: hasMore)
    }

    private static func scalar(_ value: TeamsWebJSONValue?) -> String? {
        switch value {
        case .string(let string): string
        case .number(let number): NSDecimalNumber(decimal: number).stringValue
        default: nil
        }
    }

    private static func object(_ value: TeamsWebJSONValue?) -> [String: TeamsWebJSONValue] {
        if case let .object(result) = value { return result }
        return [:]
    }
}
