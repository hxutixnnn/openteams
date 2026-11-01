import Foundation

public struct TeamsReadState: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case known(originalArrival: UInt64, timestamp: UInt64, clientID: String)
        case unset
        case absent
        case malformed
    }
    public let horizon: Value
    public let bookmark: Value
    public let version: String?

    static func parse(_ value: TeamsWebJSONValue?) -> Value {
        guard let value else { return .absent }
        if case .null = value { return .absent }
        guard case .string(let raw) = value else { return .malformed }
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 30 && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let arrival = UInt64(parts[0]), let timestamp = UInt64(parts[1]) else { return .malformed }
        return .known(originalArrival: arrival, timestamp: timestamp, clientID: String(parts[2]))
    }
}

public struct TeamsReadStateClient: Sendable {
    private let session: TeamsWebSession
    private let transport: any HTTPTransport
    public init(session: TeamsWebSession, transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.session = session; self.transport = transport
    }
    public func state(in chatID: String) async throws -> TeamsReadState {
        try session.validate()
        guard let messaging = session.messaging else { throw TeamsWebClientError.sendingUnavailable }
        try messaging.validate()
        guard !chatID.isEmpty, chatID != ".", chatID != "..", chatID.utf8.count <= 1024,
              chatID.rangeOfCharacter(from: .controlCharacters) == nil else { throw TeamsWebClientError.invalidChatID }
        guard var components = URLComponents(url: messaging.baseURL, resolvingAgainstBaseURL: false) else { throw TeamsWebClientError.unsafeBaseURL }
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + "/v1/users/ME/conversations/" + TeamsWebClient.escapedID(chatID)
        components.queryItems = [.init(name: "view", value: "msnp24Equivalent")]
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
        guard data.count <= 1_000_000 else { throw TeamsWebClientError.invalidResponse }
        let value: TeamsWebJSONValue
        do { value = try JSONDecoder().decode(TeamsWebJSONValue.self, from: data) }
        catch { throw TeamsWebClientError.invalidResponse }
        guard case .object(let root) = value else { throw TeamsWebClientError.invalidResponse }
        guard case .string(let id)? = root["id"], id == chatID else { throw TeamsWebClientError.invalidResponse }
        let version: String?
        switch root["version"] {
        case .string(let value): version = Self.numericVersion(value)
        case .number(let value): version = Self.numericVersion(NSDecimalNumber(decimal: value).stringValue)
        default: version = nil
        }
        guard case .object(let properties)? = root["properties"] else { return .init(horizon: .absent, bookmark: .absent, version: version) }
        let horizon = TeamsReadState.parse(properties["consumptionhorizon"])
        let bookmark: TeamsReadState.Value
        if properties["consumptionHorizonBookmark"] == nil, case .known = horizon { bookmark = .unset }
        else { bookmark = TeamsReadState.parse(properties["consumptionHorizonBookmark"]) }
        return .init(horizon: horizon, bookmark: bookmark, version: version)
    }
    private static func numericVersion(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 32, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return String(value.drop(while: { $0 == "0" }))
    }
}
