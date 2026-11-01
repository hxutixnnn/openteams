import Foundation
import CoreGraphics
import Testing
import TeamsCore
import TeamsCredentialPersistence
@testable import TeamsChat

@MainActor private final class MemoryCredentials: TeamsCredentialAccess {
    var value: TeamsCredentials?
    var saves: [TeamsCredentials] = []
    var failUncertain = false
    var failInteraction = false
    var failUnexpectedly = false
    var holdSave = false
    var pendingSave: CheckedContinuation<Void, Never>?
    func load(interactive: Bool) async throws -> TeamsCredentials? { value }
    func save(_ credentials: TeamsCredentials) async throws {
        if failUncertain { throw TeamsCredentialError.outcomeUnknown }
        if failInteraction { throw TeamsCredentialError.interactionRequired }
        if failUnexpectedly { throw URLError(.cannotConnectToHost) }
        if holdSave { await withCheckedContinuation { pendingSave = $0 } }
        value = credentials; saves.append(credentials)
    }
    func delete() async throws { value = nil }
}

private actor RenewalTransport: HTTPTransport {
    let csa: String
    let messaging: String
    let optionalStatus: Int
    let secondStatus: Int
    let holdSecond: Bool
    let secondBody: String
    let searchAfterThrottle: String?
    private(set) var tokenCalls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(csa: String, messaging: String, optionalStatus: Int = 429, secondStatus: Int = 200, holdSecond: Bool = false, secondBody: String = "{}", searchAfterThrottle: String? = nil) {
        self.csa = csa; self.messaging = messaging; self.optionalStatus = optionalStatus
        self.secondStatus = secondStatus; self.holdSecond = holdSecond; self.secondBody = secondBody; self.searchAfterThrottle = searchAfterThrottle
    }
    func releaseSecond() { continuation?.resume(); continuation = nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == "login.microsoftonline.com" {
            tokenCalls += 1
            let index = tokenCalls
            if index == 2 && holdSecond { await withCheckedContinuation { continuation = $0 } }
            if index == 2 && secondStatus != 200 { return (Data(secondBody.utf8), HTTPURLResponse(url: request.url!, statusCode: secondStatus, httpVersion: nil, headerFields: nil)!) }
            if index > 3, let searchAfterThrottle {
                let body = try JSONSerialization.data(withJSONObject: ["access_token": searchAfterThrottle, "refresh_token": "rotated-search", "expires_in": 3600])
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if index > 2 { return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: optionalStatus, httpVersion: nil, headerFields: ["Retry-After": "300"])!) }
            let token = index == 1 ? csa : messaging
            let body = try JSONSerialization.data(withJSONObject: ["access_token": token, "refresh_token": "rotated-\(index)", "expires_in": 3600])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let data = try JSONEncoder().encode(TeamsWebChatPage(items: []))
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor struct TeamsRenewalCoordinatorTests {
    private let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private func jwt(_ audience: String, expiry: Double, suffix: String) throws -> String {
        let claims: [String: Any] = ["aud": audience, "oid": account, "tid": tenant, "exp": expiry]
        let data = try JSONSerialization.data(withJSONObject: claims)
        return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + "." + suffix
    }
    @Test func savesBothCoreTokensWhenOptionalSearchIsThrottled() async throws {
        let past = Date().addingTimeInterval(-30).timeIntervalSince1970
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        let oldCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: past, suffix: "old-csa")
        let oldChat = try jwt("https://ic3.teams.office.com", expiry: past, suffix: "old-chat")
        let newCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: future, suffix: "new-csa")
        let newChat = try jwt("https://ic3.teams.office.com", expiry: future, suffix: "new-chat")
        let handoff = try JSONSerialization.data(withJSONObject: ["csaBaseURL": "https://teams.cloud.microsoft/api/csa/amer", "accessToken": oldCSA, "expiresAt": past,
            "messaging": ["baseURL": "https://teams.cloud.microsoft/api/chatsvc/amer", "accessToken": oldChat, "expiresAt": past]])
        let initial = TeamsCredentials(handoff: handoff, refreshToken: "initial")
        let transport = RenewalTransport(csa: newCSA, messaging: newChat)
        let memory = MemoryCredentials(); memory.value = initial
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = TeamsReaderStore(cacheRoot: root, transport: transport)
        let connection = TeamsConnection(reader: reader, credentialStore: memory, transport: transport, initialCredentials: initial)
        await connection.renew()
        let saved = try #require(memory.value)
        let session = try TeamsSessionHandoff.decode(saved.handoff)
        #expect(session.accessToken == newCSA)
        #expect(session.messaging?.accessToken == newChat)
        #expect(saved.refreshToken == "rotated-2")
        #expect(reader.connected)
        #expect(await transport.tokenCalls == 3)
    }
    @Test func secondResourceFailureKeepsRotatedRefreshTokenWithoutPublishingPartialCore() async throws {
        let past = Date().addingTimeInterval(-30).timeIntervalSince1970
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        let oldCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: past, suffix: "old")
        let oldChat = try jwt("https://ic3.teams.office.com", expiry: past, suffix: "old")
        let newCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: future, suffix: "new")
        let handoff = try JSONSerialization.data(withJSONObject: ["csaBaseURL": "https://teams.cloud.microsoft/api/csa/amer", "accessToken": oldCSA, "expiresAt": past,
            "messaging": ["baseURL": "https://teams.cloud.microsoft/api/chatsvc/amer", "accessToken": oldChat, "expiresAt": past]])
        let initial = TeamsCredentials(handoff: handoff, refreshToken: "initial")
        let transport = RenewalTransport(csa: newCSA, messaging: "unused", secondStatus: 503)
        let memory = MemoryCredentials(); memory.value = initial
        let reader = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport)
        let connection = TeamsConnection(reader: reader, credentialStore: memory, transport: transport, initialCredentials: initial)
        await connection.renew()
        #expect(memory.value?.refreshToken == "rotated-1")
        #expect(memory.value?.handoff == handoff)
        #expect(!reader.connected)
        #expect(await transport.tokenCalls == 2)
    }

    @Test func signOutDuringRenewalDoesNotRestoreCredentials() async throws {
        let past = Date().addingTimeInterval(-30).timeIntervalSince1970
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        let oldCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: past, suffix: "old")
        let oldChat = try jwt("https://ic3.teams.office.com", expiry: past, suffix: "old")
        let newCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: future, suffix: "new")
        let newChat = try jwt("https://ic3.teams.office.com", expiry: future, suffix: "new")
        let handoff = try JSONSerialization.data(withJSONObject: ["csaBaseURL": "https://teams.cloud.microsoft/api/csa/amer", "accessToken": oldCSA, "expiresAt": past,
            "messaging": ["baseURL": "https://teams.cloud.microsoft/api/chatsvc/amer", "accessToken": oldChat, "expiresAt": past]])
        let initial = TeamsCredentials(handoff: handoff, refreshToken: "initial")
        let transport = RenewalTransport(csa: newCSA, messaging: newChat, holdSecond: true)
        let memory = MemoryCredentials(); memory.value = initial
        let suite = "TeamsRenewalTest." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport)
        let connection = TeamsConnection(reader: reader, credentialStore: memory, transport: transport, initialCredentials: initial,
                                         defaults: defaults, clearWebData: { done in done() })
        let task = Task { await connection.renew() }
        while await transport.tokenCalls < 2 { await Task.yield() }
        connection.disconnect()
        let savesAtSignOut = memory.saves.count
        await transport.releaseSecond()
        await task.value
        while connection.isClearingSignIn { await Task.yield() }
        #expect(memory.value == nil)
        #expect(memory.saves.count == savesAtSignOut)
        #expect(defaults.bool(forKey: "teamsSignedOut"))
        #expect(!reader.connected)
    }

    @Test func terminalRefreshFailureClearsCredentialAndStartsRecovery() async throws {
        let past = Date().addingTimeInterval(-30).timeIntervalSince1970
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        let oldCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: past, suffix: "old")
        let oldChat = try jwt("https://ic3.teams.office.com", expiry: past, suffix: "old")
        let newCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: future, suffix: "new")
        let handoff = try JSONSerialization.data(withJSONObject: ["csaBaseURL": "https://teams.cloud.microsoft/api/csa/amer", "accessToken": oldCSA, "expiresAt": past,
            "messaging": ["baseURL": "https://teams.cloud.microsoft/api/chatsvc/amer", "accessToken": oldChat, "expiresAt": past]])
        let initial = TeamsCredentials(handoff: handoff, refreshToken: "initial")
        let transport = RenewalTransport(csa: newCSA, messaging: "unused", secondStatus: 400, secondBody: #"{"error":"invalid_grant"}"#)
        let memory = MemoryCredentials(); memory.value = initial
        let reader = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport)
        var recoveryStarted = false
        let connection = TeamsConnection(reader: reader, credentialStore: memory, transport: transport,
                                         initialCredentials: initial, webRecovery: { recoveryStarted = true })
        await connection.renew()
        #expect(memory.value?.refreshToken == nil)
        #expect(memory.value?.handoff == handoff)
        #expect(recoveryStarted)
        #expect(!reader.connected)
    }

    @Test func optionalThrottleHonorsRetryAfterWithoutRefreshingHealthyCore() async throws {
        var clock = Date()
        let past = clock.addingTimeInterval(-30).timeIntervalSince1970
        let future = clock.addingTimeInterval(3600).timeIntervalSince1970
        let oldCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: past, suffix: "old")
        let oldChat = try jwt("https://ic3.teams.office.com", expiry: past, suffix: "old")
        let newCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: future, suffix: "new")
        let newChat = try jwt("https://ic3.teams.office.com", expiry: future, suffix: "new")
        let search = try jwt("https://outlook.office.com", expiry: future, suffix: "search")
        let handoff = try JSONSerialization.data(withJSONObject: ["csaBaseURL": "https://teams.cloud.microsoft/api/csa/amer", "accessToken": oldCSA, "expiresAt": past,
            "messaging": ["baseURL": "https://teams.cloud.microsoft/api/chatsvc/amer", "accessToken": oldChat, "expiresAt": past]])
        let initial = TeamsCredentials(handoff: handoff, refreshToken: "initial")
        let transport = RenewalTransport(csa: newCSA, messaging: newChat, searchAfterThrottle: search)
        let memory = MemoryCredentials(); memory.value = initial
        let reader = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport)
        let connection = TeamsConnection(reader: reader, credentialStore: memory, transport: transport, initialCredentials: initial, now: { clock })
        await connection.renew()
        #expect(await transport.tokenCalls == 3)
        await connection.renew()
        #expect(await transport.tokenCalls == 3)
        clock = clock.addingTimeInterval(301)
        await connection.renew()
        #expect(await transport.tokenCalls == 4)
        #expect(try TeamsSessionHandoff.decode(#require(memory.value).handoff).searchSession?.accessToken == search)
    }

    @Test func concurrentRenewalsAreSingleFlight() async throws {
        let past = Date().addingTimeInterval(-30).timeIntervalSince1970
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        let oldCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: past, suffix: "old")
        let oldChat = try jwt("https://ic3.teams.office.com", expiry: past, suffix: "old")
        let newCSA = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: future, suffix: "new")
        let newChat = try jwt("https://ic3.teams.office.com", expiry: future, suffix: "new")
        let handoff = try JSONSerialization.data(withJSONObject: ["csaBaseURL": "https://teams.cloud.microsoft/api/csa/amer", "accessToken": oldCSA, "expiresAt": past,
            "messaging": ["baseURL": "https://teams.cloud.microsoft/api/chatsvc/amer", "accessToken": oldChat, "expiresAt": past]])
        let initial = TeamsCredentials(handoff: handoff, refreshToken: "initial")
        let transport = RenewalTransport(csa: newCSA, messaging: newChat, holdSecond: true)
        let memory = MemoryCredentials(); memory.value = initial
        let reader = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport)
        let connection = TeamsConnection(reader: reader, credentialStore: memory, transport: transport, initialCredentials: initial)
        let first = Task { await connection.renew() }
        while await transport.tokenCalls < 2 { await Task.yield() }
        await connection.renew()
        #expect(await transport.tokenCalls == 2)
        await transport.releaseSecond()
        await first.value
        #expect(await transport.tokenCalls == 3)
    }

}

