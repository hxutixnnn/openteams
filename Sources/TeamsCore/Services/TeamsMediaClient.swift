import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum TeamsMediaError: Error, Equatable {
    case unavailable, invalidCredential, unsafeURL, invalidResponse, tooLarge
    case http(Int, retryAfter: TimeInterval?)
}

public protocol TeamsMediaFetching: Sendable {
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse)
}

/// Media credentials and downloaded bytes exist only for this account session.
public actor TeamsMediaClient {
    private struct TokenResponse: Decodable {
        struct Tokens: Decodable { let skypeToken: String; let expiresIn: Double }
        struct Routes: Decodable { let ams: String?; let amsV2: String? }
        let tokens: Tokens
        let regionGtms: Routes
    }
    private struct Claims: Decodable { let skypeid: String; let tid: String?; let exp: Double? }
    private struct DirectoryClaims: Decodable { let aud: String; let oid: String; let tid: String; let exp: Double }
    private let accountID: String
    private let tenantID: String
    private var directory: TeamsDirectorySession
    private var credential: (token: String, expires: Date, hosts: Set<String>)?
    private var acquisition: Task<(token: String, expires: Date, hosts: Set<String>), Error>?
    private var avatars: [String: Data] = [:]
    private var avatarTasks: [String: Task<Data, Error>] = [:]
    private var missingAvatars: [String: Date] = [:]
    private var images: [URL: Data] = [:]
    private var imageTasks: [URL: Task<Data, Error>] = [:]
    private var closed = false
    private var backoffUntil = Date.distantPast
    private let limiter = TeamsMediaLimiter()
    private let transport: any TeamsMediaFetching

    public init(session: TeamsWebSession) throws {
        try self.init(session: session, transport: TeamsMediaTransport())
    }

    public init(session: TeamsWebSession, transport: any TeamsMediaFetching) throws {
        try session.validate()
        guard let directory = session.directory else { throw TeamsMediaError.unavailable }
        try Self.validate(directory, account: session.accountID, tenant: session.tenantID)
        self.accountID = session.accountID
        self.tenantID = session.tenantID
        self.directory = directory
        self.transport = transport
    }

    private static func validate(_ directory: TeamsDirectorySession, account: String, tenant: String) throws {
        try directory.validate()
        guard let claims: DirectoryClaims = Self.claims(directory.accessToken),
              claims.aud.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://api.spaces.skype.com",
              claims.oid.lowercased() == account.lowercased(), claims.tid.lowercased() == tenant.lowercased(),
              claims.exp.isFinite, Date(timeIntervalSince1970: claims.exp) > Date() else { throw TeamsMediaError.invalidCredential }
    }

    public func update(session: TeamsWebSession) throws {
        guard !closed, session.accountID == accountID, session.tenantID == tenantID,
              let newDirectory = session.directory else { throw TeamsMediaError.invalidCredential }
        try Self.validate(newDirectory, account: accountID, tenant: tenantID)
        directory = newDirectory
    }

    /// Reads only the installed-app endpoint on the account's validated middle-tier origin.
    public func installedAgents(in chatID: String) async throws -> [TeamsInstalledAgent] {
        guard !closed, !chatID.isEmpty, chatID.utf8.count <= 1024,
              chatID != ".", chatID != "..", chatID.rangeOfCharacter(from: .controlCharacters) == nil else { throw TeamsMediaError.unavailable }
        let current = directory
        try Self.validate(current, account: accountID, tenant: tenantID)
        let credential = try await token(force: false)
        guard !closed, directory.accessToken == current.accessToken, credential.expires > Date() else { throw CancellationError() }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        guard let encoded = chatID.addingPercentEncoding(withAllowedCharacters: allowed),
              var components = URLComponents(url: current.baseURL, resolvingAgainstBaseURL: false) else { throw TeamsMediaError.unsafeURL }
        components.percentEncodedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + components.percentEncodedPath + "/beta/chats/" + encoded + "/apps/chatentitlements"
        guard let url = components.url else { throw TeamsMediaError.unsafeURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer " + current.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(credential.token, forHTTPHeaderField: "x-skypetoken")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await limitedRead(request, limit: 2_000_000)
        guard !closed, directory.accessToken == current.accessToken, !Task.isCancelled else { throw CancellationError() }
        try checkStatus(response)
        guard response.mimeType?.lowercased() == "application/json",
              let envelope = try? JSONDecoder().decode(TeamsInstalledAppsEnvelope.self, from: data),
              envelope.errorCode?.isEmpty != false else { throw TeamsMediaError.invalidResponse }
        return envelope.agents()
    }

    public func image(at url: URL, fullSize: Bool = false) async throws -> Data {
        guard !closed else { throw CancellationError() }
        let current = try await token(force: false)
        guard Self.isAllowed(url, hosts: current.hosts) else { throw TeamsMediaError.unsafeURL }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw TeamsMediaError.unsafeURL }
        if fullSize {
            let animated = components.path.hasSuffix("_anim")
            guard let view = components.path.range(of: "/views/", options: .backwards) else { throw TeamsMediaError.unsafeURL }
            components.path = String(components.path.prefix(upTo: view.upperBound)) + (animated ? "imgpsh_fullsize_anim" : "imgpsh_fullsize")
        }
        guard let target = components.url else { throw TeamsMediaError.unsafeURL }
        if fullSize { components.fragment = "native-fullsize-cache" }
        guard let key = components.url else { throw TeamsMediaError.unsafeURL }
        if let data = images[key] { return data }
        if let task = imageTasks[key] { let data = try await task.value; try Task.checkCancellation(); return data }
        let task = Task { try await self.fetchImage(at: target, maxPixel: fullSize ? 4096 : 1200) }
        imageTasks[key] = task
        do {
            let data = try await task.value
            guard !closed else { throw CancellationError() }
            if images.count >= 100 || images.values.reduce(0, { $0 + $1.count }) + data.count > 16_000_000 { images.removeAll() }
            if data.count <= 16_000_000 { images[key] = data }
            imageTasks[key] = nil
            try Task.checkCancellation()
            return data
        } catch {
            imageTasks[key] = nil
            throw error
        }
    }

    private func fetchImage(at url: URL, maxPixel: Int) async throws -> Data {
        for attempt in 0...1 {
            let current = try await token(force: false)
            try Task.checkCancellation()
            guard Self.isAllowed(url, hosts: current.hosts) else { throw TeamsMediaError.unsafeURL }
            var request = URLRequest(url: url)
            request.setValue("skype_token " + current.token, forHTTPHeaderField: "Authorization")
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await limitedRead(request, limit: 8_000_000)
            try Task.checkCancellation()
            if response.statusCode == 401 && attempt == 0 {
                if credential?.token == current.token { credential = nil }
                continue
            }
            try checkStatus(response)
            guard response.mimeType?.lowercased().hasPrefix("image/") == true,
                  let prepared = Self.prepareImage(data, maxPixel: maxPixel) else { throw TeamsMediaError.invalidResponse }
            return prepared
        }
        throw TeamsMediaError.unavailable
    }

    public func profilePhoto(for personID: String) async throws -> Data {
        guard !closed else { throw CancellationError() }
        let rawID = personID.hasPrefix("8:orgid:") ? String(personID.dropFirst(8)) : personID
        guard let uuid = UUID(uuidString: rawID) else { throw TeamsMediaError.unavailable }
        let id = uuid.uuidString.lowercased()
        if let until = missingAvatars[id], until > Date() { throw TeamsMediaError.http(404, retryAfter: nil) }
        if let cached = avatars[id] { return cached }
        if let task = avatarTasks[id] { return try await task.value }
        let task = Task { try await self.fetchProfilePhoto(id) }
        avatarTasks[id] = task
        do {
            let data = try await task.value
            guard !closed else { throw CancellationError() }
            if avatars.count >= 100 || avatars.values.reduce(0, { $0 + $1.count }) + data.count > 8_000_000 { avatars.removeAll() }
            avatars[id] = data
            avatarTasks[id] = nil
            return data
        } catch {
            avatarTasks[id] = nil
            if case TeamsMediaError.http(404, _) = error {
                if missingAvatars.count >= 100 { missingAvatars.removeAll() }
                missingAvatars[id] = Date().addingTimeInterval(600)
            }
            throw error
        }
    }

    private func fetchProfilePhoto(_ id: String) async throws -> Data {
        for attempt in 0...1 {
            let current = directory
            try current.validate()
            let url = current.baseURL.appendingPathComponent("beta").appendingPathComponent("users")
                .appendingPathComponent(accountID).appendingPathComponent("profilepicturev2")
                .appendingPathComponent("8:orgid:" + id)
            var request = URLRequest(url: url)
            request.setValue("Bearer " + current.accessToken, forHTTPHeaderField: "Authorization")
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await limitedRead(request, limit: 1_000_000)
            if response.statusCode == 401, attempt == 0, current.accessToken != directory.accessToken { continue }
            try checkStatus(response)
            guard response.mimeType?.lowercased().hasPrefix("image/") == true, let prepared = Self.prepareImage(data) else { throw TeamsMediaError.invalidResponse }
            return prepared
        }
        throw TeamsMediaError.unavailable
    }

    public func groupPhoto(for members: [TeamsWebMember], chatID: String? = nil, picture: String? = nil, pictureVersion: String? = nil) async throws -> Data {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        if let chatID, (chatID.isEmpty || chatID == "." || chatID == ".." || chatID.utf8.count > 1024 || chatID.rangeOfCharacter(from: .controlCharacters) != nil) { throw TeamsMediaError.unsafeURL }
        let version = pictureVersion.flatMap { $0.utf8.count <= 256 && $0.rangeOfCharacter(from: .controlCharacters) == nil ? $0 : nil } ?? ""
        let users: [[String: String]] = members.compactMap { member in
            guard member.kind == .person, let mri = member.mri else { return nil }
            let raw = String(mri.dropFirst("8:orgid:".count))
            guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() != accountID.lowercased(),
                  let name = member.preferredDisplayName, !name.isEmpty else { return nil }
            var user = ["userId": "8:orgid:" + uuid.uuidString.lowercased(), "displayName": String(name.prefix(200))]
            if let tag = member.avatarETag, !tag.isEmpty, tag.utf8.count <= 512, tag.rangeOfCharacter(from: .controlCharacters) == nil { user["avatarETag"] = tag }
            if let tenant = member.tenantId, let uuid = UUID(uuidString: tenant) { user["tenantId"] = uuid.uuidString.lowercased() }
            return user
        }.sorted { ($0["displayName"] ?? "") < ($1["displayName"] ?? "") }.prefix(3).map { $0 }
        guard let json = try? JSONSerialization.data(withJSONObject: users, options: [.sortedKeys]),
              let encoded = String(data: json, encoding: .utf8) else { throw TeamsMediaError.unavailable }
        if let chatID, let picture, !chatID.isEmpty, chatID != ".", chatID != "..", chatID.utf8.count <= 1024,
           chatID.rangeOfCharacter(from: .controlCharacters) == nil, picture.utf8.count <= 4096,
           picture.rangeOfCharacter(from: .controlCharacters) == nil,
           let suffix = picture.split(separator: "@", omittingEmptySubsequences: false).last, !suffix.isEmpty {
            let key = "custom:" + chatID + "\n" + picture + "\n" + version + "\n" + encoded
            do { return try await cachedGroupPhoto(key: key, users: encoded, chatID: chatID, document: String(suffix)) }
            catch is CancellationError { throw CancellationError() }
            catch let error as TeamsMediaError {
                if case .http(401, _) = error { throw error }
                if case .http(429, _) = error { throw error }
            }
            catch { }
        }
        try Task.checkCancellation()
        guard users.count >= 2 else { throw TeamsMediaError.unavailable }
        return try await cachedGroupPhoto(key: "group:" + (chatID ?? "") + "\n" + version + "\n" + encoded, users: encoded, chatID: nil, document: nil)
    }

    private func cachedGroupPhoto(key: String, users: String, chatID: String?, document: String?) async throws -> Data {
        if let cached = avatars[key] { return cached }
        if let task = avatarTasks[key] { let result = try await task.value; try Task.checkCancellation(); return result }
        let task = Task { try await self.fetchGroupPhoto(users, chatID: chatID, document: document) }
        avatarTasks[key] = task
        do {
            let data = try await task.value
            guard !closed else { throw CancellationError() }
            if avatars.count >= 100 || avatars.values.reduce(0, { $0 + $1.count }) + data.count > 8_000_000 { avatars.removeAll() }
            avatars[key] = data; avatarTasks[key] = nil
            try Task.checkCancellation()
            return data
        } catch { avatarTasks[key] = nil; throw error }
    }

    private func fetchGroupPhoto(_ users: String, chatID: String?, document: String?) async throws -> Data {
        for attempt in 0...1 {
            let current = directory
            try current.validate()
            guard var parts = URLComponents(url: current.baseURL, resolvingAgainstBaseURL: false) else { throw TeamsMediaError.unsafeURL }
            let base = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let account = TeamsWebClient.escapedID(accountID)
            if let chatID, let document {
                parts.percentEncodedPath = "/" + base + "/beta/users/" + account + "/threads/" + TeamsWebClient.escapedID(chatID) + "/properties/pictureV2"
                parts.queryItems = [.init(name: "usersInfo", value: users), .init(name: "documentUrl", value: document), .init(name: "size", value: "48")]
            } else {
                parts.percentEncodedPath = "/" + base + "/beta/users/" + account + "/mergedProfilePicturev2"
                parts.queryItems = [.init(name: "usersInfo", value: users), .init(name: "size", value: "48")]
            }
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = parts.url else { throw TeamsMediaError.unsafeURL }
            var request = URLRequest(url: url)
            request.setValue("Bearer " + current.accessToken, forHTTPHeaderField: "Authorization")
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await limitedRead(request, limit: 1_000_000)
            try Task.checkCancellation()
            if response.statusCode == 401, attempt == 0, current.accessToken != directory.accessToken { continue }
            try checkStatus(response)
            guard response.mimeType?.lowercased().hasPrefix("image/") == true, let prepared = Self.prepareImage(data) else { throw TeamsMediaError.invalidResponse }
            return prepared
        }
        throw TeamsMediaError.unavailable
    }

    private func token(force: Bool) async throws -> (token: String, expires: Date, hosts: Set<String>) {
        if !force, let credential, credential.expires > Date().addingTimeInterval(30) { return credential }
        if let acquisition { return try await acquisition.value }
        let task = Task { try await self.acquire() }
        acquisition = task
        do {
            let value = try await task.value
            guard !closed else { throw CancellationError() }
            credential = value
            acquisition = nil
            return value
        } catch {
            acquisition = nil
            throw error
        }
    }

    private func acquire() async throws -> (token: String, expires: Date, hosts: Set<String>) {
        try directory.validate()
        var request = URLRequest(url: URL(string: "https://teams.microsoft.com/api/authsvc/v1.0/authz")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + directory.accessToken, forHTTPHeaderField: "Authorization")
        let start = Date()
        let (data, response) = try await limitedRead(request, limit: 128_000)
        try checkStatus(response)
        guard let result = try? JSONDecoder().decode(TokenResponse.self, from: data),
              result.tokens.expiresIn.isFinite, (1...86_400).contains(result.tokens.expiresIn),
              !result.tokens.skypeToken.isEmpty, result.tokens.skypeToken.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              let claims: Claims = Self.claims(result.tokens.skypeToken),
              claims.skypeid.lowercased() == "orgid:" + accountID.lowercased(),
              claims.tid == nil || claims.tid?.lowercased() == tenantID.lowercased() else { throw TeamsMediaError.invalidCredential }
        var expires = start.addingTimeInterval(result.tokens.expiresIn)
        if let exp = claims.exp {
            guard exp.isFinite else { throw TeamsMediaError.invalidCredential }
            expires = min(expires, Date(timeIntervalSince1970: exp))
        }
        guard expires > Date() else { throw TeamsMediaError.invalidCredential }
        let hosts = Set([result.regionGtms.ams, result.regionGtms.amsV2].compactMap { value -> String? in
            guard let value, let c = URLComponents(string: value), c.scheme == "https", let host = c.host?.lowercased(),
                  c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil,
                  host.range(of: "^[a-z0-9-]+\\.asm\\.skype\\.com$", options: .regularExpression) != nil else { return nil }
            return host
        })
        guard !hosts.isEmpty else { throw TeamsMediaError.invalidCredential }
        return (token: result.tokens.skypeToken, expires: expires, hosts: hosts)
    }

    private static func claims<T: Decodable>(_ token: String) -> T? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var part = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        part += String(repeating: "=", count: (4 - part.count % 4) % 4)
        guard let data = Data(base64Encoded: part) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public static func isAllowed(_ url: URL, hosts: Set<String>) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              let host = c.host?.lowercased(), hosts.contains(host), c.port == nil, c.user == nil, c.password == nil,
              (c.percentEncodedQuery == nil || c.percentEncodedQuery == "v=1"), c.fragment == nil else { return false }
        return c.percentEncodedPath.range(of: "^/v1/objects/[A-Za-z0-9._-]+/views/(imgo|imgt1|imgt1_anim|imgpsh_fullsize|imgpsh_fullsize_anim|original)$", options: .regularExpression) != nil
    }

    public static func validImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let count = CGImageSourceGetCount(source)
        guard (1...100).contains(count) else { return false }
        var total: Int64 = 0
        for index in 0..<count {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
                  (1...8192).contains(width), (1...8192).contains(height) else { return false }
            total += Int64(width) * Int64(height)
            guard total <= (count == 1 ? 16_000_000 : 8_000_000) else { return false }
        }
        return true
    }

    static func prepareImage(_ data: Data, maxPixel: Int = 1200) -> Data? {
        guard validImage(data), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        if count > 1 {
            for index in 0..<count where CGImageSourceCreateImageAtIndex(source, index, nil) == nil { return nil }
            return data
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                       kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    public func invalidate() {
        closed = true
        acquisition?.cancel(); acquisition = nil
        imageTasks.values.forEach { $0.cancel() }; imageTasks.removeAll()
        avatarTasks.values.forEach { $0.cancel() }; avatarTasks.removeAll()
        credential = nil; images.removeAll(); avatars.removeAll(); missingAvatars.removeAll()
    }

    private func checkStatus(_ response: HTTPURLResponse) throws {
        guard response.statusCode != 200 else { return }
        let delay = TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
        throw TeamsMediaError.http(response.statusCode, retryAfter: delay)
    }

    private func limitedRead(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard !closed else { throw CancellationError() }
        guard backoffUntil <= Date() else { throw TeamsMediaError.http(429, retryAfter: backoffUntil.timeIntervalSinceNow) }
        await limiter.acquire()
        do {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            guard backoffUntil <= Date() else { throw TeamsMediaError.http(429, retryAfter: backoffUntil.timeIntervalSinceNow) }
            let result = try await transport.read(request, limit: limit)
            if result.1.statusCode == 429 {
                let delay = TeamsWebClient.retryAfter(result.1.value(forHTTPHeaderField: "Retry-After")) ?? 60
                backoffUntil = max(backoffUntil, Date().addingTimeInterval(max(delay, 1)))
            }
            await limiter.release()
            return result
        } catch {
            await limiter.release()
            throw error
        }
    }
}

private actor TeamsMediaLimiter {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
}

private final class TeamsMediaTransport: NSObject, TeamsMediaFetching, URLSessionTaskDelegate, @unchecked Sendable {
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw TeamsMediaError.invalidResponse }
        guard response.expectedContentLength < 0 || response.expectedContentLength <= limit else { throw TeamsMediaError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw TeamsMediaError.tooLarge }
            data.append(byte)
        }
        return (data, response)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}


