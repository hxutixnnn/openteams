import Foundation
import Observation

public struct TeamsServerChatSnapshot: Equatable, Sendable {
    public let revision: UUID
    public let accountScope: String
    public let chats: [TeamsWebChat]
}

public enum TeamsChatPageLoadResult: Equatable, Sendable { case attempted, deferred }
public enum TeamsMessageEditError: Error { case storage }

@MainActor @Observable public final class TeamsMessageEditSession: Identifiable {
    public let id = UUID()
    public let chatID: String
    public let accountScope: String
    public let original: TeamsWebMessage
    public var document: TeamsRichDraft
    public var status: String?
    public var saving = false
    public var uncertain = false
    public var completed = false
    public var hasSavedDraft: Bool { journalID != nil && !completed }
    fileprivate var journalID: UUID?
    fileprivate init(chatID: String, accountScope: String, original: TeamsWebMessage, document: TeamsRichDraft) {
        self.chatID = chatID; self.accountScope = accountScope; self.original = original; self.document = document
    }
}

@MainActor @Observable
public final class TeamsReaderStore {
    public let composer: TeamsComposeStore
    public private(set) var chats: [TeamsWebChat] = []
    public private(set) var serverChatSnapshot: TeamsServerChatSnapshot?
    @ObservationIgnored public var onServerChatSnapshot: (@MainActor (TeamsServerChatSnapshot) -> Void)?
    public private(set) var conversationFolders: TeamsConversationFolders?
    public private(set) var foldersWarning: String?
    public private(set) var renderedMessages: [String: [TeamsRenderedMessage]] = [:]
    public private(set) var loadingChatIDs: Set<String> = []
    public private(set) var isLoadingChats = false
    public private(set) var hasMoreChats = false
    public private(set) var chatListError: String?
    public private(set) var chatErrors: [String: String] = [:]
    public private(set) var pendingReadChatIDs: Set<String> = []
    public private(set) var finishableReadChatIDs: Set<String> = []
    public private(set) var readStatusMessages: [String: String] = [:]
    public private(set) var cacheWarning: String?
    public private(set) var lastRefreshedAt: Date?
    public private(set) var accountName = "Teams account"
    public private(set) var accountID = ""
    public private(set) var connected = false
    public private(set) var sessionExpired = false
    public private(set) var mediaRevision = UUID()
    public private(set) var mediaRefreshRevision = UUID()
    public private(set) var contextChatID: String?
    public private(set) var contextTargetID: String?
    public private(set) var contextMessages: [TeamsRenderedMessage] = []
    public private(set) var contextLoading = false
    public private(set) var contextError: String?
    public private(set) var contextActionError: String?
    public private(set) var contextBackwardToken: String?
    public private(set) var contextForwardToken: String?
    public private(set) var contextBackwardLoading = false
    public private(set) var contextForwardLoading = false
    public private(set) var contextBackwardError: String?
    public private(set) var contextForwardError: String?
    public private(set) var searchRetryNotBefore: Date?
    public var accountScope: String { tenantID + ":" + accountID }
    public private(set) var accountRevision = UUID()
    private var tenantID = ""
    private let cacheRoot: URL
    private let transport: any HTTPTransport
    private let mediaFactory: @Sendable (TeamsWebSession) throws -> TeamsMediaClient
    private var session: TeamsWebSession?
    private var mediaClient: TeamsMediaClient?
    private var cache: TeamsReadCache?
    private var histories: [String: TeamsCachedHistory] = [:]
    private var cachedLoadCounts: [String: Int] = [:]
    private let cachedMessageRenderer = TeamsCachedMessageRenderer()
    private struct RenderingInputs {
        let messages: [TeamsWebMessage]
        let messageIndices: [String: Int]
        let people: [String: Person]
        let accountScope: String
        let accountRevision: UUID
    }
    @ObservationIgnored private var renderingInputs: [String: RenderingInputs] = [:]
    private var groupPictureLookups: [String: UUID] = [:]
    private var groupPictureFreshness: [String: (version: String?, checkedAt: Date)] = [:]
    private var groupPictureListMetadata: Set<String> = []
    private var chatsCursor: String?
    private var generation = UUID()
    private var sessionRevision = UUID()
    private var creatingAccounts: Set<String> = []
    private var markingRead: [String: UUID] = [:]
    private struct ReactionTarget: Hashable { let chat: String; let message: String }
    private var reacting: Set<ReactionTarget> = []
    private var reactionsAwaitingRefresh: Set<ReactionTarget> = []
    private var deletionStages: [ReactionTarget: TeamsPendingDeletion.Stage] = [:]
    private var deletionStatusRevision: [ReactionTarget: UUID] = [:]
    private var deletionMessages: [ReactionTarget: String] = [:]
    private var acceptedDeletionMemory: Set<ReactionTarget> = []
    private var checkingDeletions: Set<ReactionTarget> = []
    #if DEBUG
    var deletionCheckAfterJournal: (@MainActor () async -> Void)?
    #endif
    public private(set) var retryNotBefore: Date?
    private var loadingFolders = false
    public private(set) var contextRevision = UUID()
    private var contextRawMessages: [TeamsWebMessage] = []
    private var contextSequences: [String: Int64] = [:]
    private var contextBackwardSeen: Set<String> = []
    private var contextForwardSeen: Set<String> = []

    public init(cacheRoot: URL, transport: any HTTPTransport = TeamsWebURLSessionTransport(),
                mediaFactory: @escaping @Sendable (TeamsWebSession) throws -> TeamsMediaClient = { try TeamsMediaClient(session: $0) }) {
        self.cacheRoot = cacheRoot
        self.transport = transport
        self.mediaFactory = mediaFactory
        composer = TeamsComposeStore(root: cacheRoot.appendingPathComponent("Compose"), transport: transport)
    }

    public func restoreAccount(accountID: String, tenantID: String, displayName: String) async {
        guard !accountID.isEmpty, !tenantID.isEmpty else { return }
        resetAccount(accountID: accountID, tenantID: tenantID, displayName: displayName)
        let current = generation
        await restoreCreationReview(for: current)
        await restoreChats(for: current)
        guard current == generation else { return }
        await restoreFolders(for: current)
    }

    public func connect(session: TeamsWebSession) async {
        do { try session.validate() }
        catch { chatListError = error.localizedDescription; return }
        if accountID != session.accountID || tenantID != session.tenantID {
            resetAccount(accountID: session.accountID, tenantID: session.tenantID, displayName: session.displayName)
            let current = generation
            await restoreCreationReview(for: current)
            await restoreChats(for: current)
            guard current == generation else { return }
            await restoreFolders(for: current)
            guard current == generation else { return }
        }
        let current = generation
        if let existing = mediaClient {
            do { try await existing.update(session: session) }
            catch {
                await existing.invalidate()
                guard generation == current else { return }
                mediaClient = try? mediaFactory(session)
                mediaRevision = UUID()
            }
        } else {
            mediaClient = try? mediaFactory(session)
            mediaRevision = UUID()
        }
        guard generation == current else { return }
        mediaRefreshRevision = UUID()
        var contextNeedsRebind = false
        if contextLoading {
            contextRevision = UUID(); contextLoading = false
            contextNeedsRebind = true
            contextError = "Your session changed while loading context. Try again."
        }
        if contextBackwardLoading || contextForwardLoading {
            contextRevision = UUID()
            contextNeedsRebind = true
            if contextBackwardLoading { contextBackwardError = "Your session changed. Try loading earlier messages again." }
            if contextForwardLoading { contextForwardError = "Your session changed. Try loading later messages again." }
            contextBackwardLoading = false; contextForwardLoading = false
        }
        if contextNeedsRebind { renderCurrentContext() }
        sessionRevision = UUID()
        groupPictureLookups = [:]
        groupPictureFreshness = [:]
        markingRead = [:]
        self.session = session
        composer.connect(session)
        accountName = session.displayName
        connected = true
        sessionExpired = false
        if retryNotBefore == nil {
            chatListError = nil
            chatErrors = [:]
        }
        await refreshChats()
    }

    public func disconnect() {
        #if DEBUG
        cachedLoadGate?.invalidate(reason: "disconnected")
        #endif
        closeMessageContext()
        generation = UUID()
        markingRead = [:]
        serverChatSnapshot = nil
        mediaRevision = UUID()
        mediaRefreshRevision = UUID()
        session = nil
        let previousMedia = mediaClient
        mediaClient = nil
        if let previousMedia { Task { await previousMedia.invalidate() } }
        composer.disconnect()
        connected = false
        sessionExpired = false
        reacting = []
        loadingChatIDs = []
        cachedLoadCounts = [:]
        isLoadingChats = false
        loadingFolders = false
        chatListError = nil
        chatErrors = [:]
    }

    public func messages(in id: String) -> [TeamsRenderedMessage] { renderedMessages[id] ?? [] }
    public func isLoadingConversation(_ id: String) -> Bool { loadingChatIDs.contains(id) || cachedLoadCounts[id, default: 0] > 0 }
    public func ownsSharePointAttachment(_ attachment: TeamsSharePointAttachment) -> Bool {
        guard attachment.accountScope == accountScope, attachment.accountRevision == accountRevision else { return false }
        if let revision = attachment.contextRevision {
            guard revision == contextRevision, contextChatID == attachment.chatID else { return false }
            return contextMessages.contains { message in
                message.id == attachment.messageID && message.files.contains { $0.sharePoint == attachment }
            }
        }
        return (renderedMessages[attachment.chatID] ?? []).contains { message in
            message.id == attachment.messageID && message.files.contains { $0.sharePoint == attachment }
        }
    }
    #if DEBUG
    public func cachedSharePointProofCandidate() async -> TeamsSharePointAttachment? {
        guard connected, let cache else { return nil }
        let current = generation, revision = accountRevision
        for chat in chats.prefix(100) {
            let history: TeamsCachedHistory
            if let loaded = histories[chat.id] { history = loaded }
            else { guard let stored = try? await cache.history(in: chat.id) else { continue }; history = stored }
            guard current == generation, revision == accountRevision, connected else { return nil }
            histories[chat.id] = history
            render(chat.id)
            if let candidate = (renderedMessages[chat.id] ?? []).lazy.flatMap(\.files).compactMap(\.sharePoint).first,
               UUID(uuidString: candidate.fileID) != nil { return candidate }
        }
        return nil
    }
    #endif

    public func closeMessageContext() {
        contextRevision = UUID(); contextChatID = nil; contextTargetID = nil; contextMessages = []
        contextRawMessages = []; contextLoading = false; contextError = nil; contextActionError = nil
        contextBackwardToken = nil; contextForwardToken = nil
        contextBackwardLoading = false; contextForwardLoading = false
        contextBackwardError = nil; contextForwardError = nil
        contextSequences = [:]; contextBackwardSeen = []; contextForwardSeen = []
    }

    private func renderCurrentContext() {
        guard let chatID = contextChatID else { contextMessages = []; return }
        var people: [String: Person] = [:]
        for member in conversation(chatID)?.members ?? [] {
            guard let key = member.mri ?? member.objectId else { continue }
            people[key] = Person(id: key, name: member.preferredDisplayName ?? "Teams member")
        }
        contextMessages = contextRawMessages.map { TeamsRenderedMessage($0, people: people, accountScope: accountScope, accountRevision: accountRevision, chatID: chatID, contextRevision: contextRevision) }
    }

    public func openMessageContext(in chatID: String, targetID: String) async {
        closeMessageContext()
        contextChatID = chatID; contextTargetID = targetID; contextLoading = true
        let current = generation, revision = sessionRevision, request = contextRevision
        guard connected, let session, availableClient() != nil else {
            contextLoading = false; contextError = "Reconnect to load this message."; return
        }
        do {
            let page = try await TeamsMessageContextClient(session: session, transport: transport).messages(in: chatID, pivot: targetID)
            guard generation == current, sessionRevision == revision, contextRevision == request, connected, !Task.isCancelled else { return }
            guard page.messages.contains(where: { $0.message.id == targetID }) else {
                contextLoading = false; contextError = "This message could not be found in the returned context."; return
            }
            contextRawMessages = page.messages.map(\.message)
            contextSequences = Dictionary(uniqueKeysWithValues: page.messages.compactMap { entry in entry.sequenceID.map { (entry.message.id, $0) } })
            renderCurrentContext()
            contextBackwardToken = page.backwardToken; contextForwardToken = page.forwardToken
            contextLoading = false
        } catch {
            guard generation == current, sessionRevision == revision, contextRevision == request, !Task.isCancelled else { return }
            contextLoading = false; contextError = "Could not load message context. Try again."
            if let error = error as? TeamsWebClientError { record(error, chatID: chatID) }
        }
    }