@MainActor private final class DelayedCredentials: TeamsCredentialAccess {
    var value: TeamsCredentials?
    var holdLoad = false
    var holdSave = false
    var loadStarted = false
    var saveStarted = false
    var revision = 0
    var loadContinuation: CheckedContinuation<Void, Never>?
    var saveContinuation: CheckedContinuation<Void, Never>?
    func load(interactive: Bool) async throws -> TeamsCredentials? {
        let snapshot = value
        if holdLoad { loadStarted = true; await withCheckedContinuation { loadContinuation = $0 } }
        return snapshot
    }
    func save(_ credentials: TeamsCredentials) async throws {
        let expected = revision
        if holdSave { saveStarted = true; await withCheckedContinuation { saveContinuation = $0 } }
        guard revision == expected else { throw CancellationError() }
        value = credentials
    }
    func delete() async throws { revision += 1; value = nil }
}

@MainActor struct TeamsAsyncCredentialRaceTests {
    private let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private func jwt(_ audience: String, expiry: Double) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["aud": audience, "oid": account, "tid": tenant, "exp": expiry])
        return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".test"
    }
    private func credentials(expiry: Double) throws -> TeamsCredentials {
        let handoff = try JSONSerialization.data(withJSONObject: ["csaBaseURL": "https://teams.cloud.microsoft/api/csa/amer", "accessToken": jwt("https://chatsvcagg.teams.microsoft.com", expiry: expiry), "expiresAt": expiry,
            "messaging": ["baseURL": "https://teams.cloud.microsoft/api/chatsvc/amer", "accessToken": jwt("https://ic3.teams.office.com", expiry: expiry), "expiresAt": expiry]])
        return TeamsCredentials(handoff: handoff, refreshToken: "test")
    }
    @Test func delayedLoadAfterSignOutDoesNotReconnect() async throws {
        let store = DelayedCredentials(); store.value = try credentials(expiry: Date().addingTimeInterval(3600).timeIntervalSince1970); store.holdLoad = true
        let suite = "TeamsAsyncLoad." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let transport = RenewalTransport(csa: "", messaging: "")
        let reader = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport)
        let connection = TeamsConnection(reader: reader, credentialStore: store, transport: transport, defaults: defaults, clearWebData: { $0() })
        let task = Task { await connection.start() }
        while !store.loadStarted { await Task.yield() }
        connection.disconnect()
        while connection.isClearingSignIn { await Task.yield() }
        store.loadContinuation?.resume(); store.loadContinuation = nil
        await task.value
        #expect(!reader.connected)
        #expect(store.value == nil)
        #expect(defaults.bool(forKey: "teamsSignedOut"))
    }
    @Test func delayedSaveAfterSignOutCannotRestoreRevokedSession() async throws {
        let past = Date().addingTimeInterval(-30).timeIntervalSince1970
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        let initial = try credentials(expiry: past)
        let transport = RenewalTransport(csa: try jwt("https://chatsvcagg.teams.microsoft.com", expiry: future), messaging: try jwt("https://ic3.teams.office.com", expiry: future))
        let store = DelayedCredentials(); store.value = initial; store.holdSave = true
        let suite = "TeamsAsyncSave." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let reader = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport)
        let connection = TeamsConnection(reader: reader, credentialStore: store, transport: transport, initialCredentials: initial,
                                         defaults: defaults, clearWebData: { $0() })
        let task = Task { await connection.renew() }
        while !store.saveStarted { await Task.yield() }
        connection.disconnect()
        while connection.isClearingSignIn { await Task.yield() }
        store.saveContinuation?.resume(); store.saveContinuation = nil
        await task.value
        #expect(store.value == nil)
        #expect(!reader.connected)
        #expect(defaults.bool(forKey: "teamsSignedOut"))
    }
}

