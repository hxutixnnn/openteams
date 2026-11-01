import Foundation
import Testing
@testable import TeamsCore

private actor LifecycleTransport: HTTPTransport {
    var directoryStatus = 200
    var creationStatus = 201
    var unknown = false
    var searches = 0
    var creations = 0
    var messageReads = 0
    var metadataReads = 0
    var metadata = Data(#"{"id":"19:created@thread.v2"}"#.utf8)
    func setMetadata(_ json: String) { metadata = Data(json.utf8) }
    var holdCreation = false
    var failReadsAfterCreation = false
    var failedReadStatus = 503
    var continuation: CheckedContinuation<Void, Never>?
    func hold() { holdCreation = true }
    func release() { continuation?.resume(); continuation = nil }
    func failRefresh(status: Int = 503) { failReadsAfterCreation = true; failedReadStatus = status }
    func configure(directory: Int? = nil, creation: Int? = nil, unknown: Bool? = nil) {
        if let directory { directoryStatus = directory }
        if let creation { creationStatus = creation }
        if let unknown { self.unknown = unknown }
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        var status = 200
        var headers: [String: String] = [:]
        var body = Data("{}".utf8)
        if path.hasSuffix("/searchV2") { searches += 1; status = directoryStatus }
        else if request.httpMethod == "POST" && path.hasSuffix("/v1/threads") {
            creations += 1
            if holdCreation { await withCheckedContinuation { continuation = $0 } }
            if unknown { throw URLError(.networkConnectionLost) }
            status = creationStatus
            headers["Location"] = "https://teams.cloud.microsoft/v1/threads/19%3Acreated%40thread.v2"
        } else if path.contains("/teams/users/me/chats/") {
            metadataReads += 1; body = metadata
            if failReadsAfterCreation && creations > 0 { status = failedReadStatus }
        } else {
            if path.hasSuffix("/messages") { messageReads += 1 }
            if failReadsAfterCreation && creations > 0 { status = failedReadStatus }
            body = try JSONEncoder().encode(TeamsWebChatPage(items: []))
        }
        if status == 429 { headers["Retry-After"] = "120" }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

@MainActor struct TeamsNewChatLifecycleTests {
    func session(_ account: String, directoryExpiry: Date = .distantFuture) -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "csa", expiresAt: .distantFuture,
              accountID: account, tenantID: "tenant", displayName: "Fixture",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "chat", expiresAt: .distantFuture),
              directory: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/mt/amer")!, accessToken: "directory", expiresAt: directoryExpiry))
    }
    var person: TeamsDirectoryPerson { .init(mri: "8:orgid:other", displayName: "Other") }
    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func throttlesAreResourceScopedAndPreventSecondRequest() async throws {
        let transport = LifecycleTransport(), store = TeamsReaderStore(cacheRoot: root(), transport: transport)
        await store.connect(session: session(UUID().uuidString))
        await transport.configure(directory: 429, creation: 429)
        for _ in 0..<2 { do { _ = try await store.findPeople("Ada") } catch {} }
        #expect(await transport.searches == 1)
        #expect(store.directoryRetryNotBefore != nil && store.retryNotBefore == nil)
        for _ in 0..<2 { do { _ = try await store.createChat(with: [person], title: nil) } catch {} }
        #expect(await transport.creations == 1)
        #expect(!store.creationNeedsReview && store.retryNotBefore != nil)
    }

    @Test func staleAccountCannotDispatchAndAuthFailuresSignalRecovery() async throws {
        let transport = LifecycleTransport(), store = TeamsReaderStore(cacheRoot: root(), transport: transport)
        await store.connect(session: session(UUID().uuidString))
        let oldAccount = store.accountScope, oldRevision = store.accountRevision
        await store.connect(session: session(UUID().uuidString))
        do { _ = try await store.createChat(with: [person], title: "old", expectedAccount: oldAccount, expectedRevision: oldRevision); Issue.record("Stale account dispatched") } catch {}
        #expect(await transport.creations == 0)
        await transport.configure(directory: 401)
        do { _ = try await store.findPeople("Ada") } catch {}
        #expect(await transport.searches == 1 && store.sessionExpired && !store.connected)
        await store.connect(session: session(UUID().uuidString))
        await transport.configure(creation: 401)
        do { _ = try await store.createChat(with: [person], title: nil) } catch {}
        #expect(await transport.creations == 1 && store.sessionExpired && !store.creationNeedsReview)
        await store.connect(session: session(UUID().uuidString, directoryExpiry: .distantPast))
        do { _ = try await store.findPeople("Ada") } catch {}
        #expect(await transport.searches == 1 && store.sessionExpired)
    }

    @Test func partialKnownIDSurvivesRestartAndUnknownDoesNotReplay() async throws {
        let transport = LifecycleTransport(), cache = root(), account = UUID().uuidString
        let store = TeamsReaderStore(cacheRoot: cache, transport: transport)
        await store.connect(session: session(account)); await transport.configure(creation: 207); await transport.failRefresh()
        let result = try await store.createChat(with: [person], title: "Project")
        #expect(result.status == 207 && store.creationReview?.threadID == result.threadID)
        let reopened = TeamsReaderStore(cacheRoot: cache, transport: transport)
        await reopened.restoreAccount(accountID: account, tenantID: "tenant", displayName: "Fixture")
        #expect(reopened.creationReview?.state == .known && reopened.creationReview?.status == 207)
        reopened.ensureKnownCreationVisible()
        #expect(reopened.conversation(result.threadID) != nil)
        await reopened.connect(session: session(account))
        do { try await reopened.refreshKnownCreation(result.threadID, expectedAccount: reopened.accountScope, expectedRevision: reopened.accountRevision); Issue.record("Expected refresh failure") } catch {}
        #expect(await transport.metadataReads == 1 && reopened.creationReview?.threadID == result.threadID)
        #expect(await transport.creations == 1)
        _ = await reopened.acknowledgeChatCreationReview(expectedID: reopened.creationReview?.operationID)
        await transport.configure(unknown: true)
        do { _ = try await reopened.createChat(with: [person], title: nil) } catch {}
        #expect(reopened.creationReview?.state == .unknown)
        do { _ = try await reopened.createChat(with: [person], title: nil) } catch {}
        #expect(await transport.creations == 2)
        _ = await reopened.acknowledgeChatCreationReview(expectedID: reopened.creationReview?.operationID)
    }
    @Test func delayedKnownResultStaysWithOriginalAccount() async throws {
        let transport = LifecycleTransport(), cache = root(), accountA = UUID().uuidString, accountB = UUID().uuidString
        let store = TeamsReaderStore(cacheRoot: cache, transport: transport)
        await store.connect(session: session(accountA)); await transport.hold()
        let scope = store.accountScope, revision = store.accountRevision
        let task = Task { try await store.createChat(with: [person], title: "A title", expectedAccount: scope, expectedRevision: revision) }
        while await transport.creations == 0 { await Task.yield() }
        await store.connect(session: session(accountB))
        await transport.release()
        do { _ = try await task.value } catch {}
        #expect(store.accountScope != scope && store.creationReview == nil)
        await store.restoreAccount(accountID: accountA, tenantID: "tenant", displayName: "A")
        #expect(store.creationReview?.state == .known && store.creationReview?.title == "A title")
        #expect(await transport.creations == 1)
        _ = await store.acknowledgeChatCreationReview(expectedID: store.creationReview?.operationID)
    }

    @Test func twoReadersCannotAcknowledgeOrReplaceLiveCreation() async throws {
        let transport = LifecycleTransport(), cache = root(), account = UUID().uuidString
        let first = TeamsReaderStore(cacheRoot: cache, transport: transport)
        let second = TeamsReaderStore(cacheRoot: cache, transport: transport)
        await first.connect(session: session(account)); await transport.hold()
        let task = Task { try await first.createChat(with: [person], title: "first") }
        while await transport.creations == 0 { await Task.yield() }
        await second.connect(session: session(account))
        let id = second.creationReview?.operationID
        #expect(id != nil && second.creationReview?.state == .pending)
        #expect(!(await second.acknowledgeChatCreationReview(expectedID: id)))
        do { _ = try await second.createChat(with: [person], title: "replacement"); Issue.record("Second owner dispatched") } catch {}
        #expect(await transport.creations == 1)
        await transport.release()
        let result = try await task.value
        let restored = TeamsReaderStore(cacheRoot: cache, transport: transport)
        await restored.restoreAccount(accountID: account, tenantID: "tenant", displayName: "Fixture")
        #expect(restored.creationReview?.operationID == id && restored.creationReview?.threadID == result.threadID)
        #expect(await transport.creations == 1)
    }

    @Test func knownRefreshRejectsStaleAccountBeforeRead() async throws {
        let transport = LifecycleTransport(), store = TeamsReaderStore(cacheRoot: root(), transport: transport)
        await store.connect(session: session(UUID().uuidString))
        let scope = store.accountScope, revision = store.accountRevision
        await store.connect(session: session(UUID().uuidString))
        do { try await store.refreshKnownCreation("19:old", expectedAccount: scope, expectedRevision: revision); Issue.record("Stale read allowed") } catch {}
        #expect(await transport.metadataReads == 0)
    }

    @Test func knownChatDecodesDirectMetadataWithoutInventingRoster() async throws {
        let transport = LifecycleTransport(), client = TeamsWebClient(session: session(UUID().uuidString), transport: transport)
        let id = "19:created@thread.v2"
        let absent = try await client.knownChat(id)
        #expect(absent.members == nil)
        await transport.setMetadata(#"{"id":"19:created@thread.v2","title":"Project","members":[{"mri":"8:orgid:ada","friendlyName":"Ada","role":"Admin"}]}"#)
        let basic = try await client.knownChat(id)
        #expect(basic.title == "Project" && basic.members?.first?.preferredDisplayName == "Ada" && basic.members?.first?.displayName == nil && basic.members?.first?.friendlyName == "Ada" && basic.members?.first?.objectId == nil)
        await transport.setMetadata(#"{"id":"19:created@thread.v2","members":[{"mri":"8:orgid:ada","displayName":"Richer","objectId":"object","userIdentityType":"person"}]}"#)
        let richer = try await client.knownChat(id)
        #expect(richer.members?.first?.displayName == "Richer" && richer.members?.first?.objectId == "object")
        await transport.setMetadata(#"{"id":"wrong"}"#)
        do { _ = try await client.knownChat(id); Issue.record("Wrong ID accepted") } catch {}
    }

    @Test func acceptedResultSurvivesSameAccountRenewalDuringPost() async throws {
        let transport = LifecycleTransport(), account = UUID().uuidString
        let store = TeamsReaderStore(cacheRoot: root(), transport: transport)
        await store.connect(session: session(account)); await transport.hold()
        let task = Task { try await store.createChat(with: [person], title: "Renewal") }
        while await transport.creations == 0 { await Task.yield() }
        await store.connect(session: session(account))
        await transport.release()
        let result = try await task.value
        #expect(result.status == 201 && store.creationReview?.threadID == result.threadID)
        #expect(!store.creationNeedsReview && store.conversation(result.threadID) != nil)
        #expect(await transport.creations == 1)
    }

    @Test func acceptedResultDoesNotDependOnAnOptionalListRefresh() async throws {
        let transport = LifecycleTransport(), store = TeamsReaderStore(cacheRoot: root(), transport: transport)
        await store.connect(session: session(UUID().uuidString)); await transport.failRefresh(status: 401)
        let result = try await store.createChat(with: [person], title: nil)
        #expect(result.status == 201 && store.creationReview?.threadID == result.threadID)
        #expect(store.connected && !store.creationNeedsReview)
        await store.refreshChats()
        #expect(store.sessionExpired && store.creationReview?.threadID == result.threadID)
        #expect(await transport.creations == 1)
    }

}