public struct TeamsSharePointMetadataSummary: Sendable {
    public let status: Int
    public let mimeType: String?
    public let byteCount: Int
    public let hasID: Bool
    public let hasName: Bool
    public let hasFile: Bool
    public let retryAfter: TimeInterval?
}

public struct TeamsSharePointMetadataClient: Sendable {
    private let transport: any TeamsMediaFetching
    public init() { transport = TeamsMediaTransport() }
    public init(transport: any TeamsMediaFetching) { self.transport = transport }

    public func read(attachment: TeamsSharePointAttachment, bearer: String) async throws -> TeamsSharePointMetadataSummary {
        guard let resource = attachment.resource, !bearer.isEmpty,
              !attachment.fileID.isEmpty, attachment.fileID != ".", attachment.fileID != "..", attachment.fileID.utf8.count <= 1024,
              attachment.fileID.rangeOfCharacter(from: .controlCharacters) == nil,
              var parts = URLComponents(url: attachment.baseURL, resolvingAgainstBaseURL: false) else { throw TeamsMediaError.invalidResponse }
        let base = parts.percentEncodedPath.hasSuffix("/") ? String(parts.percentEncodedPath.dropLast()) : parts.percentEncodedPath
        parts.percentEncodedPath = base + "/_api/v2.0/sites/root/items/" + TeamsWebClient.escapedID(attachment.fileID) + "/driveItem/"
        parts.queryItems = [URLQueryItem(name: "select", value: "id,name,file")]
        guard let url = parts.url, url.scheme == "https", url.host?.lowercased() == URL(string: resource.origin)?.host else { throw TeamsMediaError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        try Task.checkCancellation()
        let (data, response) = try await transport.read(request, limit: 128_000)
        try Task.checkCancellation()
        guard response.url?.scheme?.lowercased() == "https", response.url?.host?.lowercased() == url.host?.lowercased(),
              response.url?.port == nil else { throw TeamsMediaError.invalidResponse }
        let object = response.statusCode == 200 ? ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) : nil
        return TeamsSharePointMetadataSummary(status: response.statusCode, mimeType: response.mimeType, byteCount: data.count,
                                               hasID: object?["id"] is String, hasName: object?["name"] is String,
                                               hasFile: object?["file"] is [String: Any],
                                               retryAfter: TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
    }
}

public struct TeamsSharePointContentClient: Sendable {
    private let transport: any TeamsMediaFetching
    public init() { transport = TeamsMediaTransport() }
    public init(transport: any TeamsMediaFetching) { self.transport = transport }