private actor FileAuthorizationTransport: HTTPTransport {
    var calls = 0
    var status = 200
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    var body = #"{"access_token":"opaque-file-token","refresh_token":"rotated-file","expires_in":3600,"scope":"files"}"#
    var lastScope: String?
    var attachmentMessage: TeamsWebMessage?
    var contextPaging = false
    var contextPagePending: CheckedContinuation<Void, Never>?
    func setAttachmentMessage(_ message: TeamsWebMessage) { attachmentMessage = message }
    func enableContextPaging() { contextPaging = true }
    func contextPageWaiting() -> Bool { contextPagePending != nil }
    func releaseContextPage() { contextPagePending?.resume(); contextPagePending = nil }
    func configure(status: Int = 200, hold: Bool = false, body: String? = nil) { self.status = status; self.hold = hold; if let body { self.body = body } }
    func waiting() -> Bool { pending != nil }
    func release() { pending?.resume(); pending = nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == "login.microsoftonline.com" {
            calls += 1
            let query = URLComponents(string: "?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)
            lastScope = query?.queryItems?.first(where: { $0.name == "scope" })?.value
            let code = status, response = body
            if hold { hold = false; await withCheckedContinuation { pending = $0 } }
            return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Retry-After":"120"])!)
        }
        if contextPaging, request.url?.path.hasSuffix("/epochTimeStamp/90") == true {
            await withCheckedContinuation { contextPagePending = $0 }
            return (Data(#"{"messages":[{"id":"90","content":"late page"}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if contextPaging, request.url?.path.hasSuffix("/epochTimeStamp/100") == true, let attachmentMessage {
            let encoded = try JSONEncoder().encode(attachmentMessage)
            let message = try JSONSerialization.jsonObject(with: encoded)
            let data = try JSONSerialization.data(withJSONObject: ["messages": [message], "_metadata": ["backwardLink": "https://example.invalid/epochTimeStamp/90"]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if (request.url?.path.hasSuffix("/messages") == true || request.url?.path.contains("/epochTimeStamp/") == true), let attachmentMessage {
            return (try JSONEncoder().encode(TeamsWebMessagePage(messages: [attachmentMessage])), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return (Data(#"{"items":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension TeamsRenewalCoordinatorTests {
    @MainActor private func fileSetup(_ transport: FileAuthorizationTransport, now: @escaping @MainActor () -> Date = Date.init) async throws -> (TeamsConnection, MemoryCredentials, TeamsReaderStore, TeamsSharePointResource) {
        let expiry = Date().addingTimeInterval(3600).timeIntervalSince1970
        let csa = try jwt("https://chatsvcagg.teams.microsoft.com", expiry: expiry, suffix: "csa")
        let chat = try jwt("https://ic3.teams.office.com", expiry: expiry, suffix: "chat")
        let handoff = try JSONSerialization.data(withJSONObject: ["csaBaseURL":"https://teams.cloud.microsoft/api/csa/amer", "accessToken":csa, "expiresAt":expiry, "messaging":["baseURL":"https://teams.cloud.microsoft/api/chatsvc/amer", "accessToken":chat, "expiresAt":expiry]])
        let saved = TeamsCredentials(handoff: handoff, refreshToken: "initial"), memory = MemoryCredentials()
        memory.value = saved
        let reader = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport)
        await reader.connect(session: try TeamsSessionHandoff.decode(handoff))
        let connection = TeamsConnection(reader: reader, credentialStore: memory, transport: transport, initialCredentials: saved, now: now)
        let resource = try #require(TeamsSharePointResource(baseURL: URL(string:"https://example.sharepoint.com/sites/team")!, objectURL: URL(string:"https://example.sharepoint.com/sites/team/file")!))
        return (connection, memory, reader, resource)
    }
    @Test func fileAcquisitionCoalescesAndPersistsRotationAfterViewerCancellation() async throws {
        let transport = FileAuthorizationTransport(); await transport.configure(hold: true)
        let (connection, memory, reader, resource) = try await fileSetup(transport)
        let first = Task { try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision) }
        while !(await transport.waiting()) { await Task.yield() }
        let second = Task { try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision) }
        for _ in 0..<50 { await Task.yield() }
        await connection.renew()
        #expect(await transport.calls == 1)
        first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled viewer received credential") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation result") }
        #expect(await transport.waiting())
        await transport.release()
        let result = try await second.value
        #expect(result.token == "opaque-file-token" && result.scope == "files")
        #expect(memory.value?.refreshToken == "rotated-file" && memory.saves.count == 1)
        #expect(await transport.calls == 1)
        #expect(await transport.lastScope == "https://example.sharepoint.com/.default")
    }
    @Test func fileThrottleAndInteractionRemainOptional() async throws {
        let transport = FileAuthorizationTransport(); await transport.configure(status: 429)
        let (connection, memory, reader, resource) = try await fileSetup(transport)
        for _ in 0..<2 { do { _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision) } catch {} }
        #expect(await transport.calls == 1 && reader.connected && memory.value?.refreshToken == "initial")
        let other = try #require(TeamsSharePointResource(baseURL: URL(string:"https://other.sharepoint.com/sites/team")!, objectURL: URL(string:"https://other.sharepoint.com/sites/team/file")!))
        await transport.configure(status: 400, body: #"{"error":"interaction_required"}"#)
        do { _ = try await connection.fileCredential(for: other, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision); Issue.record("Expected interaction") } catch {}
        #expect(reader.connected && memory.value?.refreshToken == "initial")
        #expect(TeamsSharePointResource(baseURL: URL(string:"https://example.sharepoint.com/site")!, objectURL: URL(string:"https://evil.example/file")!) == nil)
    }
    @Test func fileAcquisitionCannotPublishAfterAccountChange() async throws {
        let transport = FileAuthorizationTransport(); await transport.configure(hold: true)
        let (connection, memory, reader, resource) = try await fileSetup(transport)
        let oldRevision = reader.accountRevision
        let task = Task { try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision) }
        while !(await transport.waiting()) { await Task.yield() }
        await reader.restoreAccount(accountID: "cccccccc-cccc-cccc-cccc-cccccccccccc", tenantID: tenant, displayName: "Other")
        await reader.restoreAccount(accountID: account, tenantID: tenant, displayName: "Original")
        await reader.connect(session: try TeamsSessionHandoff.decode(memory.value!.handoff))
        do { _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: oldRevision); Issue.record("Old attachment revision accepted") } catch {}
        await transport.release()
        do { _ = try await task.value; Issue.record("Old account returned a token") } catch {}
        #expect(memory.saves.isEmpty && memory.value?.refreshToken == "initial")
    }
    @Test func fileAcquisitionBlocksAfterUncertainRotationSave() async throws {
        let transport = FileAuthorizationTransport()
        let (connection, memory, reader, resource) = try await fileSetup(transport)
        memory.failUncertain = true
        do { _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision); Issue.record("Uncertain save published token") } catch {}
        #expect(connection.credentialWriteUncertain && reader.connected)
        do { _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision); Issue.record("Uncertain save allowed retry") } catch {}
        #expect(await transport.calls == 1)
    }
    @Test func malformedFileTokenStillPersistsRotation() async throws {
        let transport = FileAuthorizationTransport()
        await transport.configure(body: #"{"refresh_token":"rotated-file","expires_in":0}"#)
        let (connection, memory, reader, resource) = try await fileSetup(transport)
        do { _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision); Issue.record("Malformed access token was published") } catch {}
        #expect(memory.value?.refreshToken == "rotated-file" && memory.saves.count == 1 && reader.connected)
    }
    @Test func unexpectedRotationSaveFailureBlocksAnotherExchange() async throws {
        let transport = FileAuthorizationTransport()
        let (connection, memory, reader, resource) = try await fileSetup(transport)
        memory.failUnexpectedly = true
        for _ in 0..<2 { do { _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision) } catch {} }
        #expect(connection.credentialWriteUncertain && reader.connected)
        #expect(await transport.calls == 1)
    }
    @Test func fileThrottleIsIsolatedAcrossAccountEpochs() async throws {
        for held in [false, true] {
            let transport = FileAuthorizationTransport(); await transport.configure(status: 429, hold: held)
            let (connection, memory, reader, resource) = try await fileSetup(transport)
            let first = Task { try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision) }
            if held { while !(await transport.waiting()) { await Task.yield() } }
            else { _ = try? await first.value }
            await reader.restoreAccount(accountID: "cccccccc-cccc-cccc-cccc-cccccccccccc", tenantID: tenant, displayName: "Other")
            await reader.restoreAccount(accountID: account, tenantID: tenant, displayName: "Original")
            await reader.connect(session: try TeamsSessionHandoff.decode(memory.value!.handoff))
            if held { await transport.release(); _ = try? await first.value }
            do { _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision) } catch {}
            #expect(await transport.calls == 2)
        }
    }
    @Test func fileTokenExpiryCountsSaveLatency() async throws {
        let transport = FileAuthorizationTransport()
        var clock = Date()
        let (connection, memory, reader, resource) = try await fileSetup(transport, now: { clock })
        memory.holdSave = true
        let request = Task { try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision) }
        while memory.pendingSave == nil { await Task.yield() }
        clock = clock.addingTimeInterval(4000)
        memory.pendingSave?.resume(); memory.pendingSave = nil
        do { _ = try await request.value; Issue.record("Expired token published") } catch {}
        #expect(memory.value?.refreshToken == "rotated-file")
    }
    @Test func fileSaveInteractionRequiresKeychainRecovery() async throws {
        let transport = FileAuthorizationTransport()
        let (connection, memory, reader, resource) = try await fileSetup(transport)
        memory.failInteraction = true
        for _ in 0..<2 { do { _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision) } catch {} }
        #expect(connection.keychainNeedsApproval && reader.connected)
        #expect(await transport.calls == 1)
        memory.failInteraction = false
        await connection.unlockSavedSignIn()
        #expect(!connection.keychainNeedsApproval && memory.value?.refreshToken == "rotated-file")
    }
    @Test func uncertainUnlockSaveCanBeReconciled() async throws {
        let transport = FileAuthorizationTransport()
        let (connection, memory, reader, resource) = try await fileSetup(transport)
        memory.failInteraction = true
        do { _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision) } catch {}
        memory.failInteraction = false; memory.failUncertain = true
        await connection.unlockSavedSignIn()
        #expect(connection.credentialWriteUncertain && connection.keychainNeedsApproval)
        #expect(await transport.calls == 1)
        memory.failUncertain = false
        await connection.reconcileSavedSignIn()
        #expect(!connection.credentialWriteUncertain && !connection.keychainNeedsApproval)
        _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision)
        #expect(await transport.calls == 2)
    }
    @Test func removedAttachmentCannotAcquireAFileToken() async throws {
        let transport = FileAuthorizationTransport()
        let files = #"[{"version":2,"id":"file-id","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://example.sharepoint.com/sites/team/file.pdf"}]"#
        await transport.setAttachmentMessage(TeamsWebMessage(id: "message", version: "1", properties: .object(["files": .string(files)])))
        let (connection, _, reader, _) = try await fileSetup(transport)
        await reader.loadConversation("chat")
        let attachment = try #require(reader.messages(in: "chat").first?.files.first?.sharePoint)
        await transport.setAttachmentMessage(TeamsWebMessage(id: "message", version: "2", properties: .object([:])))
        await reader.refreshConversation("chat")
        do { _ = try await connection.fileCredential(for: attachment, accountID: account, tenantID: tenant); Issue.record("Removed attachment accepted") } catch {}
        #expect(await transport.calls == 0)
    }
}

