import Foundation
import CryptoKit

public struct TeamsSharedItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case file, link }
    public let id: String
    public let kind: Kind
    public let title: String
    public let url: URL?
    public let sharedBy: String?
    public let sharedDate: String?
    public let messageID: String?
    public let parentMessageID: String?
    public let immutableID: String?
}

public struct TeamsSharedPage: Sendable {
    public let items: [TeamsSharedItem]
    public let hasMore: Bool
    public let bookmark: String?
    public let rawCount: Int
    public let fingerprint: String
    public var unsupportedCount: Int { rawCount - items.count }
}

public struct TeamsSharedPaginationTracker {
    private var pages = Set<String>()
    private var items = Set<String>()
    public init() {}
    public mutating func accept(_ page: TeamsSharedPage) throws -> [TeamsSharedItem] {
        if page.rawCount > 0 && pages.contains(page.fingerprint) { throw TeamsSharedError.repeatedPage }
        if page.rawCount > 0 { pages.insert(page.fingerprint) }
        return page.items.filter { items.insert($0.id).inserted }
    }
}

public enum TeamsSharedError: Error, LocalizedError, Sendable {
    case unavailable, invalidRequest, invalidResponse, repeatedPage, network, http(Int, TimeInterval?)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Reconnect to use the shared-items index."
        case .invalidRequest: "This shared-items request is invalid."
        case .invalidResponse: "The shared-items service returned an unexpected response."
        case .repeatedPage: "The shared-items service repeated a page. Loading stopped."
        case .network: "Could not reach the shared-items service."
        case let .http(status, delay): status == 401 ? "Shared items could not authenticate. Reconnect to load shared items." : status == 429 ? "Shared items are temporarily limited. Try again\(delay.map { " in \(Int(ceil($0))) seconds" } ?? " later")." : "Shared items are unavailable (HTTP \(status))."
        }
    }
}

public struct TeamsSharedIndexClient: Sendable {
    private let session: TeamsSearchSession
    private let transport: any HTTPTransport
    public init(session: TeamsSearchSession, transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.session = session; self.transport = transport
    }
    public func page(chatID: String, bookmark: String? = nil, offset: Int = 0, pageSize: Int = 50) async throws -> TeamsSharedPage {
        do { try session.validate() } catch { throw TeamsSharedError.unavailable }
        guard !chatID.isEmpty, chatID.utf8.count <= 1024, chatID.rangeOfCharacter(from: .controlCharacters) == nil,
              (0...100_000).contains(offset), (1...100).contains(pageSize), bookmark?.utf8.count ?? 0 <= 4096 else { throw TeamsSharedError.invalidRequest }
        var components = URLComponents(string: "https://substrate.office.com")!
        components.percentEncodedPath = "/AllFiles/api/users('OID:" + TeamsWebClient.escapedID(session.accountID + "@" + session.tenantID) + "')/AllShared"
        var query = [URLQueryItem(name: "ThreadId", value: chatID), .init(name: "ItemTypes", value: "File"), .init(name: "ItemTypes", value: "Link"), .init(name: "PageSize", value: String(pageSize))]
        if let bookmark, !bookmark.isEmpty { query.append(.init(name: "Bookmark", value: bookmark)) }
        if offset > 0 { query.append(.init(name: "Skip", value: String(offset))) }
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw TeamsSharedError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(ISO8601DateFormatter().string(from: Date()), forHTTPHeaderField: "X-Client-LocalTime")
        request.setValue("Oid:\(session.accountID)@\(session.tenantID)", forHTTPHeaderField: "X-AnchorMailbox")
        request.setValue("TeamsSharedInChat", forHTTPHeaderField: "scenarioTag")
        let correlation = UUID().uuidString
        request.setValue(correlation, forHTTPHeaderField: "ClientRequestId")
        request.setValue(correlation, forHTTPHeaderField: "client-request-id")
        let data: Data; let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw TeamsSharedError.network }
        guard (200..<300).contains(response.statusCode) else { throw TeamsSharedError.http(response.statusCode, TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))) }
        struct File: Decodable { let FileUrl: String?; let FileName: String?; let WebUrl: String?; let ImmutableId: String? }
        struct Weblink: Decodable { let WebUrl: String?; let Title: String? }
        struct Item: Decodable { let FileData: File?; let WeblinkData: Weblink?; let SharedDateTime: String?; let SharedByDisplayName: String?; let TeamsMessageId: String?; let ParentMessageId: String?; let ThreadId: String? }
        struct Response: Decodable { let Items: [Item]; let HasMoreItems: Bool; let Bookmark: String? }
        guard data.count <= 5_000_000, let response = try? JSONDecoder().decode(Response.self, from: data), response.Items.count <= 500,
              response.Bookmark?.utf8.count ?? 0 <= 4096 else { throw TeamsSharedError.invalidResponse }
        func safeURL(_ text: String?) -> URL? {
            guard let text, text.utf8.count <= 8192, let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
                  parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
            return parts.url
        }
        let items = response.Items.compactMap { item -> TeamsSharedItem? in
            guard item.ThreadId == nil || item.ThreadId == chatID else { return nil }
            let kind: TeamsSharedItem.Kind; let title: String; let url: URL?
            if let file = item.FileData, let name = file.FileName, !name.isEmpty {
                kind = .file; title = name; url = safeURL(file.WebUrl) ?? safeURL(file.FileUrl)
            } else if let link = item.WeblinkData, let linkURL = safeURL(link.WebUrl) {
                kind = .link; title = link.Title.flatMap { $0.isEmpty ? nil : $0 } ?? linkURL.host ?? "Link"; url = linkURL
            } else { return nil }
            let message = item.TeamsMessageId.flatMap { $0.isEmpty ? nil : $0 }
            let parent = item.ParentMessageId.flatMap { $0.isEmpty ? nil : $0 }
            let immutable = item.FileData?.ImmutableId.flatMap { $0.isEmpty ? nil : $0 }
            let identity = [kind.rawValue, immutable ?? "", url?.absoluteString ?? "", message ?? "", parent ?? "", item.SharedDateTime ?? "", title].joined(separator: "\n")
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            return .init(id: id, kind: kind, title: title, url: url,
                         sharedBy: item.SharedByDisplayName, sharedDate: item.SharedDateTime, messageID: message, parentMessageID: parent, immutableID: immutable)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = object["Items"] as? [Any],
              let canonical = try? JSONSerialization.data(withJSONObject: rawItems, options: [.sortedKeys, .fragmentsAllowed]) else { throw TeamsSharedError.invalidResponse }
        let fingerprint = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        return .init(items: items, hasMore: response.HasMoreItems, bookmark: response.Bookmark, rawCount: response.Items.count, fingerprint: fingerprint)
    }
}