    public func loadContextPage(_ direction: TeamsMessageContextClient.Direction) async {
        guard direction != .bidirectional, let chatID = contextChatID, connected, let session, availableClient() != nil else { return }
        let backward = direction == .backward
        guard !(backward ? contextBackwardLoading : contextForwardLoading),
              let token = backward ? contextBackwardToken : contextForwardToken else { return }
        if backward { contextBackwardLoading = true; contextBackwardError = nil }
        else { contextForwardLoading = true; contextForwardError = nil }
        let current = generation, revision = sessionRevision, context = contextRevision
        defer {
            if current == generation, revision == sessionRevision, context == contextRevision {
                if backward { contextBackwardLoading = false } else { contextForwardLoading = false }
            }
        }
        do {
            let page = try await TeamsMessageContextClient(session: session, transport: transport).messages(in: chatID, pivot: token, direction: direction)
            guard current == generation, revision == sessionRevision, context == contextRevision, connected,
                  contextChatID == chatID, (backward ? contextBackwardToken : contextForwardToken) == token, !Task.isCancelled else { return }
            var byID = Dictionary(uniqueKeysWithValues: contextRawMessages.map { ($0.id, $0) })
            let before = byID
            for entry in page.messages {
                if let old = byID[entry.message.id], let a = Decimal(string: old.version ?? ""), let b = Decimal(string: entry.message.version ?? ""), b < a { continue }
                byID[entry.message.id] = entry.message
                if let sequence = entry.sequenceID { contextSequences[entry.message.id] = sequence }
            }
            let allHaveSequence = byID.keys.allSatisfy { contextSequences[$0] != nil }
            contextRawMessages = byID.values.sorted { a, b in
                if allHaveSequence, let left = contextSequences[a.id], let right = contextSequences[b.id], left != right { return left < right }
                let left = String(a.id.drop(while: { $0 == "0" })), right = String(b.id.drop(while: { $0 == "0" }))
                if left.count != right.count { return left.count < right.count }
                return left == right ? a.id < b.id : left < right
            }
            renderCurrentContext()
            if backward {
                contextBackwardSeen.insert(token)
                let next = page.backwardToken
                contextBackwardToken = page.messages.isEmpty || (next.map { contextBackwardSeen.contains($0) } ?? true) || (before == byID && next == token) ? nil : next
                contextBackwardLoading = false
            } else {
                contextForwardSeen.insert(token)
                let next = page.forwardToken
                contextForwardToken = page.messages.isEmpty || (next.map { contextForwardSeen.contains($0) } ?? true) || (before == byID && next == token) ? nil : next
                contextForwardLoading = false
            }
        } catch {
            guard current == generation, revision == sessionRevision, context == contextRevision else { return }
            if backward { contextBackwardLoading = false; contextBackwardError = "Could not load earlier messages. Try again." }
            else { contextForwardLoading = false; contextForwardError = "Could not load later messages. Try again." }
            if let error = error as? TeamsWebClientError { record(error, chatID: chatID) }
        }
    }

    public func refreshConversationFolders() async {
        guard let client = availableClient(), !loadingFolders, let cache else { return }
        let current = generation, revision = sessionRevision
        loadingFolders = true
        defer { if current == generation { loadingFolders = false } }
        do {
            let snapshot = try await client.conversationFolders()
            guard current == generation, revision == sessionRevision, !Task.isCancelled else { return }
            guard snapshot.isComplete else { foldersWarning = "Some chat sections could not be refreshed."; return }
            conversationFolders = snapshot
            foldersWarning = nil
            do { try await cache.save(snapshot) }
            catch { if current == generation { cacheWarning = "Chat sections could not be saved on this Mac." } }
        } catch {
            guard current == generation, revision == sessionRevision, !Task.isCancelled else { return }
            foldersWarning = "Chat sections could not be refreshed."
            record(error)
        }
    }

    public func replyAuthor(_ reply: TeamsReplyPreview, in chatID: String) -> String {
        let original = reply.messageID.flatMap { id in
            histories[chatID]?.messages.first { $0.id == id } ?? (contextChatID == chatID ? contextRawMessages.first { $0.id == id } : nil)
        }
        return reply.resolvedAuthor(original: original, members: conversation(chatID)?.members ?? [])
    }

    public func imageData(for image: TeamsInlineImage, fullSize: Bool = false) async throws -> Data {
        guard connected, let mediaClient else { throw TeamsMediaError.unavailable }
        let current = generation
        let data: Data
        do { data = try await mediaClient.image(at: image.url, fullSize: fullSize) }
        catch {
            guard connected, generation == current, self.mediaClient === mediaClient, !Task.isCancelled else { throw CancellationError() }
            throw error
        }
        guard connected, generation == current, self.mediaClient === mediaClient, !Task.isCancelled else { throw CancellationError() }
        return data
    }

    public func profilePhoto(for personID: String) async throws -> Data {
        guard connected, let mediaClient else { throw TeamsMediaError.unavailable }
        let current = generation
        let data: Data
        do { data = try await mediaClient.profilePhoto(for: personID) }
        catch {
            guard connected, generation == current, self.mediaClient === mediaClient, !Task.isCancelled else { throw CancellationError() }
            throw error
        }
        guard connected, generation == current, self.mediaClient === mediaClient, !Task.isCancelled else { throw CancellationError() }
        return data
    }

    public func installedAgents(in chatID: String) async throws -> [TeamsInstalledAgent] {
        guard connected, let mediaClient else { throw TeamsMediaError.unavailable }
        let current = generation, revision = sessionRevision
        let agents = try await mediaClient.installedAgents(in: chatID)
        guard connected, current == generation, revision == sessionRevision,
              self.mediaClient === mediaClient, !Task.isCancelled else { throw CancellationError() }
        return agents
    }

    public func groupPhoto(for members: [TeamsWebMember], chatID: String? = nil, picture: String? = nil, pictureVersion: String? = nil) async throws -> Data {
        guard connected, let mediaClient else { throw TeamsMediaError.unavailable }
        let current = generation
        let data: Data
        do { data = try await mediaClient.groupPhoto(for: members, chatID: chatID, picture: picture, pictureVersion: pictureVersion) }
        catch {
            guard connected, generation == current, self.mediaClient === mediaClient, !Task.isCancelled else { throw CancellationError() }
            throw error
        }
        guard connected, generation == current, self.mediaClient === mediaClient, !Task.isCancelled else { throw CancellationError() }
        return data
    }

    public struct CreationReview: Codable, Sendable {
        public enum State: String, Codable, Sendable { case pending, unknown, known }
        public let operationID: UUID
        public let state: State
        public let threadID: String?
        public let status: Int?
        public let title: String?
    }

    public private(set) var creationReview: CreationReview?
    public private(set) var creationJournalUnavailable = false
    public private(set) var directoryRetryNotBefore: Date?
    public var canFindPeople: Bool { connected && session?.directory != nil }
    private var creationGuardKey: String { "teamsChatCreationPending." + tenantID + "." + accountID }
    public var creationNeedsReview: Bool {
        creationJournalUnavailable || UserDefaults.standard.bool(forKey: creationGuardKey) ||
        (creationReview.map { $0.state != .known || $0.status != 201 } ?? false)
    }
    public var isCreatingChat: Bool { creatingAccounts.contains(creationGuardKey) }

    private func restoreCreationReview(for current: UUID) async {
        guard let cache else { return }
        do {
            let record = try await cache.creationReview()
            guard current == generation else { return }
            creationReview = record; creationJournalUnavailable = false
        } catch {
            guard current == generation else { return }
            creationJournalUnavailable = true
        }
    }

    @discardableResult public func acknowledgeChatCreationReview(expectedID: UUID? = nil, expectedAccount: String? = nil, expectedRevision: UUID? = nil, isCurrent: @MainActor () -> Bool = { true }) async -> Bool {
        guard isCurrent(), expectedAccount == nil || expectedAccount == accountScope,
              expectedRevision == nil || expectedRevision == accountRevision, let cache, !isCreatingChat else { return false }
        let current = generation, key = creationGuardKey
        do {
            guard let lease = try await cache.acquireCreationLease() else { return false }
            defer { withExtendedLifetime(lease) {} }
            guard isCurrent(), current == generation, expectedAccount == nil || expectedAccount == accountScope,
                  expectedRevision == nil || expectedRevision == accountRevision else { return false }
            let stored = try await cache.creationReview()
            guard isCurrent(), current == generation, stored?.operationID == expectedID else { return false }
            guard try await cache.updateCreationReview(expectedID: expectedID, review: nil) else { return false }
            UserDefaults.standard.set(false, forKey: key)
            guard current == generation else { return false }
            creationReview = nil; creationJournalUnavailable = false
            return true
        } catch { if current == generation { creationJournalUnavailable = true }; return false }
    }