private actor FileContentTransport: TeamsMediaFetching {
    var calls = 0
    var status = 429
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    var payload: Data?
    var mime = "image/png"
    func configure(status: Int, hold: Bool = false, data: Data? = nil, mime: String? = nil) { self.status = status; self.hold = hold; self.payload = data; if let mime { self.mime = mime } }
    func waiting() -> Bool { pending != nil }
    func release() { pending?.resume(); pending = nil }
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        if hold { hold = false; await withCheckedContinuation { pending = $0 } }
        let data = payload ?? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII=")!
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":mime, "Retry-After":"120"])!)
    }
}

extension TeamsRenewalCoordinatorTests {
    @Test func fileContentThrottleAndStaleCompletionStayOptional() async throws {
        let tokenTransport = FileAuthorizationTransport()
        let files = #"[{"version":2,"id":"file-id","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://example.sharepoint.com/sites/team/file.png"}]"#
        await tokenTransport.setAttachmentMessage(TeamsWebMessage(id: "message", version: "1", properties: .object(["files": .string(files)])))
        let (connection, memory, reader, _) = try await fileSetup(tokenTransport)
        await reader.loadConversation("chat")
        let attachment = try #require(reader.messages(in: "chat").first?.files.first?.sharePoint)
        let content = FileContentTransport(), client = TeamsSharePointContentClient(transport: content)
        for _ in 0..<2 { do { _ = try await connection.filePreview(for: attachment, client: client) } catch {} }
        #expect(await content.calls == 1)
        #expect(reader.connected && memory.value?.refreshToken == "rotated-file")
        let secondContent = FileContentTransport(); await secondContent.configure(status: 200, hold: true)
        let secondClient = TeamsSharePointContentClient(transport: secondContent)
        await reader.restoreAccount(accountID: account, tenantID: tenant, displayName: "Original")
        await reader.connect(session: try TeamsSessionHandoff.decode(memory.value!.handoff))
        await reader.loadConversation("chat")
        let fresh = try #require(reader.messages(in: "chat").first?.files.first?.sharePoint)
        let task = Task { try await connection.filePreview(for: fresh, client: secondClient) }
        while !(await secondContent.waiting()) { await Task.yield() }
        await reader.restoreAccount(accountID: "cccccccc-cccc-cccc-cccc-cccccccccccc", tenantID: tenant, displayName: "Other")
        await secondContent.release()
        do { _ = try await task.value; Issue.record("Stale image published") } catch {}
    }
}