    public func preview(attachment: TeamsSharePointAttachment, bearer: String) async throws -> Data {
        guard attachment.supportsPreview, let resource = attachment.resource, !bearer.isEmpty, bearer.utf8.count <= 32768,
              bearer.rangeOfCharacter(from: .controlCharacters) == nil,
              let object = URLComponents(url: attachment.objectURL, resolvingAgainstBaseURL: false),
              var base = URLComponents(url: attachment.baseURL, resolvingAgainstBaseURL: false) else { throw TeamsMediaError.unsafeURL }
        let encodedPath = object.percentEncodedPath
        guard !encodedPath.lowercased().contains("%2f"), !encodedPath.lowercased().contains("%5c"),
              let path = encodedPath.removingPercentEncoding, path.hasPrefix("/"),
              !path.lowercased().contains("/_api/"),
              path.rangeOfCharacter(from: CharacterSet(charactersIn: "%#\\").union(.controlCharacters)) == nil else { throw TeamsMediaError.unsafeURL }
        let basePath = base.percentEncodedPath.hasSuffix("/") ? String(base.percentEncodedPath.dropLast()) : base.percentEncodedPath
        base.percentEncodedPath = basePath + "/_api/web/GetFileByServerRelativeUrl(@a1)/$value/"
        let alias = "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encodedAlias = alias.addingPercentEncoding(withAllowedCharacters: unreserved) else { throw TeamsMediaError.unsafeURL }
        base.percentEncodedQuery = "%40a1=" + encodedAlias
        guard let url = base.url, url.scheme?.lowercased() == "https", url.host?.lowercased() == URL(string: resource.origin)?.host else { throw TeamsMediaError.unsafeURL }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try Task.checkCancellation()
        let (data, response) = try await transport.read(request, limit: 8_000_000)
        try Task.checkCancellation()
        guard response.url?.scheme?.lowercased() == "https", response.url?.host?.lowercased() == url.host?.lowercased(), response.url?.port == nil else { throw TeamsMediaError.unsafeURL }
        guard response.statusCode == 200 else { throw TeamsMediaError.http(response.statusCode, retryAfter: TeamsWebClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))) }
        guard data.count <= 8_000_000, let mime = response.mimeType?.lowercased() else { throw TeamsMediaError.invalidResponse }
        if attachment.supportsPDFPreview {
            guard mime == "application/pdf", data.starts(with: Data("%PDF-".utf8)),
                  let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                  (!document.isEncrypted || document.isUnlocked), (1...100).contains(document.numberOfPages) else { throw TeamsMediaError.invalidResponse }
            for index in 1...document.numberOfPages {
                guard let page = document.page(at: index) else { throw TeamsMediaError.invalidResponse }
                let size = page.getBoxRect(.mediaBox).size
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      size.width <= 14400, size.height <= 14400 else { throw TeamsMediaError.invalidResponse }
            }
            try Task.checkCancellation()
            return data
        }
        guard ["image/png", "image/jpeg", "image/heic", "image/heif"].contains(mime),
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let preview = TeamsMediaClient.prepareImage(data, maxPixel: 1800) else { throw TeamsMediaError.invalidResponse }
        try Task.checkCancellation()
        return preview
    }
}