    public func findPeople(_ query: String, expectedAccount: String? = nil, expectedRevision: UUID? = nil) async throws -> [TeamsDirectoryPerson] {
        guard expectedAccount == nil || expectedAccount == accountScope, expectedRevision == nil || expectedRevision == accountRevision,
              connected, let directory = session?.directory else { throw TeamsWebClientError.invalidSession }
        if let deadline = directoryRetryNotBefore, deadline > Date() { throw TeamsWebClientError.http(status: 429, retryAfter: deadline.timeIntervalSinceNow) }
        let current = generation, revision = sessionRevision
        do {
            let people = try await TeamsDirectoryClient(session: directory, transport: transport).searchUsers(query)
            guard current == generation, revision == sessionRevision, connected, !Task.isCancelled else { throw CancellationError() }
            return people
        } catch {
            guard current == generation, revision == sessionRevision, !Task.isCancelled else { throw CancellationError() }
            if case let TeamsWebClientError.http(status, delay) = error, status == 429 {
                let deadline = max(directoryRetryNotBefore ?? .distantPast, Date().addingTimeInterval(max(delay ?? 30, 0)))
                directoryRetryNotBefore = deadline
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
                    guard let self, self.generation == current, self.directoryRetryNotBefore == deadline, !Task.isCancelled else { return }
                    self.directoryRetryNotBefore = nil
                }
            } else if let failure = error as? TeamsWebClientError { record(failure) }
            throw error
        }
    }

    public func createChat(with people: [TeamsDirectoryPerson], title: String?, expectedAccount: String? = nil, expectedRevision: UUID? = nil, isCurrent: @MainActor () -> Bool = { true }) async throws -> TeamsConversationCreation {
        guard isCurrent(), expectedAccount == nil || expectedAccount == accountScope, expectedRevision == nil || expectedRevision == accountRevision,
              connected, let session, let cache, !creationJournalUnavailable, !isCreatingChat else { throw TeamsWebClientError.invalidSession }
        if let deadline = retryNotBefore, deadline > Date() { throw TeamsWebClientError.http(status: 429, retryAfter: deadline.timeIntervalSinceNow) }
        let current = generation, revision = sessionRevision, accountEpoch = accountRevision, account = accountScope, key = creationGuardKey, operation = UUID()
        let lease: TeamsReadLease
        do {
            guard let acquired = try await cache.acquireCreationLease() else { throw TeamsWebClientError.invalidSession }
            lease = acquired
        } catch { throw error }
        defer { withExtendedLifetime(lease) {} }
        guard isCurrent(), current == generation, revision == sessionRevision, connected,
              expectedAccount == nil || expectedAccount == accountScope,
              expectedRevision == nil || expectedRevision == accountRevision else { throw CancellationError() }
        let prior: CreationReview?
        do { prior = try await cache.creationReview() }
        catch { creationJournalUnavailable = true; throw error }
        guard current == generation, revision == sessionRevision, connected else { throw CancellationError() }
        guard !UserDefaults.standard.bool(forKey: key), prior == nil || (prior?.state == .known && prior?.status == 201) else {
            creationReview = prior; throw TeamsWebClientError.invalidSession
        }
        let members = people.compactMap { person in
            person.mri.map { TeamsConversationMember(id: $0, role: person.userType?.lowercased() == "guest" ? .guest : .admin) }
        }
        let savedTitle = title.map { String($0.prefix(256)) }
        let pending = CreationReview(operationID: operation, state: .pending, threadID: nil, status: nil, title: savedTitle)
        do {
            guard try await cache.updateCreationReview(expectedID: prior?.operationID, review: pending) else { throw TeamsWebClientError.invalidSession }
        } catch { if current == generation { creationJournalUnavailable = true }; throw error }
        creatingAccounts.insert(key)
        if current == generation { creationReview = pending }
        defer { creatingAccounts.remove(key) }
        var receivedSuccess = false
        do {
            guard isCurrent(), current == generation, revision == sessionRevision, connected else {
                _ = try await cache.updateCreationReview(expectedID: operation, review: nil)
                if current == generation { creationReview = nil }
                throw CancellationError()
            }
            let result = try await TeamsConversationClient(session: session, transport: transport).createChat(with: members, title: title)
            receivedSuccess = true
            let known = CreationReview(operationID: operation, state: .known, threadID: result.threadID, status: result.status, title: savedTitle)
            guard try await cache.updateCreationReview(expectedID: operation, review: known) else { throw TeamsConversationError.creationOutcomeUnknown }
            guard accountScope == account, accountRevision == accountEpoch else { throw CancellationError() }
            creationReview = known
            ensureKnownCreationVisible()
            return result
        } catch {
            do {
                let stored = try await cache.creationReview()
                if stored?.operationID == operation, stored?.state == .pending {
                    let next: CreationReview? = receivedSuccess || (error as? TeamsConversationError) == .creationOutcomeUnknown ? .init(operationID: operation, state: .unknown, threadID: nil, status: nil, title: savedTitle) : nil
                    guard try await cache.updateCreationReview(expectedID: operation, review: next) else { throw TeamsConversationError.creationOutcomeUnknown }
                    if current == generation { creationReview = next }
                }
            } catch { if current == generation { creationJournalUnavailable = true } }
            if current == generation, revision == sessionRevision, let failure = error as? TeamsWebClientError { record(failure) }
            throw error
        }
    }

    public func ensureKnownCreationVisible() {
        guard let review = creationReview, review.state == .known, let id = review.threadID, conversation(id) == nil else { return }
        chats.insert(TeamsWebChat(id: id, title: review.title, chatType: "chat", threadType: "chat"), at: 0)
    }

    public func refreshKnownCreation(_ id: String, expectedAccount: String, expectedRevision: UUID) async throws {
        guard accountScope == expectedAccount, accountRevision == expectedRevision, connected, let client = availableClient() else { throw CancellationError() }
        let current = generation, revision = sessionRevision
        do {
            let chat = try await client.knownChat(id)
            guard current == generation, revision == sessionRevision, accountScope == expectedAccount,
                  accountRevision == expectedRevision, connected else { throw CancellationError() }
            let old = conversation(id)
            let merged = TeamsWebChat(id: id, title: chat.title ?? old?.title, chatType: chat.chatType ?? old?.chatType,
                                      threadType: old?.threadType, isOneOnOne: chat.isOneOnOne ?? old?.isOneOnOne,
                                      isRead: chat.isRead ?? old?.isRead, hidden: chat.hidden ?? old?.hidden,
                                      isConversationDeleted: chat.isConversationDeleted ?? old?.isConversationDeleted,
                                      isDisabled: chat.isDisabled ?? old?.isDisabled, members: chat.members, lastMessage: old?.lastMessage,
                                      picture: chat.picture, pictureMetadataPresent: chat.pictureMetadataPresent, threadVersion: chat.threadVersion).retainingPicture(from: old)
            chats.removeAll { $0.id == id }; chats.insert(merged, at: 0)
        } catch {
            guard current == generation, revision == sessionRevision, accountScope == expectedAccount,
                  accountRevision == expectedRevision else { throw CancellationError() }
            if let failure = error as? TeamsWebClientError { record(failure, chatID: id) }
            throw error
        }
    }

    public var canSearchServer: Bool { connected && session?.searchSession != nil }
    public var searchCoolingDown: Bool { searchRetryNotBefore.map { $0 > Date() } ?? false }

    public func searchServer(_ query: String, in chatID: String, page: Int = 0) async throws -> TeamsMessageSearchPage {
        guard connected, let search = session?.searchSession else { throw TeamsSearchError.invalidSession }
        if let deadline = searchRetryNotBefore, deadline > Date() { throw TeamsSearchError.http(status: 429, retryAfter: deadline.timeIntervalSinceNow) }
        let current = generation, revision = sessionRevision
        do {
            let result = try await TeamsSearchClient(session: search, transport: transport).searchMessages(query: query, in: chatID, page: page)
            guard connected, current == generation, revision == sessionRevision, !Task.isCancelled else { throw CancellationError() }
            return result
        } catch {
            guard connected, current == generation, revision == sessionRevision, !Task.isCancelled else { throw CancellationError() }
            if case let TeamsSearchError.http(status, delay) = error, status == 429 {
                let deadline = max(searchRetryNotBefore ?? .distantPast, Date().addingTimeInterval(max(delay ?? 30, 0)))
                let scope = accountScope
                searchRetryNotBefore = deadline
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
                    guard let self, self.searchRetryNotBefore == deadline, self.accountScope == scope, !Task.isCancelled else { return }
                    self.searchRetryNotBefore = nil
                }
            }
            throw error
        }
    }

    public private(set) var sharedRetryNotBefore: Date?
    public func sharedItems(in chatID: String, bookmark: String? = nil, offset: Int = 0) async throws -> TeamsSharedPage {
        guard connected, let search = session?.searchSession,
              search.accountID.caseInsensitiveCompare(accountID) == .orderedSame,
              search.tenantID.caseInsensitiveCompare(tenantID) == .orderedSame else { throw TeamsSharedError.unavailable }
        if let deadline = sharedRetryNotBefore, deadline > Date() { throw TeamsSharedError.http(429, deadline.timeIntervalSinceNow) }
        let current = generation, revision = sessionRevision
        do {
            let page = try await TeamsSharedIndexClient(session: search, transport: transport).page(chatID: chatID, bookmark: bookmark, offset: offset)
            guard current == generation, revision == sessionRevision, connected, !Task.isCancelled else { throw CancellationError() }
            return page
        } catch {
            guard current == generation, revision == sessionRevision, !Task.isCancelled else { throw CancellationError() }
            if case let TeamsSharedError.http(status, delay) = error, status == 429 {
                let deadline = max(sharedRetryNotBefore ?? .distantPast, Date().addingTimeInterval(max(delay ?? 30, 0)))
                sharedRetryNotBefore = deadline
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
                    guard let self, self.generation == current, self.sharedRetryNotBefore == deadline, !Task.isCancelled else { return }
                    self.sharedRetryNotBefore = nil
                }
            }
            throw error
        }
    }

    public func markConversationRead(_ chatID: String) async { await performMarkConversationRead(chatID, finishKnownPartial: false) }
    public func finishMarkConversationRead(_ chatID: String) async { await performMarkConversationRead(chatID, finishKnownPartial: true) }
    public func markVisibleConversationRead(_ chatID: String, messageID: String) async {
        await performMarkConversationRead(chatID, finishKnownPartial: false, visibleMessageID: messageID)
    }
    private func performMarkConversationRead(_ chatID: String, finishKnownPartial: Bool, visibleMessageID: String? = nil) async {
        guard connected, let session, let cache, availableClient() != nil, markingRead[chatID] == nil, !loadingChatIDs.contains(chatID) else { return }
        let operation = UUID()
        markingRead[chatID] = operation
        readStatusMessages[chatID] = nil
        defer { if markingRead[chatID] == operation { markingRead.removeValue(forKey: chatID) } }
        let current = generation, revision = sessionRevision
        defer { Task { await self.refreshPendingReadStatus(chatID, generation: current) } }
        let lease: TeamsReadLease
        do {
            guard let acquired = try await cache.acquireReadLease(in: chatID) else {
                if current == generation, revision == sessionRevision { chatErrors[chatID] = "A read update is already in progress for this conversation." }
                return
            }
            lease = acquired
        } catch { if current == generation, revision == sessionRevision { chatErrors[chatID] = "Could not safely coordinate the read update." }; return }
        defer { withExtendedLifetime(lease) {} }
        guard current == generation, revision == sessionRevision, connected, markingRead[chatID] == operation else { return }
        if visibleMessageID == nil { await loadConversation(chatID) }
        guard current == generation, revision == sessionRevision, connected, markingRead[chatID] == operation,
              availableClient() != nil, chatErrors[chatID] == nil,
              let latest = histories[chatID]?.messages.last,
              visibleMessageID == nil || latest.id == visibleMessageID else { return }
        if let known = conversation(chatID)?.lastMessage?.arrivalDate,
           let loaded = latest.arrivalDate, known > loaded {
            chatErrors[chatID] = "Refresh this conversation before marking it as read."
            return
        }
        guard let rawArrival = TeamsChatActionsClient.arrivalMilliseconds(latest.originalArrivalTime), rawArrival > 0 else {
            chatErrors[chatID] = "The latest message has no usable read position."; return
        }
        let target = UInt64(rawArrival)
        func stillCurrent() -> Bool {
            current == generation && revision == sessionRevision && connected && markingRead[chatID] == operation && availableClient() != nil
        }
        func confirmed(_ state: TeamsReadState, target: UInt64, minimumVersion: String?) -> Bool {
            guard case .known(let horizon, _, _) = state.horizon else { return false }
            if let minimumVersion {
                guard let version = state.version, version.count > minimumVersion.count || (version.count == minimumVersion.count && version >= minimumVersion) else { return false }
            }
            let clear: Bool
            switch state.bookmark { case .unset: clear = true; case .known(let bookmark, _, _): clear = bookmark == 0; default: clear = false }
            return horizon >= target && clear
        }
        func versionAcceptable(_ state: TeamsReadState, minimum: String?) -> Bool {
            guard let minimum else { return true }
            guard let version = state.version else { return false }
            return version.count > minimum.count || (version.count == minimum.count && version >= minimum)
        }
        func definitelyRejected(_ error: any Error) -> Bool {
            if error is CancellationError { return true }
            if let action = error as? TeamsChatActionError { return action != .outcomeUnknown }
            if let web = error as? TeamsWebClientError {
                if case .http(let status, _) = web { return status != 408 && status < 500 }
                return web != .network
            }
            return false
        }
        var writeAttempted = false, bookmarkAccepted = false, attemptedBookmark = false, definiteRejection = false, localFailure = false
        do {
            let pending = try await cache.pendingRead(in: chatID)
            guard stillCurrent() else { return }
            let reader = TeamsReadStateClient(session: session, transport: transport)
            let before = try await reader.state(in: chatID)
            guard stillCurrent() else { return }
            if visibleMessageID != nil, pending != nil { return }
            if let pending, pending.stage == .prepared || pending.stage == .bookmarkRejected || (pending.stage == .horizonRejected && !pending.bookmarkRequired) {
                _ = try await cache.clearPendingRead(id: pending.id, in: chatID)
                if stillCurrent() {
                    chatErrors[chatID] = pending.stage == .prepared ? "The earlier update was not sent. Mark as read again to retry." : "The earlier update was rejected. Mark as read again to retry."
                }
                return
            }
            if let pending, confirmed(before, target: pending.targetHorizon, minimumVersion: pending.minimumVersion) {
                guard try await cache.clearPendingRead(id: pending.id, in: chatID) else {
                    if stillCurrent() { chatErrors[chatID] = "The read state changed while checking. Check again before updating." }
                    return
                }
                guard stillCurrent() else { return }
                chatErrors[chatID] = nil
                readStatusMessages[chatID] = "The earlier read update was confirmed."
                await refreshChats()
                if stillCurrent(), target > pending.targetHorizon {
                    readStatusMessages[chatID] = nil
                    chatErrors[chatID] = "The earlier read update was confirmed. Mark as read again to include newer messages."
                }
                return
            }
            if let pending {
                guard finishKnownPartial, versionAcceptable(before, minimum: pending.minimumVersion),
                      pending.stage == .bookmarkAccepted || (pending.stage == .horizonRejected && pending.bookmarkRequired) else {
                    chatErrors[chatID] = "A previous read update could not be confirmed. Check the conversation's read state before trying again."
                    return
                }
            }
            guard case .known(let horizon, _, _) = before.horizon else {
                chatErrors[chatID] = "Teams did not return a complete read state. Try again after refreshing."
                return
            }
            let bookmark: UInt64
            switch before.bookmark {
            case .unset: bookmark = 0
            case .known(let value, _, _): bookmark = value
            default: chatErrors[chatID] = "Teams did not return a complete read state. Try again after refreshing."; return
            }
            if visibleMessageID != nil && bookmark > 0 { return }
            if let pending, target < pending.targetHorizon, horizon < pending.targetHorizon {
                chatErrors[chatID] = "The saved read target is newer than the available messages. Refresh before finishing."
                return
            }
            if pending == nil && horizon >= target && bookmark == 0 { await refreshChats(); return }
            let intent: TeamsPendingReadIntent
            if let pending {
                guard let updated = try await cache.retargetPendingRead(id: pending.id, target: max(horizon, target), bookmarkRequired: bookmark > 0, minimumVersion: before.version, in: chatID) else { return }
                intent = updated
                bookmarkAccepted = true
            } else {
                intent = TeamsPendingReadIntent(targetHorizon: max(horizon, target), bookmarkRequired: bookmark > 0, minimumVersion: before.version)
                guard try await cache.installPendingRead(intent, in: chatID) else {
                    if stillCurrent() { chatErrors[chatID] = "A previous read update needs confirmation before trying again." }
                    return
                }
            }
            guard stillCurrent() else {
                if pending == nil { _ = try? await cache.clearPendingRead(id: intent.id, in: chatID) }
                return
            }
            let actions = TeamsChatActionsClient(session: session, transport: transport)
            if bookmark > 0 {
                guard try await cache.advancePendingRead(id: intent.id, stage: .bookmarkDispatched, in: chatID) else { return }
                guard stillCurrent() else {
                    if pending != nil { _ = try? await cache.advancePendingRead(id: intent.id, stage: .bookmarkAccepted, in: chatID) }
                    else { _ = try? await cache.clearPendingRead(id: intent.id, in: chatID) }
                    return
                }
                writeAttempted = true
                attemptedBookmark = true
                do { try await actions.clearUnreadBookmark(in: chatID) }
                catch {
                    if definitelyRejected(error) {
                        definiteRejection = true
                        if case TeamsWebClientError.http = error { localFailure = false } else { localFailure = true }
                        if pending != nil { _ = try? await cache.advancePendingRead(id: intent.id, stage: .bookmarkAccepted, in: chatID) }
                        else if (try? await cache.advancePendingRead(id: intent.id, stage: .bookmarkRejected, in: chatID)) == true { _ = try? await cache.clearPendingRead(id: intent.id, in: chatID) }
                    }
                    throw error
                }
                bookmarkAccepted = true
                guard try await cache.advancePendingRead(id: intent.id, stage: .bookmarkAccepted, in: chatID) else { return }
                guard stillCurrent() else { return }
            }
            if horizon < target {
                guard try await cache.advancePendingRead(id: intent.id, stage: .horizonDispatched, in: chatID) else { return }
                guard stillCurrent() else {
                    if bookmarkAccepted { _ = try? await cache.advancePendingRead(id: intent.id, stage: .bookmarkAccepted, in: chatID) }
                    else { _ = try? await cache.clearPendingRead(id: intent.id, in: chatID) }
                    return
                }
                writeAttempted = true
                attemptedBookmark = false
                do { try await actions.markRead(in: chatID, through: latest) }
                catch {
                    if definitelyRejected(error) {
                        definiteRejection = true
                        if case TeamsWebClientError.http = error { localFailure = false } else { localFailure = true }
                        if (try? await cache.advancePendingRead(id: intent.id, stage: .horizonRejected, in: chatID)) == true, !bookmarkAccepted { _ = try? await cache.clearPendingRead(id: intent.id, in: chatID) }
                    }
                    throw error
                }
                guard try await cache.advancePendingRead(id: intent.id, stage: .horizonAccepted, in: chatID) else { return }
                guard stillCurrent() else { return }
            }
            let after = try await reader.state(in: chatID)
            guard stillCurrent() else { return }
            guard confirmed(after, target: max(horizon, target), minimumVersion: intent.minimumVersion) else {
                chatErrors[chatID] = "The read update was sent but could not be confirmed. Check its state before trying again."
                return
            }
            guard try await cache.clearPendingRead(id: intent.id, in: chatID) else {
                if stillCurrent() { chatErrors[chatID] = "The read state changed while confirming. Check again before updating." }
                return
            }
            guard stillCurrent() else { return }
            chatErrors[chatID] = nil
            readStatusMessages[chatID] = "Read update confirmed."
            await refreshChats()
        } catch {
            guard current == generation, revision == sessionRevision, markingRead[chatID] == operation else { return }
            if let webError = error as? TeamsWebClientError { record(webError, chatID: chatID) }
            if bookmarkAccepted && attemptedBookmark {
                chatErrors[chatID] = definiteRejection ? "The current unread bookmark update was rejected. The earlier partial update remains; no retry was sent." : "The current unread bookmark update could not be confirmed. No automatic retry was sent."
            } else {
            chatErrors[chatID] = bookmarkAccepted
                ? (localFailure ? "The unread bookmark was cleared, but the read position could not be prepared. No retry was sent." : (definiteRejection ? "The unread bookmark was cleared, but Teams rejected the read position. No automatic retry was sent." : "The unread bookmark was cleared, but the read position could not be confirmed. No automatic retry was sent."))
                : (localFailure ? "The read update could not be prepared. No update was sent." : (definiteRejection ? "Teams rejected the read update. No update was applied." : (writeAttempted ? "The read update could not be confirmed. No automatic retry was sent." : "Teams could not read the current read state. No update was sent.")))
            }
        }
    }

    public func checkReadStatus(_ chatID: String) async {
        guard connected, let session, let cache, availableClient() != nil, markingRead[chatID] == nil else { return }
        let current = generation, revision = sessionRevision, operation = UUID()
        markingRead[chatID] = operation
        defer {
            if markingRead[chatID] == operation { markingRead.removeValue(forKey: chatID) }
            Task { await self.refreshPendingReadStatus(chatID, generation: current) }
        }
        do {
            guard let lease = try await cache.acquireReadLease(in: chatID) else {
                if current == generation, revision == sessionRevision { readStatusMessages[chatID] = "A read update is still in progress." }
                return
            }
            defer { withExtendedLifetime(lease) {} }
            guard current == generation, revision == sessionRevision, connected, markingRead[chatID] == operation else { return }
            guard let pending = try await cache.pendingRead(in: chatID) else {
                if current == generation, revision == sessionRevision { readStatusMessages[chatID] = "No read update is awaiting confirmation." }
                return
            }
            if pending.stage == .prepared || pending.stage == .bookmarkRejected || (pending.stage == .horizonRejected && !pending.bookmarkRequired) {
                guard try await cache.clearPendingRead(id: pending.id, in: chatID) else { return }
                if current == generation, revision == sessionRevision {
                    readStatusMessages[chatID] = pending.stage == .prepared ? "The earlier update was not sent." : "The earlier update was rejected."
                    chatErrors[chatID] = nil
                }
                return
            }
            let state = try await TeamsReadStateClient(session: session, transport: transport).state(in: chatID)
            guard current == generation, revision == sessionRevision, connected, markingRead[chatID] == operation else { return }
            let versionAcceptable: Bool
            if let minimum = pending.minimumVersion, let version = state.version {
                versionAcceptable = version.count > minimum.count || (version.count == minimum.count && version >= minimum)
            } else { versionAcceptable = pending.minimumVersion == nil }
            let bookmarkClear: Bool
            switch state.bookmark { case .unset: bookmarkClear = true; case .known(let value, _, _): bookmarkClear = value == 0; default: bookmarkClear = false }
            guard case .known(let horizon, _, _) = state.horizon, horizon >= pending.targetHorizon, bookmarkClear, versionAcceptable else {
                if pending.stage == .bookmarkAccepted || (pending.stage == .horizonRejected && pending.bookmarkRequired) {
                    readStatusMessages[chatID] = "The earlier update is partly complete. Choose Finish Mark as Read to continue."
                } else { readStatusMessages[chatID] = "The read update remains unconfirmed. No repeat was sent." }
                return
            }
            guard try await cache.clearPendingRead(id: pending.id, in: chatID) else { return }
            guard current == generation, revision == sessionRevision else { return }
            readStatusMessages[chatID] = "The earlier read update was confirmed."
            chatErrors[chatID] = nil
            await refreshChats()
        } catch {
            guard current == generation, revision == sessionRevision else { return }
            readStatusMessages[chatID] = "Could not check the read update. No repeat was sent."
            if let webError = error as? TeamsWebClientError { record(webError, chatID: chatID) }
        }
    }

    private func refreshPendingReadStatus(_ chatID: String, generation expected: UUID) async {
        guard let cache else { return }
        do {
            let pending = try await cache.pendingRead(in: chatID)
            guard expected == generation else { return }
            if let pending {
                pendingReadChatIDs.insert(chatID)
                if pending.stage == .bookmarkAccepted || (pending.stage == .horizonRejected && pending.bookmarkRequired) { finishableReadChatIDs.insert(chatID) }
                else { finishableReadChatIDs.remove(chatID) }
            } else { pendingReadChatIDs.remove(chatID); finishableReadChatIDs.remove(chatID) }
        } catch { if expected == generation { cacheWarning = "A saved read update could not be checked on this Mac." } }
    }

    public func canEditMessage(in chatID: String, messageID: String) -> Bool {
        guard let type = historyMessage(in: chatID, id: messageID)?.messageType else { return false }
        return deletionStages[ReactionTarget(chat: chatID, message: messageID)] == nil && (type == "Text" || type == "RichText/Html")
    }

    public func beginMessageEdit(in chatID: String, messageID: String, accountScope expectedScope: String) async throws -> TeamsMessageEditSession {
        guard expectedScope == accountScope, connected, let cache else { throw TeamsWebClientError.sendingUnavailable }
        guard let message = histories[chatID]?.messages.first(where: { $0.id == messageID }) else { throw TeamsChatActionError.invalidMessage }
        guard let sender = message.senderID, sender.caseInsensitiveCompare("8:orgid:" + accountID) == .orderedSame || sender.caseInsensitiveCompare(accountID) == .orderedSame else { throw TeamsChatActionError.ownMessageRequired }
        let current = generation, revision = sessionRevision
        let pending: TeamsPendingEdit?
        do {
            guard try await cache.pendingDeletion(in: chatID, messageID: messageID) == nil else { throw TeamsMessageEditError.storage }
            pending = try await cache.pendingEdit(in: chatID, messageID: messageID)
        }
        catch { throw TeamsMessageEditError.storage }
        guard current == generation, revision == sessionRevision, accountScope == expectedScope, connected else { throw CancellationError() }
        let source = pending?.original ?? message
        let imported = try TeamsChatActionsClient.editableContent(source)
        let edit = TeamsMessageEditSession(chatID: chatID, accountScope: expectedScope, original: source, document: pending?.document ?? imported.document)
        edit.journalID = pending?.id
        if let pending, pending.stage == .uncertain || pending.stage == .dispatched || pending.stage == .accepted {
            edit.uncertain = true
            edit.status = pending.stage == .accepted ? "Edit saved. Check status to load the current message." : "The edit may have succeeded. Check its status before trying again."
        } else if pending?.stage == .rejected { edit.status = "The edit was rejected. Your changes are available to retry." }
        return edit
    }

    public func saveMessageEdit(_ edit: TeamsMessageEditSession) async {
        guard !edit.saving, !edit.uncertain, !edit.completed, edit.accountScope == accountScope else { return }
        edit.saving = true; edit.status = nil
        defer { edit.saving = false }
        let current = generation, revision = sessionRevision, proposed = edit.document
        func stillCurrent() -> Bool { generation == current && sessionRevision == revision && connected && accountScope == edit.accountScope && !Task.isCancelled }
        guard let cache else { edit.status = "The edit could not be saved on this Mac. Your changes are still here."; return }
        guard connected, let session, session.messaging != nil, let chat = conversation(edit.chatID), chat.isDisabled != true, chat.isConversationDeleted != true else {
            let saved = await retainUnsentMessageEdit(edit, document: proposed, cache: cache, generation: current, revision: revision)
            if saved, generation == current, sessionRevision == revision { edit.status = "Reconnect to save this edit. Your changes are saved on this Mac." }
            return
        }
        guard let readClient = availableClient() else {
            let saved = await retainUnsentMessageEdit(edit, document: proposed, cache: cache, generation: current, revision: revision)
            if saved, generation == current, sessionRevision == revision { edit.status = "Teams is limiting requests. Try again later; your changes are saved on this Mac." }
            return
        }
        do {
            let before = try TeamsChatActionsClient.editableContent(edit.original).document.serialize(), after = try proposed.serialize()
            guard before.html != after.html || before.mentionsJSON != after.mentionsJSON else { edit.status = "No changes to save."; return }
            guard let lease = try await cache.acquireEditLease(in: edit.chatID, messageID: edit.original.id) else { edit.status = "This message is being edited in another window."; return }
            defer { withExtendedLifetime(lease) {} }
            guard try await cache.pendingDeletion(in: edit.chatID, messageID: edit.original.id) == nil else { edit.status = "Check the deletion before editing this message."; return }
            let previous = try await cache.pendingEdit(in: edit.chatID, messageID: edit.original.id)
            guard stillCurrent() else { return }
            if let previous, previous.stage == .dispatched || previous.stage == .uncertain || previous.stage == .accepted {
                edit.journalID = previous.id; edit.uncertain = true
                edit.status = previous.stage == .accepted ? "Edit saved. Check status to load the current message." : "The edit may have succeeded. Check its status before trying again."
                return
            }
            let intent: TeamsPendingEdit
            if let previous {
                guard previous.id == edit.journalID, previous.stage == .prepared || previous.stage == .rejected else { edit.status = "Another edit is already saved for this message."; return }
                intent = previous
                guard try await cache.updatePendingEdit(id: intent.id, in: edit.chatID, messageID: edit.original.id, expected: previous.stage, document: proposed, stage: .prepared) else { return }
            } else {
                intent = TeamsPendingEdit(original: edit.original, document: proposed)
                guard try await cache.installPendingEdit(intent, in: edit.chatID) else { edit.status = "Another edit is already saved for this message."; return }
            }
            edit.journalID = intent.id
            guard stillCurrent() else { return }
            let fresh = try await readClient.message(in: edit.chatID, id: edit.original.id)
            guard stillCurrent() else { return }
            guard fresh == edit.original else {
                _ = try? await cache.updatePendingEdit(id: intent.id, in: edit.chatID, messageID: edit.original.id, expected: .prepared, stage: .rejected)
                guard stillCurrent() else { return }
                _ = await mergeTargetedEdit(fresh, in: edit.chatID, generation: current, revision: revision)
                guard stillCurrent() else { return }
                edit.status = "The message changed. Your draft is saved; discard this saved edit before reopening the current message."; return
            }
            guard stillCurrent(), try await cache.updatePendingEdit(id: intent.id, in: edit.chatID, messageID: edit.original.id, expected: .prepared, stage: .dispatched) else { return }
            guard stillCurrent() else { _ = try? await cache.restoreUndispatchedEdit(id: intent.id, in: edit.chatID, messageID: edit.original.id); return }
            guard availableClient() != nil else {
                _ = try? await cache.restoreUndispatchedEdit(id: intent.id, in: edit.chatID, messageID: edit.original.id)
                if stillCurrent() { edit.status = "Teams is limiting requests. Your changes are saved; try again later." }
                return
            }
            var responseAccepted = false
            do {
                try await TeamsChatActionsClient(session: session, transport: transport).editDocument(proposed, in: edit.chatID, message: edit.original)
                responseAccepted = true
                guard stillCurrent() else { edit.uncertain = true; return }
                guard try await cache.updatePendingEdit(id: intent.id, in: edit.chatID, messageID: edit.original.id, expected: .dispatched, stage: .accepted) else { edit.uncertain = true; return }
                guard stillCurrent() else { return }
                edit.uncertain = true; edit.status = "Edit saved. Check status to load the updated message."
                do {
                    let fresh = try await readClient.message(in: edit.chatID, id: edit.original.id)
                    guard stillCurrent() else { return }
                    guard isNewerEditTarget(fresh, original: intent.original) else { return }
                    let matches = (try? matchesEdit(fresh, original: intent.original, desired: proposed)) == true
                    guard await mergeTargetedEdit(fresh, in: edit.chatID, generation: current, revision: revision) else { edit.status = "Edit saved, but the updated message could not be stored. Check status later."; return }
                    guard stillCurrent(), try await cache.clearPendingEdit(id: intent.id, in: edit.chatID, messageID: edit.original.id), stillCurrent() else { return }
                    edit.uncertain = false; edit.completed = true; edit.status = matches ? "Saved." : "Edit saved. Close to review the current message."
                } catch {
                    if stillCurrent() {
                        if let error = error as? TeamsWebClientError { record(error, chatID: edit.chatID) }
                        edit.status = "Edit saved, but the updated message could not be loaded. Check status later."
                    }
                }
            } catch {
                guard stillCurrent() else { edit.uncertain = true; return }
                let unknown = responseAccepted || (error as? TeamsChatActionError) == .outcomeUnknown
                _ = try? await cache.updatePendingEdit(id: intent.id, in: edit.chatID, messageID: edit.original.id, expected: .dispatched, stage: unknown ? .uncertain : .rejected)
                edit.uncertain = unknown
                edit.status = unknown ? "The edit may have succeeded. Check its status before trying again." : "The edit was not saved. Your changes are available to retry."
                if let error = error as? TeamsWebClientError { record(error, chatID: edit.chatID) }
            }
        } catch {
            if stillCurrent() {
                if let error = error as? TeamsWebClientError { record(error, chatID: edit.chatID) }
                edit.status = "The edit could not be prepared. Your changes are still here."
            }
        }
    }

    private func retainUnsentMessageEdit(_ edit: TeamsMessageEditSession, document: TeamsRichDraft, cache: TeamsReadCache, generation expected: UUID, revision: UUID) async -> Bool {
        do {
            guard let lease = try await cache.acquireEditLease(in: edit.chatID, messageID: edit.original.id) else { edit.status = "This message is being edited in another window."; return false }
            defer { withExtendedLifetime(lease) {} }
            guard generation == expected, sessionRevision == revision, accountScope == edit.accountScope, !Task.isCancelled else { return false }
            guard try await cache.pendingDeletion(in: edit.chatID, messageID: edit.original.id) == nil else { edit.status = "Check the deletion before editing this message."; return false }
            let previous = try await cache.pendingEdit(in: edit.chatID, messageID: edit.original.id)
            guard generation == expected, sessionRevision == revision, accountScope == edit.accountScope, !Task.isCancelled else { return false }
            if let previous {
                guard previous.id == edit.journalID else { edit.status = "Another edit is already saved for this message."; return false }
                guard previous.stage == .prepared || previous.stage == .rejected else { edit.uncertain = true; edit.status = "The edit may have succeeded. Check its status before trying again."; return false }
                guard try await cache.updatePendingEdit(id: previous.id, in: edit.chatID, messageID: edit.original.id, expected: previous.stage, document: document, stage: .prepared) else { return false }
            } else {
                let intent = TeamsPendingEdit(original: edit.original, document: document)
                guard try await cache.installPendingEdit(intent, in: edit.chatID) else { return false }
                edit.journalID = intent.id
            }
            return generation == expected && sessionRevision == revision && accountScope == edit.accountScope && !Task.isCancelled
        } catch { if generation == expected, sessionRevision == revision { edit.status = "The edit could not be saved on this Mac. Your changes are still here." }; return false }
    }

    public func checkMessageEdit(_ edit: TeamsMessageEditSession) async {
        guard !edit.saving, edit.uncertain, edit.accountScope == accountScope, let cache, let id = edit.journalID else { return }
        guard let client = availableClient() else { edit.status = connected ? "Teams is limiting requests. Try checking later." : "Reconnect to check this edit."; return }
        edit.saving = true; defer { edit.saving = false }
        let current = generation, revision = sessionRevision
        do {
            guard let lease = try await cache.acquireEditLease(in: edit.chatID, messageID: edit.original.id) else { edit.status = "This message is being checked in another window."; return }
            defer { withExtendedLifetime(lease) {} }
            guard let pending = try await cache.pendingEdit(in: edit.chatID, messageID: edit.original.id), pending.id == id else { return }
            guard current == generation, revision == sessionRevision, connected, edit.accountScope == accountScope, !Task.isCancelled else { return }
            if pending.stage == .accepted {
                let fresh = try await client.message(in: edit.chatID, id: edit.original.id)
                guard current == generation, revision == sessionRevision, connected, edit.accountScope == accountScope, !Task.isCancelled else { return }
                guard isNewerEditTarget(fresh, original: pending.original) else { edit.status = "Edit saved, but the updated message is not available yet. Check status later."; return }
                let matches = (try? matchesEdit(fresh, original: pending.original, desired: pending.document)) == true
                guard await mergeTargetedEdit(fresh, in: edit.chatID, generation: current, revision: revision) else { edit.status = "The updated message could not be stored. Check status later."; return }
                guard current == generation, revision == sessionRevision, connected, edit.accountScope == accountScope, !Task.isCancelled,
                      try await cache.clearPendingEdit(id: id, in: edit.chatID, messageID: edit.original.id),
                      current == generation, revision == sessionRevision, connected, !Task.isCancelled else { return }
                edit.uncertain = false; edit.completed = true; edit.status = matches ? "Edit confirmed." : "Edit saved. Close to review the current message."
                return
            }
            guard pending.stage == .dispatched || pending.stage == .uncertain else { return }
            let fresh = try await client.message(in: edit.chatID, id: edit.original.id)
            guard current == generation, revision == sessionRevision, connected, edit.accountScope == accountScope, !Task.isCancelled else { return }
            guard try matchesEdit(fresh, original: pending.original, desired: pending.document) else {
                edit.status = "The edit could not be confirmed. Your changes remain saved, and another write is blocked."; return
            }
            guard await mergeTargetedEdit(fresh, in: edit.chatID, generation: current, revision: revision) else { edit.status = "The updated message could not be stored. Check status later."; return }
            guard current == generation, revision == sessionRevision, connected, edit.accountScope == accountScope, !Task.isCancelled else { return }
            guard try await cache.confirmPendingEdit(id: id, in: edit.chatID, messageID: edit.original.id) else { return }
            guard current == generation, revision == sessionRevision, connected, edit.accountScope == accountScope, !Task.isCancelled else { return }
            edit.uncertain = false; edit.completed = true; edit.status = "Edit confirmed."
        } catch {
            if current == generation, revision == sessionRevision, !Task.isCancelled {
                if let error = error as? TeamsWebClientError { record(error, chatID: edit.chatID) }
                edit.status = "Could not check the edit. Your changes remain saved."
            }
        }
    }

    private func matchesEdit(_ fresh: TeamsWebMessage, original: TeamsWebMessage, desired: TeamsRichDraft) throws -> Bool {
        let actual = try TeamsChatActionsClient.editableContent(fresh), before = try TeamsChatActionsClient.editableContent(original)
        let actualDocument = try actual.document.serialize(), desiredDocument = try desired.serialize()
        guard isNewerEditTarget(fresh, original: original) else { return false }
        return actual.reply == before.reply && actualDocument.html == desiredDocument.html && actualDocument.mentionsJSON == desiredDocument.mentionsJSON
    }

    private func isNewerEditTarget(_ fresh: TeamsWebMessage, original: TeamsWebMessage) -> Bool {
        guard fresh.id == original.id, fresh.senderID == original.senderID,
              original.version?.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil,
              fresh.version?.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil,
              let oldVersion = original.version.flatMap({ Decimal(string: $0) }),
              let newVersion = fresh.version.flatMap({ Decimal(string: $0) }), newVersion > oldVersion else { return false }
        return true
    }

    private func mergeTargetedEdit(_ message: TeamsWebMessage, in chatID: String, generation expected: UUID, revision: UUID) async -> Bool {
        guard generation == expected, sessionRevision == revision, connected, !Task.isCancelled,
              var history = histories[chatID], history.messages.contains(where: { $0.id == message.id }), let cache else { return false }
        if let existing = history.messages.first(where: { $0.id == message.id }),
           let old = existing.version.flatMap({ Decimal(string: $0) }), let new = message.version.flatMap({ Decimal(string: $0) }), new < old { return false }
        history.merge([message]); histories[chatID] = history; render(chatID)
        do { try await cache.save(history, in: chatID) } catch { return false }
        guard generation == expected, sessionRevision == revision, connected, !Task.isCancelled else { return false }
        if contextChatID == chatID, let index = contextRawMessages.firstIndex(where: { $0.id == message.id }) {
            if let old = contextRawMessages[index].version.flatMap({ Decimal(string: $0) }), let new = message.version.flatMap({ Decimal(string: $0) }), new < old { return true }
            contextRawMessages[index] = message
            renderCurrentContext()
        }
        return true
    }

    public func discardMessageEdit(_ edit: TeamsMessageEditSession) async -> Bool {
        guard !edit.saving, !edit.uncertain, edit.accountScope == accountScope, let cache else { return false }
        guard let id = edit.journalID else { return true }
        do {
            guard let lease = try await cache.acquireEditLease(in: edit.chatID, messageID: edit.original.id) else { return false }
            defer { withExtendedLifetime(lease) {} }
            guard edit.accountScope == accountScope, !Task.isCancelled else { return false }
            return try await cache.clearPendingEdit(id: id, in: edit.chatID, messageID: edit.original.id)
        } catch { edit.status = "The saved edit could not be discarded."; return false }
    }

    public func retainMessageEdit(_ edit: TeamsMessageEditSession) async -> Bool {
        guard !edit.saving, !edit.uncertain, !edit.completed, edit.accountScope == accountScope, let cache else { return false }
        edit.saving = true; defer { edit.saving = false }
        return await retainUnsentMessageEdit(edit, document: edit.document, cache: cache, generation: generation, revision: sessionRevision)
    }

    public func canReact(in chatID: String, messageID: String) -> Bool {
        let target = ReactionTarget(chat: chatID, message: messageID)
        guard connected, !sessionExpired, session?.messaging != nil, !loadingChatIDs.contains(chatID),
              retryNotBefore.map({ $0 <= Date() }) ?? true,
              let chat = conversation(chatID), chat.isDisabled != true, chat.isConversationDeleted != true,
              let message = renderedMessage(in: chatID, id: messageID) ?? (contextChatID == chatID ? contextMessages.first(where: { $0.id == messageID }) : nil), !message.isDeleted else { return false }
        return !reacting.contains(target) && !reactionsAwaitingRefresh.contains(target)
    }

    public func reactionNeedsConfirmation(in chatID: String, messageID: String) -> Bool {
        reactionsAwaitingRefresh.contains(ReactionTarget(chat: chatID, message: messageID))
    }

    private func setDeletionStage(_ stage: TeamsPendingDeletion.Stage?, for target: ReactionTarget) {
        deletionStatusRevision[target] = UUID()
        if acceptedDeletionMemory.contains(target), stage == .dispatched || stage == .uncertain { deletionStages[target] = .accepted }
        else { deletionStages[target] = stage }
    }
    public func deletionStage(in chatID: String, messageID: String) -> TeamsPendingDeletion.Stage? {
        deletionStages[ReactionTarget(chat: chatID, message: messageID)]
    }
    public func deletionMessage(in chatID: String, messageID: String) -> String? {
        deletionMessages[ReactionTarget(chat: chatID, message: messageID)]
    }
    public func canDelete(in chatID: String, messageID: String) -> Bool {
        let stage = deletionStage(in: chatID, messageID: messageID)
        guard let message = historyMessage(in: chatID, id: messageID), !TeamsRenderedMessage.isDeleted(message) else { return false }
        return connected && session?.messaging != nil && (retryNotBefore.map { $0 <= Date() } ?? true) && (stage == nil || stage == .rejected)
    }
    public func loadDeletionStatus(in chatID: String, messageID: String, expectedScope: String, expectedRevision: UUID) async {
        guard expectedScope == accountScope, expectedRevision == accountRevision, let cache else { return }
        let current = generation, target = ReactionTarget(chat: chatID, message: messageID)
        let observed = deletionStatusRevision[target]
        do {
            let pending = try await cache.pendingDeletion(in: chatID, messageID: messageID)
            guard current == generation, expectedRevision == accountRevision, expectedScope == accountScope, deletionStatusRevision[target] == observed else { return }
            if acceptedDeletionMemory.contains(target), pending == nil || pending?.stage == .dispatched || pending?.stage == .uncertain { deletionStages[target] = .accepted }
            else { deletionStages[target] = pending?.stage }
        } catch { if current == generation, expectedRevision == accountRevision, expectedScope == accountScope { chatErrors[chatID] = "Could not read the saved deletion status." } }
    }

    private func deleteMessage(in chatID: String, messageID: String, expectedScope: String?, expectedRevision: UUID?) async {
        guard expectedScope == nil || expectedScope == accountScope, expectedRevision == nil || expectedRevision == accountRevision,
              connected, let session, let cache, let message = histories[chatID]?.messages.first(where: { $0.id == messageID }),
              !TeamsRenderedMessage(message, people: [:]).isDeleted, let sender = message.senderID, sender.caseInsensitiveCompare("8:orgid:" + accountID) == .orderedSame || sender.caseInsensitiveCompare(accountID) == .orderedSame else { return }
        guard availableClient() != nil else { chatErrors[chatID] = "Teams is limiting requests. Try deleting later."; return }
        let current = generation, revision = sessionRevision, epoch = accountRevision, target = ReactionTarget(chat: chatID, message: messageID)
        func currentOwner() -> Bool { current == generation && revision == sessionRevision && epoch == accountRevision && connected && !Task.isCancelled }
        deletionStatusRevision[target] = UUID()
        if !acceptedDeletionMemory.contains(target) { deletionMessages[target] = nil }
        do {
            let acquired = try await cache.acquireEditLease(in: chatID, messageID: messageID)
            guard currentOwner() else { return }
            guard let lease = acquired else { chatErrors[chatID] = "This message is being changed in another window."; return }
            defer { withExtendedLifetime(lease) {} }
            let pendingEdit = try await cache.pendingEdit(in: chatID, messageID: messageID)
            guard currentOwner() else { return }
            guard pendingEdit == nil else { chatErrors[chatID] = "Check or discard the saved edit before deleting."; return }
            let pendingDeletion = try await cache.pendingDeletion(in: chatID, messageID: messageID)
            guard currentOwner() else { return }
            if let existing = pendingDeletion {
                guard currentOwner() else { return }
                setDeletionStage(existing.stage, for: target)
                guard existing.stage == .rejected else { return }
                guard try await cache.updatePendingDeletion(id: existing.id, in: chatID, messageID: messageID, expected: .rejected, stage: nil) else { return }
            }
            guard currentOwner(), availableClient() != nil, histories[chatID]?.messages.first(where: { $0.id == messageID }) == message else { return }
            let intent = TeamsPendingDeletion(original: message)
            let installed = try await cache.installPendingDeletion(intent, in: chatID)
            guard currentOwner() else {
                if installed { _ = try? await cache.updatePendingDeletion(id: intent.id, in: chatID, messageID: messageID, expected: .prepared, stage: nil) }
                return
            }
            guard installed else { chatErrors[chatID] = "A saved change already exists for this message."; return }
            guard currentOwner(), availableClient() != nil else {
                _ = try? await cache.updatePendingDeletion(id: intent.id, in: chatID, messageID: messageID, expected: .prepared, stage: nil)
                return
            }
            guard try await cache.updatePendingDeletion(id: intent.id, in: chatID, messageID: messageID, expected: .prepared, stage: .dispatched) else { return }
            guard currentOwner(), availableClient() != nil, let currentMessage = histories[chatID]?.messages.first(where: { $0.id == messageID }),
                  currentMessage == message, !TeamsRenderedMessage(currentMessage, people: [:]).isDeleted else {
                _ = try? await cache.updatePendingDeletion(id: intent.id, in: chatID, messageID: messageID, expected: .dispatched, stage: .rejected)
                if currentOwner() { setDeletionStage(.rejected, for: target) }
                return
            }
            setDeletionStage(.dispatched, for: target)
            var responseAccepted = false
            do {
                try await TeamsChatActionsClient(session: session, transport: transport).delete(in: chatID, message: message)
                responseAccepted = true
                if current == generation, epoch == accountRevision {
                    acceptedDeletionMemory.insert(target); setDeletionStage(.accepted, for: target)
                    deletionMessages[target] = "Deletion accepted; saving status."
                }
                let saved = try await cache.updatePendingDeletion(id: intent.id, in: chatID, messageID: messageID, expected: .dispatched, stage: .accepted)
                guard current == generation, epoch == accountRevision else { return }
                guard saved else { deletionMessages[target] = "Deletion accepted, but status could not be saved. Check status later."; return }
                deletionMessages[target] = "Deletion accepted; check status."
                guard currentOwner() else { return }
                Task { await self.checkDeletion(in: chatID, messageID: messageID, expectedScope: expectedScope, expectedRevision: epoch) }
            } catch {
                if responseAccepted {
                    if current == generation, epoch == accountRevision {
                        acceptedDeletionMemory.insert(target); setDeletionStage(.accepted, for: target)
                        deletionMessages[target] = "Deletion accepted, but status could not be saved. Check status later."
                    }
                    return
                }
                let stage: TeamsPendingDeletion.Stage = (error as? TeamsChatActionError) == .outcomeUnknown ? .uncertain : .rejected
                _ = try? await cache.updatePendingDeletion(id: intent.id, in: chatID, messageID: messageID, expected: .dispatched, stage: stage)
                guard current == generation, epoch == accountRevision else { return }
                setDeletionStage(stage, for: target)
                deletionMessages[target] = stage == .rejected ? "Deletion was rejected. Retry later or dismiss." : "Deletion may have succeeded; check status."
                guard currentOwner() else { return }
                if let failure = error as? TeamsWebClientError { record(failure, chatID: chatID) }
            }
        } catch { if currentOwner() { chatErrors[chatID] = "Could not safely save deletion status. No repeat was sent." } }
    }

    public func checkDeletion(in chatID: String, messageID: String, expectedScope: String? = nil, expectedRevision: UUID? = nil) async {
        guard expectedScope == nil || expectedScope == accountScope, expectedRevision == nil || expectedRevision == accountRevision, let cache else { return }
        let target = ReactionTarget(chat: chatID, message: messageID)
        guard let client = availableClient() else {
            let prefix = deletionStages[target] == .accepted ? "Deletion accepted. " : ""
            deletionMessages[target] = prefix + (connected ? "Teams is limiting requests. Check later." : "Reconnect to check deletion.")
            return
        }
        var acceptedDuringCheck = acceptedDeletionMemory.contains(target)
        let current = generation, revision = sessionRevision, epoch = accountRevision
        guard !checkingDeletions.contains(target) else { return }
        checkingDeletions.insert(target); defer { if current == generation { checkingDeletions.remove(target) } }
        do {
            guard let lease = try await cache.acquireEditLease(in: chatID, messageID: messageID) else { return }
            defer { withExtendedLifetime(lease) {} }
            guard current == generation, revision == sessionRevision, epoch == accountRevision, connected, !Task.isCancelled,
                  var intent = try await cache.pendingDeletion(in: chatID, messageID: messageID) else { return }
            #if DEBUG
            await deletionCheckAfterJournal?()
            #endif
            acceptedDuringCheck = acceptedDuringCheck || intent.stage == .accepted
            if intent.stage == .prepared {
                guard current == generation, revision == sessionRevision, epoch == accountRevision, connected, !Task.isCancelled,
                      try await cache.updatePendingDeletion(id: intent.id, in: chatID, messageID: messageID, expected: .prepared, stage: .rejected) else { return }
                guard current == generation, revision == sessionRevision, epoch == accountRevision else { return }
                setDeletionStage(.rejected, for: target); deletionMessages[target] = "Deletion did not start. You may retry or dismiss."
                return
            }
            guard current == generation, revision == sessionRevision, epoch == accountRevision, connected, !Task.isCancelled else { return }
            guard availableClient() != nil else { deletionMessages[target] = "Teams is limiting requests. Check later."; return }
            guard [.dispatched, .accepted, .uncertain].contains(intent.stage) else { return }
            if acceptedDeletionMemory.contains(target), intent.stage == .dispatched {
                guard try await cache.updatePendingDeletion(id: intent.id, in: chatID, messageID: messageID, expected: .dispatched, stage: .accepted) else { return }
                intent.stage = .accepted
            }
            guard current == generation, revision == sessionRevision, epoch == accountRevision, connected, !Task.isCancelled else { return }
            guard availableClient() != nil else { deletionMessages[target] = "Teams is limiting requests. Check later."; return }
            let fresh = try await client.message(in: chatID, id: messageID)
            guard current == generation, revision == sessionRevision, epoch == accountRevision, connected, !Task.isCancelled else { return }
            let rendered = TeamsRenderedMessage(fresh, people: [:])
            let newest = histories[chatID]?.messages.first(where: { $0.id == messageID })
            let newestVersion = newest?.version.flatMap { $0.range(of: "^[0-9]{1,30}$", options: .regularExpression) == nil ? nil : Decimal(string: $0) }
            let freshVersion = fresh.version.flatMap { Decimal(string: $0) }
            guard rendered.isDeleted, isNewerEditTarget(fresh, original: intent.original),
                  newest?.senderID == intent.original.senderID, let newestVersion, let freshVersion, freshVersion >= newestVersion else {
                deletionMessages[target] = intent.stage == .accepted || acceptedDeletionMemory.contains(target) ? "Deletion accepted; the updated message is not available yet." : "Deletion could not be confirmed. No repeat was sent."
                return
            }
            let merged = await mergeTargetedEdit(fresh, in: chatID, generation: current, revision: revision)
            guard current == generation, revision == sessionRevision, epoch == accountRevision, connected, !Task.isCancelled else { return }
            guard merged else { deletionMessages[target] = "The updated message could not be saved. Check again."; return }
            guard current == generation, revision == sessionRevision, epoch == accountRevision, connected, !Task.isCancelled,
                  try await cache.updatePendingDeletion(id: intent.id, in: chatID, messageID: messageID, expected: intent.stage, stage: nil) else { return }
            guard current == generation, revision == sessionRevision, epoch == accountRevision else { return }
            acceptedDeletionMemory.remove(target); setDeletionStage(nil, for: target); deletionMessages[target] = nil; chatErrors[chatID] = nil
        } catch {
            guard current == generation, revision == sessionRevision, epoch == accountRevision, !Task.isCancelled else { return }
            deletionMessages[target] = acceptedDuringCheck ? "Deletion accepted; its status or message could not be checked." : "Could not check deletion. The previous result remains saved."
            if let failure = error as? TeamsWebClientError { record(failure, chatID: chatID) }
        }
    }

    public func dismissRejectedDeletion(in chatID: String, messageID: String, expectedScope: String, expectedRevision: UUID) async {
        guard expectedScope == accountScope, expectedRevision == accountRevision, let cache else { return }
        let current = generation, target = ReactionTarget(chat: chatID, message: messageID)
        do {
            guard let lease = try await cache.acquireEditLease(in: chatID, messageID: messageID) else { return }
            defer { withExtendedLifetime(lease) {} }
            guard current == generation, expectedRevision == accountRevision, expectedScope == accountScope,
                  let intent = try await cache.pendingDeletion(in: chatID, messageID: messageID), intent.stage == .rejected else { return }
            guard current == generation, expectedRevision == accountRevision, expectedScope == accountScope,
                  try await cache.updatePendingDeletion(id: intent.id, in: chatID, messageID: messageID, expected: .rejected, stage: nil) else { return }
            if current == generation, expectedRevision == accountRevision { setDeletionStage(nil, for: target); deletionMessages[target] = nil }
        } catch { if current == generation, expectedRevision == accountRevision, expectedScope == accountScope { chatErrors[chatID] = "Could not clear the rejected deletion." } }
    }

    public func messageAction(_ action: String, chatID: String, messageID: String, text: String = "", accountScope expectedScope: String? = nil, accountRevision expectedRevision: UUID? = nil, contextScope expectedContext: UUID? = nil) async {
        if action == "delete" { await deleteMessage(in: chatID, messageID: messageID, expectedScope: expectedScope, expectedRevision: expectedRevision); return }
        guard action != "edit" else { return }
        guard expectedScope == nil || expectedScope == accountScope,
              expectedContext == nil || expectedContext == contextRevision,
              connected, let session, let message = histories[chatID]?.messages.first(where: { $0.id == messageID }) ?? (contextChatID == chatID ? contextRawMessages.first(where: { $0.id == messageID }) : nil) else { return }
        let client = TeamsChatActionsClient(session: session, transport: transport)
        let current = generation
        let revision = sessionRevision
        let isReaction = !["edit", "delete", "unread"].contains(action)
        let target = ReactionTarget(chat: chatID, message: messageID)
        if isReaction {
            guard canReact(in: chatID, messageID: messageID) else { return }
            let key = action.hasPrefix("remove:") ? String(action.dropFirst(7)) : action
            let rendered = renderedMessages[chatID]?.first(where: { $0.id == messageID }) ?? (contextChatID == chatID ? contextMessages.first(where: { $0.id == messageID }) : nil)
            let existing = rendered?.reactions.contains(where: { $0.key == key }) == true
            guard ["like", "heart", "laugh", "surprised"].contains(key) || existing else { return }
            reacting.insert(target); reactionsAwaitingRefresh.insert(target)
        }
        defer { if isReaction && current == generation { reacting.remove(target) } }
        do {
            switch action {
            case "delete": try await client.delete(in: chatID, message: message)
            case "unread": try await client.markUnread(in: chatID, before: message)
            default:
                if action.hasPrefix("remove:") { try await client.removeReaction(String(action.dropFirst(7)), in: chatID, message: message) }
                else { try await client.setReaction(action, in: chatID, message: message, replaceExisting: false) }
            }
            guard current == generation, revision == sessionRevision else { return }
            if isReaction { reacting.remove(target) }
            if action == "unread" { await refreshChats() }
            else if isReaction, contextChatID == chatID, contextRawMessages.contains(where: { $0.id == messageID }) { await refreshContextReaction(chatID: chatID, messageID: messageID) }
            else { await refreshConversation(chatID) }
        } catch {
            guard current == generation, revision == sessionRevision else { return }
            if isReaction && (error as? TeamsChatActionError) != .outcomeUnknown { reactionsAwaitingRefresh.remove(target) }
            if let webError = error as? TeamsWebClientError { record(webError, chatID: chatID) }
            else if (error as? TeamsChatActionError) == .outcomeUnknown {
                chatErrors[chatID] = "The action may have succeeded. Refresh the conversation before trying again."
            } else { chatErrors[chatID] = "Teams could not complete the action. Refresh the conversation to check its current state." }
            if isReaction, contextChatID == chatID, contextRawMessages.contains(where: { $0.id == messageID }) {
                contextActionError = (error as? TeamsChatActionError) == .outcomeUnknown
                    ? "The reaction may have succeeded. Check it before reacting again."
                    : "Teams could not complete the reaction. Try again."
            }
        }
    }

    public func refreshContextReaction(chatID: String, messageID: String, contextScope expectedContext: UUID? = nil) async {
        let target = ReactionTarget(chat: chatID, message: messageID)
        guard expectedContext == nil || expectedContext == contextRevision,
              contextChatID == chatID, reactionsAwaitingRefresh.contains(target), let client = availableClient() else { return }
        let current = generation, revision = sessionRevision, context = contextRevision
        do {
            let message = try await client.message(in: chatID, id: messageID)
            guard current == generation, revision == sessionRevision, context == contextRevision, connected, !Task.isCancelled,
                  let index = contextRawMessages.firstIndex(where: { $0.id == messageID }) else { return }
            contextRawMessages[index] = message
            renderCurrentContext()
            if var history = histories[chatID], history.messages.contains(where: { $0.id == messageID }) {
                history.merge([message]); histories[chatID] = history; render(chatID)
                try? await cache?.save(history, in: chatID)
                guard current == generation, revision == sessionRevision, context == contextRevision else { return }
            }
            reactionsAwaitingRefresh.remove(target)
            contextActionError = nil
        } catch {
            guard current == generation, revision == sessionRevision, context == contextRevision, !Task.isCancelled else { return }
            contextActionError = "Could not confirm the reaction. Check again before reacting."
            if let error = error as? TeamsWebClientError { record(error, chatID: chatID) }
        }
    }

    public func hasOlderMessages(_ id: String) -> Bool { histories[id]?.messageToken?.isEmpty == false }

    public var selfChat: TeamsWebChat? {
        guard !accountID.isEmpty else { return nil }
        return TeamsWebChat(id: "48:notes", title: "\(accountName) (You)", chatType: "chat", threadType: "notes",
                            isOneOnOne: true, members: [.init(mri: "8:orgid:" + accountID, objectId: accountID, displayName: accountName)])
    }

    public func conversation(_ id: String) -> TeamsWebChat? {
        if id == "48:notes" { return selfChat }
        return chats.first { $0.id == id }
    }

    @discardableResult public func sendDraft(in id: String) async -> String? {
        guard let chat = conversation(id), chat.isDisabled != true,
              chat.isConversationDeleted != true, let cache else { return nil }
        let current = generation
        let draftReply = composer.replies[id]
        var reply = draftReply.flatMap { target in histories[id]?.messages.first { $0.id == target.messageID } ?? (contextChatID == id ? contextRawMessages.first { $0.id == target.messageID } : nil) }
        if let value = reply, (try? TeamsChatActionsClient.quotedReplyProperties(for: value)) == nil { reply = nil }
        if reply == nil, let target = draftReply {
            guard let preparation = composer.beginPreparation(in: id) else { return nil }
            defer { _ = composer.finishPreparation(in: id, revision: preparation) }
            guard let client = availableClient() else { chatErrors[id] = "Reconnect to load the message you are replying to."; return nil }
            let revision = sessionRevision
            do { reply = try await client.message(in: id, id: target.messageID) }
            catch {
                guard current == generation, revision == sessionRevision else { return nil }
                chatErrors[id] = "Could not load the message you are replying to. Your draft is saved."
                if let error = error as? TeamsWebClientError { record(error, chatID: id) }
                return nil
            }
            guard current == generation, revision == sessionRevision,
                  composer.finishPreparation(in: id, revision: preparation) else { return nil }
        }
        guard let sent = await composer.sendDraft(in: id, replyingTo: reply, preview: draftReply?.preview ?? ""), current == generation else { return nil }
        do {
            var history: TeamsCachedHistory
            if let existing = histories[id] { history = existing }
            else { history = try await cache.history(in: id) }
            guard current == generation else { return nil }
            history = histories[id] ?? history
            history.merge([sent])
            histories[id] = history
            render(id)
            try await cache.save(history, in: id)
        } catch { if current == generation { cacheWarning = "The message was sent, but could not be saved on this Mac." } }
        guard current == generation else { return nil }
        await refreshConversation(id)
        return sent.id
    }

    public func conversationTitle(_ chat: TeamsWebChat) -> String {
        if let title = chat.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        let others = chat.members?.filter { $0.objectId != accountID && $0.mri != "8:orgid:\(accountID)" } ?? []
        let names = others.filter { $0.kind != .agent }
            .compactMap(\.preferredDisplayName).filter { !$0.isEmpty }
        if names.isEmpty, !others.isEmpty, others.allSatisfy({ $0.kind == .agent }), let agent = others.first {
            let name = agent.displayName ?? ""
            return name.isEmpty || name.range(of: "^Bot-[0-9a-f-]+$", options: [.regularExpression, .caseInsensitive]) != nil ? "Agent" : name
        }
        if names.isEmpty && others.isEmpty && chat.members?.contains(where: { $0.objectId == accountID }) == true { return "\(accountName) (You)" }
        if names.isEmpty && !others.isEmpty { return "Teams chat" }
        return names.isEmpty ? chat.displayTitle : names.joined(separator: ", ")
    }

    public func loadChats() async {
        if chats.isEmpty { await refreshChats() }
    }

    public func refreshChats() async { _ = await fetchChats(more: false) }
    @discardableResult public func loadMoreChats() async -> TeamsChatPageLoadResult { await fetchChats(more: true) }

    private func refreshGroupPictureMetadata(_ id: String) async {
        guard connected, mediaClient != nil, let chat = conversation(id), id != "48:notes", chat.isOneOnOne != true,
              !groupPictureListMetadata.contains(id), groupPictureLookups[id] == nil, let client = availableClient() else { return }
        if let fresh = groupPictureFreshness[id], fresh.version == chat.threadVersion,
           Date().timeIntervalSince(fresh.checkedAt) < 60 { return }
        let current = generation, revision = sessionRevision
        let request = UUID()
        groupPictureLookups[id] = request
        defer { if groupPictureLookups[id] == request { groupPictureLookups.removeValue(forKey: id) } }
        do {
            let metadata = try await client.knownChat(id)
            guard current == generation, revision == sessionRevision, connected, !Task.isCancelled else { return }
            guard !groupPictureListMetadata.contains(id),
                  let index = chats.firstIndex(where: { $0.id == id }),
                  chats[index].picture == chat.picture, chats[index].threadVersion == chat.threadVersion else { return }
            groupPictureFreshness[id] = (metadata.pictureMetadataPresent ? (metadata.threadVersion ?? chat.threadVersion) : chat.threadVersion, Date())
            guard metadata.pictureMetadataPresent else { return }
            let old = chats[index]
            chats[index] = TeamsWebChat(id: old.id, title: old.title, chatType: old.chatType, threadType: old.threadType,
                                        isOneOnOne: old.isOneOnOne, isRead: old.isRead, hidden: old.hidden,
                                        isConversationDeleted: old.isConversationDeleted, isDisabled: old.isDisabled,
                                        members: old.members, lastMessage: old.lastMessage, picture: metadata.picture, pictureMetadataPresent: true, threadVersion: metadata.threadVersion ?? old.threadVersion)
            try? await cache?.save(.init(chats: chats, continuationToken: chatsCursor, refreshedAt: lastRefreshedAt))
        } catch {
            if current == generation, revision == sessionRevision, let failure = error as? TeamsWebClientError {
                switch failure {
                case .expiredSession, .http(status: 401, retryAfter: _), .http(status: 429, retryAfter: _): record(failure)
                default: break
                }
            }
        }
    }

    #if DEBUG
    @ObservationIgnored public var cachedLoadGate: TeamsCachedLoadGate?
    @ObservationIgnored public var onCachedLoadTiming: (@MainActor (String, Double, Bool) -> Void)?
    #endif

    public func loadConversation(_ id: String) async {
        Task { await self.refreshGroupPictureMetadata(id) }
        let current = generation
        if renderedMessages[id] == nil, let cache {
            cachedLoadCounts[id, default: 0] += 1
            defer { if current == generation { cachedLoadCounts[id, default: 0] -= 1 } }
            do {
                #if DEBUG
                let cacheStart = ContinuousClock.now
                #endif
                var history: TeamsCachedHistory
                if let existing = histories[id] { history = existing }
                else { history = try await cache.history(in: id) }
                guard current == generation, !Task.isCancelled else { return }
                history = histories[id] ?? history
                histories[id] = history
                #if DEBUG
                onCachedLoadTiming?("cache_read", cachedLoadMilliseconds(since: cacheStart), false)
                #endif
                if renderedMessages[id] == nil {
                    let people = renderingPeople(in: id), scope = accountScope, epoch = accountRevision
                    #if DEBUG
                    let gate = cachedLoadGate
                    let request = TeamsCachedLoadGate.Request(accountScope: scope, accountRevision: epoch, generation: current, chatID: id)
                    var preparationCompleted = false
                    defer { gate?.complete(request, cancelled: !preparationCompleted) }
                    try await gate?.wait(request)
                    guard current == generation, epoch == accountRevision, !Task.isCancelled else { return }
                    #endif
                    let prepared = try await cachedMessageRenderer.render(history.messages, people: people, accountScope: scope, accountRevision: epoch, chatID: id)
                    guard current == generation, !Task.isCancelled else { return }
                    #if DEBUG
                    onCachedLoadTiming?("conversion", prepared.conversionMilliseconds, prepared.convertedOnMainThread)
                    let publicationStart = ContinuousClock.now
                    #endif
                    if histories[id]?.messages == history.messages {
                        if people == renderingPeople(in: id) {
                            composer.reconcile(history.messages, in: id)
                            renderingInputs[id] = RenderingInputs(messages: history.messages, messageIndices: prepared.indices, people: people, accountScope: scope, accountRevision: epoch)
                            if renderedMessages[id] != prepared.messages { renderedMessages[id] = prepared.messages }
                        } else { render(id) }
                    }
                    #if DEBUG
                    onCachedLoadTiming?("publication", cachedLoadMilliseconds(since: publicationStart), true)
                    preparationCompleted = true
                    #endif
                }
            } catch {
                guard current == generation, !Task.isCancelled, !(error is CancellationError) else { return }
                cacheWarning = "Saved messages could not be read. A new download will replace this conversation's cache."
            }
        }
        guard current == generation, !Task.isCancelled else { return }
        await refreshConversation(id)
    }

    public func refreshConversation(_ id: String) async {
        guard let client = availableClient(), !loadingChatIDs.contains(id), !reacting.contains(where: { $0.chat == id }), let cache else { return }
        let revision = sessionRevision
        let current = generation
        loadingChatIDs.insert(id)
        chatErrors[id] = nil
        defer { if current == generation { loadingChatIDs.remove(id) } }
        do {
            var history: TeamsCachedHistory
            if let existing = histories[id] { history = existing }
            else { history = try await cache.history(in: id) }
            guard current == generation, !Task.isCancelled else { return }
            let known = Set(history.messages.map(\.id))
            var cursor: String?
            var seen: Set<String> = []
            var pages: [TeamsWebMessage] = []
            var reachedKnownMessage = false
            let targets = Set(reactionsAwaitingRefresh.filter { $0.chat == id }.map(\.message))
            var foundTargets = Set<String>()
            var pageCount = 0
            repeat {
                try Task.checkCancellation()
                let page = try await client.messages(in: id, messageToken: cursor)
                guard current == generation, !Task.isCancelled else { return }
                pages += page.messages
                pageCount += 1
                reachedKnownMessage = reachedKnownMessage || page.messages.contains { known.contains($0.id) }
                foundTargets.formUnion(page.messages.map(\.id).filter { targets.contains($0) })
                cursor = nonempty(page.messageToken)
                if let cursor, !seen.insert(cursor).inserted { throw TeamsWebClientError.invalidPaginationToken }
                if (known.isEmpty || reachedKnownMessage) && targets.isSubset(of: foundTargets) { break }
            } while cursor != nil && pageCount < 20
            history.merge(histories[id]?.messages ?? [])
            history.merge(pages)
            if current == generation, revision == sessionRevision {
                let ids = Set(pages.map(\.id))
                reactionsAwaitingRefresh = reactionsAwaitingRefresh.filter { $0.chat != id || !ids.contains($0.message) }
                if !targets.isSubset(of: foundTargets) {
                    chatErrors[id] = "Could not confirm the reaction in the recent message history. Refresh to check again."
                }
            }
            if known.isEmpty || (!reachedKnownMessage && targets.isEmpty) { history.messageToken = cursor }
            history.refreshedAt = Date()
            histories[id] = history
            render(id)
            lastRefreshedAt = history.refreshedAt
            do { try await cache.save(history, in: id) }
            catch { if current == generation { cacheWarning = "Messages are available for this session, but could not be saved on this Mac." } }
        } catch {
            if current == generation && revision == sessionRevision { record(error, chatID: id) }
        }
    }

    public func loadOlderMessages(_ id: String) async {
        guard let client = availableClient(), !loadingChatIDs.contains(id), let cache,
              var history = histories[id], let cursor = nonempty(history.messageToken) else { return }
        let revision = sessionRevision
        let current = generation
        loadingChatIDs.insert(id)
        chatErrors[id] = nil
        defer { if current == generation { loadingChatIDs.remove(id) } }
        do {
            let page = try await client.messages(in: id, messageToken: cursor)
            guard current == generation, !Task.isCancelled else { return }
            let next = nonempty(page.messageToken)
            guard next != cursor else { throw TeamsWebClientError.invalidPaginationToken }
            history.merge(histories[id]?.messages ?? [])
            history.merge(page.messages)
            history.messageToken = next
            histories[id] = history
            render(id)
            do { try await cache.save(history, in: id) }
            catch { if current == generation { cacheWarning = "Older messages could not be saved on this Mac." } }
        } catch {
            if current == generation && revision == sessionRevision { record(error, chatID: id) }
        }
    }

    private func resetAccount(accountID: String, tenantID: String, displayName: String) {
        #if DEBUG
        cachedLoadGate?.invalidate(reason: "account_changed")
        #endif
        accountRevision = UUID()
        closeMessageContext()
        generation = UUID()
        markingRead = [:]
        mediaRevision = UUID()
        mediaRefreshRevision = UUID()
        session = nil
        let previousMedia = mediaClient
        mediaClient = nil
        if let previousMedia { Task { await previousMedia.invalidate() } }
        self.accountID = accountID
        self.tenantID = tenantID
        accountName = displayName
        cache = TeamsReadCache(root: cacheRoot, accountID: accountID, tenantID: tenantID)
        composer.restore(accountID: accountID, tenantID: tenantID)
        chats = []; histories = [:]; renderedMessages = [:]; groupPictureLookups = [:]; groupPictureFreshness = [:]; groupPictureListMetadata = []
        cachedLoadCounts = [:]
        renderingInputs = [:]
        serverChatSnapshot = nil
        pendingReadChatIDs = []; finishableReadChatIDs = []; readStatusMessages = [:]
        conversationFolders = nil; foldersWarning = nil; loadingFolders = false
        loadingChatIDs = []; isLoadingChats = false; hasMoreChats = false
        reacting = []; reactionsAwaitingRefresh = []; deletionStages = [:]; deletionStatusRevision = [:]; deletionMessages = [:]; acceptedDeletionMemory = []; checkingDeletions = []
        chatsCursor = nil; connected = false; sessionExpired = false
        chatListError = nil; chatErrors = [:]; cacheWarning = nil; lastRefreshedAt = nil
        retryNotBefore = nil
        searchRetryNotBefore = nil
        directoryRetryNotBefore = nil
        sharedRetryNotBefore = nil
        creationReview = nil; creationJournalUnavailable = true
    }

    private func restoreChats(for current: UUID) async {
        guard let cache else { return }
        do {
            let stored = try await cache.chats()
            guard current == generation, !Task.isCancelled else { return }
            chats = stored.chats
            chatsCursor = nonempty(stored.continuationToken)
            hasMoreChats = chatsCursor != nil
            lastRefreshedAt = stored.refreshedAt
            let ids = stored.chats.map(\.id)
            Task { for id in ids { await self.refreshPendingReadStatus(id, generation: current) } }
        } catch {
            if current == generation { cacheWarning = "Saved conversations could not be read. Connect to Teams to download them again." }
        }
    }

    private func restoreFolders(for current: UUID) async {
        guard let cache else { return }
        do {
            let stored = try await cache.folders()
            guard current == generation else { return }
            if stored?.isComplete == true { conversationFolders = stored }
        } catch { if current == generation { foldersWarning = "Saved chat sections could not be read." } }
    }

    private func fetchChats(more: Bool) async -> TeamsChatPageLoadResult {
        guard let client = availableClient(), !isLoadingChats, let cache else { return .deferred }
        if more && chatsCursor == nil { return .deferred }
        let revision = sessionRevision
        let current = generation
        let previousCursor = chatsCursor
        isLoadingChats = true
        chatListError = nil
        defer { if current == generation { isLoadingChats = false } }
        do {
            let page = try await client.chats(continuationToken: more ? chatsCursor : nil)
            guard current == generation, revision == sessionRevision, !Task.isCancelled else { return .deferred }
            if more && nonempty(page.continuationToken) == previousCursor { throw TeamsWebClientError.invalidPaginationToken }
            let wasEmpty = chats.isEmpty
            var byID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for chat in page.items {
                if let previous = byID[chat.id], chat.threadVersion != previous.threadVersion, chat.threadVersion != nil {
                    groupPictureFreshness.removeValue(forKey: chat.id)
                }
                if chat.pictureMetadataPresent { groupPictureListMetadata.insert(chat.id) }
                else { groupPictureListMetadata.remove(chat.id) }
                byID[chat.id] = chat.retainingPicture(from: byID[chat.id])
            }
            chats = byID.values.filter { $0.isConversationDeleted != true }.sorted {
                let left = $0.lastMessage?.arrivalDate ?? .distantPast, right = $1.lastMessage?.arrivalDate ?? .distantPast
                return left == right ? $0.id < $1.id : left > right
            }
            if !more {
                let snapshot = TeamsServerChatSnapshot(revision: UUID(), accountScope: accountScope, chats: page.items)
                serverChatSnapshot = snapshot
                onServerChatSnapshot?(snapshot)
            }
            if more || wasEmpty || previousCursor == nil { chatsCursor = nonempty(page.continuationToken) }
            hasMoreChats = chatsCursor != nil
            lastRefreshedAt = Date()
            let ids = page.items.map(\.id)
            Task { for id in ids { await self.refreshPendingReadStatus(id, generation: current) } }
            for id in histories.keys { render(id) }
            do { try await cache.save(.init(chats: chats, continuationToken: chatsCursor, refreshedAt: lastRefreshedAt)) }
            catch { if current == generation { cacheWarning = "Conversations could not be saved on this Mac." } }
        } catch {
            if current == generation && revision == sessionRevision { record(error) }
        }
        return .attempted
    }

    private func historyMessage(in chatID: String, id: String) -> TeamsWebMessage? {
        guard let messages = histories[chatID]?.messages else { return nil }
        if let index = renderingInputs[chatID]?.messageIndices[id], messages.indices.contains(index), messages[index].id == id {
            return messages[index]
        }
        return messages.first { $0.id == id }
    }

    private func renderedMessage(in chatID: String, id: String) -> TeamsRenderedMessage? {
        guard let messages = renderedMessages[chatID] else { return nil }
        if let index = renderingInputs[chatID]?.messageIndices[id], messages.indices.contains(index), messages[index].id == id {
            return messages[index]
        }
        return messages.first { $0.id == id }
    }

    private func renderingPeople(in id: String) -> [String: Person] {
        var people: [String: Person] = [:]
        for member in conversation(id)?.members ?? [] {
            guard let key = member.mri ?? member.objectId else { continue }
            people[key] = Person(id: key, name: member.preferredDisplayName ?? "Teams member")
        }
        return people
    }

    private func render(_ id: String) {
        let messages = histories[id]?.messages ?? []
        composer.reconcile(messages, in: id)
        let people = renderingPeople(in: id)
        let previous = renderingInputs[id]
        let canReuse = previous?.people == people && previous?.accountScope == accountScope
            && previous?.accountRevision == accountRevision
        if canReuse, previous?.messages == messages { return }

        var reusable: [String: (raw: TeamsWebMessage, rendered: TeamsRenderedMessage)] = [:]
        if canReuse, let previous {
            for (raw, rendered) in zip(previous.messages, renderedMessages[id] ?? []) {
                reusable[raw.id] = (raw, rendered)
            }
        }
        let rendered = messages.map { message in
            if let cached = reusable[message.id], cached.raw == message { return cached.rendered }
            return TeamsRenderedMessage(message, people: people, accountScope: accountScope, accountRevision: accountRevision, chatID: id)
        }
        let messageIndices = Dictionary(messages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        renderingInputs[id] = RenderingInputs(messages: messages, messageIndices: messageIndices, people: people, accountScope: accountScope, accountRevision: accountRevision)
        if renderedMessages[id] != rendered { renderedMessages[id] = rendered }
    }

    private func availableClient() -> TeamsWebClient? {
        guard connected, let session else { return nil }
        if let retryNotBefore, retryNotBefore > Date() { return nil }
        return TeamsWebClient(session: session, transport: transport)
    }

    private func record(_ error: any Error, chatID: String? = nil) {
        if error is CancellationError || Task.isCancelled { return }
        let message = (error as? TeamsWebClientError)?.localizedDescription ?? "Teams could not complete this read. Try again."
        if let chatID { chatErrors[chatID] = message } else { chatListError = message }
        if let failure = error as? TeamsWebClientError {
            switch failure {
            case .expiredSession, .http(status: 401, retryAfter: _):
                sessionExpired = true
                connected = false
                composer.disconnect()
            case let .http(status: 429, retryAfter: delay):
                let wait = max(delay ?? 30, 0)
                let deadline = max(retryNotBefore ?? .distantPast, Date().addingTimeInterval(wait))
                retryNotBefore = deadline
                let current = generation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
                    guard let self, !Task.isCancelled, self.generation == current, self.retryNotBefore == deadline else { return }
                    self.retryNotBefore = nil
                }
            default: break
            }
        }
    }

    private func nonempty(_ string: String?) -> String? { string.flatMap { $0.isEmpty ? nil : $0 } }
}