@MainActor private final class FilePreviewGate {
    var calls = 0
    var pending: CheckedContinuation<Void, Never>?
    func pauseFirst() async {
        calls += 1
        if calls == 1 { await withCheckedContinuation { pending = $0 } }
    }
    func release() { pending?.resume(); pending = nil }
}

extension TeamsRenewalCoordinatorTests {
    @Test func filePreviewRechecksCooldownAfterCredentialWait() async throws {
        let tokenTransport = FileAuthorizationTransport()
        let files = #"[{"version":2,"id":"file-id","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://example.sharepoint.com/sites/team/file.png"}]"#
        await tokenTransport.setAttachmentMessage(TeamsWebMessage(id: "message", version: "1", properties: .object(["files": .string(files)])))
        let (connection, _, reader, _) = try await fileSetup(tokenTransport)
        await reader.loadConversation("chat")
        let attachment = try #require(reader.messages(in: "chat").first?.files.first?.sharePoint)
        let content = FileContentTransport(), client = TeamsSharePointContentClient(transport: content), gate = FilePreviewGate()
        connection.filePreviewAfterCredential = { await gate.pauseFirst() }
        let first = Task { try await connection.filePreview(for: attachment, client: client) }
        while gate.pending == nil { await Task.yield() }
        do { _ = try await connection.filePreview(for: attachment, client: client) } catch {}
        gate.release(); _ = try? await first.value
        #expect(await content.calls == 1)
    }
    @Test func lateFileUnauthorizedDoesNotEvictNewCredential() async throws {
        let tokenTransport = FileAuthorizationTransport()
        let files = #"[{"version":2,"id":"file-id","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://example.sharepoint.com/sites/team/file.png"}]"#
        await tokenTransport.setAttachmentMessage(TeamsWebMessage(id: "message", version: "1", properties: .object(["files": .string(files)])))
        var clock = Date()
        let (connection, _, reader, resource) = try await fileSetup(tokenTransport, now: { clock })
        await reader.loadConversation("chat")
        let attachment = try #require(reader.messages(in: "chat").first?.files.first?.sharePoint)
        let content = FileContentTransport(); await content.configure(status: 401, hold: true)
        let task = Task { try await connection.filePreview(for: attachment, client: TeamsSharePointContentClient(transport: content)) }
        while !(await content.waiting()) { await Task.yield() }
        clock = clock.addingTimeInterval(3550)
        _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision)
        await content.release(); _ = try? await task.value
        _ = try await connection.fileCredential(for: resource, accountID: account, tenantID: tenant, expectedAccountRevision: reader.accountRevision)
        #expect(await tokenTransport.calls == 2)
    }
}

extension TeamsRenewalCoordinatorTests {
    @Test func pdfPreviewDiscardsCompletionAfterAccountChange() async throws {
        let tokenTransport = FileAuthorizationTransport()
        let files = #"[{"version":2,"id":"file-id","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://example.sharepoint.com/sites/team/file.pdf"}]"#
        await tokenTransport.setAttachmentMessage(TeamsWebMessage(id: "message", version: "1", properties: .object(["files": .string(files)])))
        let (connection, _, reader, _) = try await fileSetup(tokenTransport)
        await reader.loadConversation("chat")
        let attachment = try #require(reader.messages(in: "chat").first?.files.first?.sharePoint)
        let bytes = NSMutableData(), consumer = try #require(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let content = FileContentTransport(); await content.configure(status: 200, hold: true, data: bytes as Data, mime: "application/pdf")
        let task = Task { try await connection.filePreview(for: attachment, client: TeamsSharePointContentClient(transport: content)) }
        while !(await content.waiting()) { await Task.yield() }
        await reader.restoreAccount(accountID: "cccccccc-cccc-cccc-cccc-cccccccccccc", tenantID: tenant, displayName: "Other")
        await content.release()
        do { _ = try await task.value; Issue.record("Old-account PDF published") } catch {}
    }
}

extension TeamsRenewalCoordinatorTests {
    @Test func contextAttachmentsRequireTheExactActiveContext() async throws {
        let transport = FileAuthorizationTransport()
        let files = #"[{"version":2,"id":"file-id","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://example.sharepoint.com/sites/team/file.png"}]"#
        let message = TeamsWebMessage(id: "100", version: "1", properties: .object(["files": .string(files)]))
        await transport.setAttachmentMessage(message)
        let (_, _, reader, _) = try await fileSetup(transport)
        await reader.loadConversation("chat")
        let main = try #require(reader.messages(in: "chat").first?.files.first?.sharePoint)
        await reader.openMessageContext(in: "chat", targetID: "100")
        let context = try #require(reader.contextMessages.first?.files.first?.sharePoint)
        #expect(context.contextRevision != nil && main.contextRevision == nil)
        #expect(reader.ownsSharePointAttachment(main) && reader.ownsSharePointAttachment(context))
        reader.closeMessageContext()
        #expect(reader.ownsSharePointAttachment(main) && !reader.ownsSharePointAttachment(context))
        await reader.openMessageContext(in: "chat", targetID: "100")
        let replacement = try #require(reader.contextMessages.first?.files.first?.sharePoint)
        #expect(reader.ownsSharePointAttachment(replacement) && !reader.ownsSharePointAttachment(context))
        await transport.setAttachmentMessage(TeamsWebMessage(id: "101", version: "1", properties: .object(["files": .string(files)])))
        await reader.openMessageContext(in: "chat", targetID: "101")
        await transport.setAttachmentMessage(message)
        await reader.openMessageContext(in: "chat", targetID: "100")
        #expect(!reader.ownsSharePointAttachment(replacement))
        let latest = try #require(reader.contextMessages.first?.files.first?.sharePoint)
        #expect(reader.ownsSharePointAttachment(latest))
        await reader.restoreAccount(accountID: "cccccccc-cccc-cccc-cccc-cccccccccccc", tenantID: tenant, displayName: "Other")
        #expect(!reader.ownsSharePointAttachment(latest))
    }
    @Test func heldContextPreviewsAreDiscardedOnCloseTargetOrAccountChange() async throws {
        for (index, transition) in ["close", "target", "account"].enumerated() {
            let transport = FileAuthorizationTransport()
            let isPDF = index == 1
            let filename = isPDF ? "file.pdf" : "file.png"
            let files = "[{\"version\":2,\"id\":\"file-id\",\"baseUrl\":\"https://example.sharepoint.com/sites/team\",\"objectUrl\":\"https://example.sharepoint.com/sites/team/\(filename)\"}]"
            await transport.setAttachmentMessage(TeamsWebMessage(id: "100", version: "1", properties: .object(["files": .string(files)])))
            let (connection, _, reader, _) = try await fileSetup(transport)
            await reader.openMessageContext(in: "chat", targetID: "100")
            let attachment = try #require(reader.contextMessages.first?.files.first?.sharePoint)
            let content = FileContentTransport()
            if isPDF {
                let bytes = NSMutableData(), consumer = try #require(CGDataConsumer(data: bytes))
                var box = CGRect(x: 0, y: 0, width: 612, height: 792)
                let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
                context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
                await content.configure(status: 200, hold: true, data: bytes as Data, mime: "application/pdf")
            } else { await content.configure(status: 200, hold: true) }
            let task = Task { try await connection.filePreview(for: attachment, client: TeamsSharePointContentClient(transport: content)) }
            while !(await content.waiting()) { await Task.yield() }
            if transition == "close" { reader.closeMessageContext() }
            else if transition == "target" {
                await transport.setAttachmentMessage(TeamsWebMessage(id: "101", version: "1", properties: .object(["files": .string(files)])))
                await reader.openMessageContext(in: "chat", targetID: "101")
            } else { await reader.restoreAccount(accountID: "cccccccc-cccc-cccc-cccc-cccccccccccc", tenantID: tenant, displayName: "Other") }
            await content.release()
            do { _ = try await task.value; Issue.record("Obsolete context preview published") } catch {}
            #expect(!reader.ownsSharePointAttachment(attachment))
        }
    }
}