private actor TeamsCachedMessageRenderer {
    struct Prepared: Sendable {
        let messages: [TeamsRenderedMessage]
        let indices: [String: Int]
        #if DEBUG
        let conversionMilliseconds: Double
        let convertedOnMainThread: Bool
        #endif
    }

    func render(_ messages: [TeamsWebMessage], people: [String: Person], accountScope: String, accountRevision: UUID, chatID: String) throws -> Prepared {
        #if DEBUG
        let start = ContinuousClock.now
        #endif
        var rendered: [TeamsRenderedMessage] = []
        var indices: [String: Int] = [:]
        rendered.reserveCapacity(messages.count)
        indices.reserveCapacity(messages.count)
        for message in messages {
            try Task.checkCancellation()
            if indices[message.id] == nil { indices[message.id] = rendered.count }
            rendered.append(TeamsRenderedMessage(message, people: people, accountScope: accountScope, accountRevision: accountRevision, chatID: chatID))
        }
        #if DEBUG
        return Prepared(messages: rendered, indices: indices, conversionMilliseconds: cachedLoadMilliseconds(since: start), convertedOnMainThread: Thread.isMainThread)
        #else
        return Prepared(messages: rendered, indices: indices)
        #endif
    }
}

#if DEBUG
private func cachedLoadMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
}
#endif