extension TeamsRenewalCoordinatorTests {
    @Test func contextAttachmentRebindsAfterRenewalInterruptsPaging() async throws {
        let transport = FileAuthorizationTransport()
        let files = #"[{"version":2,"id":"file-id","baseUrl":"https://example.sharepoint.com/sites/team","objectUrl":"https://example.sharepoint.com/sites/team/file.png"}]"#
        await transport.setAttachmentMessage(TeamsWebMessage(id: "100", version: "1", properties: .object(["files": .string(files)])))
        await transport.enableContextPaging()
        let (_, memory, reader, _) = try await fileSetup(transport)
        await reader.openMessageContext(in: "chat", targetID: "100")
        let old = try #require(reader.contextMessages.first?.files.first?.sharePoint)
        let page = Task { await reader.loadContextPage(.backward) }
        while !(await transport.contextPageWaiting()) { await Task.yield() }
        await reader.connect(session: try TeamsSessionHandoff.decode(memory.value!.handoff))
        let rebound = try #require(reader.contextMessages.first?.files.first?.sharePoint)
        #expect(old.contextRevision != rebound.contextRevision)
        #expect(!reader.ownsSharePointAttachment(old) && reader.ownsSharePointAttachment(rebound))
        await transport.releaseContextPage(); await page.value
        #expect(reader.contextMessages.map(\.id) == ["100"])
        #expect(reader.ownsSharePointAttachment(rebound))
    }
}
