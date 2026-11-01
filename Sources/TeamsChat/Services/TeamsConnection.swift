import AppKit
import Darwin
import Observation
import TeamsCore
import TeamsCredentialPersistence
import WebKit

struct TeamsFileCredential: Sendable, CustomStringConvertible, CustomReflectable {
    let id: UUID
    let token: String
    let resource: TeamsSharePointResource
    let accountID: String
    let tenantID: String
    let accountRevision: UUID
    let connectionGeneration: UUID
    let acquiredAt: Date
    let expiresAt: Date
    let scope: String?
    var description: String { "TeamsFileCredential(<redacted>)" }
    var customMirror: Mirror { Mirror(self, children: ["credentials": "<redacted>"]) }
}

enum TeamsFileAuthorizationError: Error { case busy, unavailable, staleAccount, throttled, persistenceUncertain }
private struct TeamsFileCooldownKey: Hashable { let resource: TeamsSharePointResource; let account: String; let tenant: String; let revision: UUID }
@MainActor private final class TeamsFileCredentialWaiter {
    var continuation: CheckedContinuation<TeamsFileCredential, Error>?
    var finished = false
    func finish(_ result: Result<TeamsFileCredential, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor @Observable
final class TeamsConnection: NSObject, WKNavigationDelegate, WKUIDelegate {
    let reader: TeamsReaderStore
    let refreshCoordinator: TeamsRefreshCoordinator
    private let credentialStore: any TeamsCredentialAccess
    private let transport: any HTTPTransport
    private let defaults: UserDefaults
    private let clearWebData: (@escaping @MainActor () -> Void) -> Void
    private let webRecoveryOverride: (@MainActor () -> Void)?
    private let now: @MainActor () -> Date
    var showSignIn = false
    private(set) var error: String?
    private(set) var expiresAt: Date?
    private(set) var isConnecting = false
    private(set) var isClearingSignIn = false
    private(set) var keychainNeedsApproval = false
    private(set) var credentialWriteUncertain = false
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastToken = ""
    @ObservationIgnored private var lastMessagingToken = ""
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var credentials: TeamsCredentials?
    @ObservationIgnored private var renewalTask: Task<Void, Never>?
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var checkingWebSession = false
    @ObservationIgnored private var loadingCredentials = false
    @ObservationIgnored private var resourceRetryAfter: [String: Date] = [:]
    @ObservationIgnored private var credentialRevision = UUID()
    @ObservationIgnored private var fileCredentials: [TeamsSharePointResource: TeamsFileCredential] = [:]
    @ObservationIgnored private var fileAcquisitions: [TeamsSharePointResource: (id: UUID, account: String, tenant: String, task: Task<TeamsFileCredential, Error>)] = [:]
    @ObservationIgnored private var fileRetryAfter: [TeamsFileCooldownKey: Date] = [:]
    @ObservationIgnored private var pendingFileRotation: (old: TeamsCredentials, updated: TeamsCredentials)?
    #if DEBUG
    @ObservationIgnored private var sharePointProofStarted = false
    @ObservationIgnored var filePreviewAfterCredential: (@MainActor () async -> Void)?
    #endif

    init(reader: TeamsReaderStore, credentialStore: any TeamsCredentialAccess = TeamsKeychainCredentialAccess(),
         transport: any HTTPTransport = TeamsWebURLSessionTransport(), initialCredentials: TeamsCredentials? = nil,
         defaults: UserDefaults = .standard, clearWebData: ((@escaping @MainActor () -> Void) -> Void)? = nil,
         webRecovery: (@MainActor () -> Void)? = nil, now: @escaping @MainActor () -> Date = Date.init) {
        self.reader = reader; self.refreshCoordinator = TeamsRefreshCoordinator(reader: reader, defaults: defaults)
        self.credentialStore = credentialStore; self.transport = transport; self.credentials = initialCredentials
        self.defaults = defaults
        self.webRecoveryOverride = webRecovery
        self.now = now
        self.clearWebData = clearWebData ?? { completion in
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                Task { @MainActor in completion() }
            }
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        refreshCoordinator.start()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                await self.checkWebSession()
                let saved = self.credentials.flatMap { try? TeamsSessionHandoff.decode($0.handoff) }
                let known = self.credentials.flatMap { try? TeamsSessionHandoff.decode($0.handoff, at: .distantPast) }
                let deadline = self.now().addingTimeInterval(300)
                let searchDue = (saved?.searchSession?.expiresAt ?? .distantPast) < deadline && self.now() >= (self.resourceRetryAfter["search"] ?? .distantPast)
                let directoryDue = known?.directoryBaseURL != nil && (saved?.directory?.expiresAt ?? .distantPast) < deadline && self.now() >= (self.resourceRetryAfter["directory"] ?? .distantPast)
                let needsOptional = searchDue || directoryDue
                if self.reader.sessionExpired || (self.expiresAt?.timeIntervalSinceNow ?? 0) < 300 || needsOptional {
                    await self.renew()
                }
            }
        }
        let startupGeneration = generation
        if let account = defaults.string(forKey: "teamsAccountID"), let tenant = defaults.string(forKey: "teamsTenantID") {
            await reader.restoreAccount(accountID: account, tenantID: tenant,
                                        displayName: defaults.string(forKey: "teamsAccountName") ?? "Teams account")
        }
        guard startupGeneration == generation else { return }
        do {
            let restored = defaults.bool(forKey: "teamsSignedOut") ? nil : try await credentialStore.load(interactive: false)
            guard startupGeneration == generation else { return }
            credentials = restored
            if let credentials {
                if let session = try? TeamsSessionHandoff.decode(credentials.handoff), session.messaging != nil {
                    await accept(session)
                } else {
                    await renew()
                }
            }
        } catch TeamsCredentialError.interactionRequired {
            guard startupGeneration == generation else { return }
            keychainNeedsApproval = true
            self.error = "Unlock the login Keychain in macOS, then choose Retry Saved Sign-in in Settings."
        } catch {
            guard startupGeneration == generation else { return }
            self.error = "Saved sign-in could not be read from Keychain. Open Teams sign-in to continue."
        }
        guard startupGeneration == generation else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--session-pipe"), arguments.indices.contains(index + 1) {
            let current = generation
            do {
                let data = try await SessionPipe.read(arguments[index + 1])
                guard current == generation, !isClearingSignIn, !isConnecting, !checkingWebSession, !loadingCredentials else { return }
                checkingWebSession = true
                defer { checkingWebSession = false }
                let candidate = try TeamsSessionHandoff.decode(data)
                var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let refresh = object.removeValue(forKey: "refreshToken") as? String
                let existing = credentials.flatMap { try? TeamsSessionHandoff.decode($0.handoff, at: .distantPast) }
                let sameIdentity = existing?.accountID == candidate.accountID && existing?.tenantID == candidate.tenantID
                if sameIdentity, let existing, let oldData = credentials?.handoff,
                   let old = try JSONSerialization.jsonObject(with: oldData) as? [String: Any] {
                    if existing.expiresAt > candidate.expiresAt {
                        object["csaBaseURL"] = old["csaBaseURL"]; object["accessToken"] = old["accessToken"]; object["expiresAt"] = old["expiresAt"]
                    }
                    for (key, oldExpiry, newExpiry) in [("messaging", existing.messaging?.expiresAt, candidate.messaging?.expiresAt),
                        ("search", existing.searchSession?.expiresAt, candidate.searchSession?.expiresAt),
                        ("directory", existing.directory?.expiresAt, candidate.directory?.expiresAt)] {
                        if let oldExpiry, oldExpiry > (newExpiry ?? .distantPast) { object[key] = old[key] }
                    }
                }
                let handoff = try JSONSerialization.data(withJSONObject: object)
                let session = try TeamsSessionHandoff.decode(handoff)
                let saved = TeamsCredentials(handoff: handoff, refreshToken: sameIdentity ? (credentials?.refreshToken ?? refresh) : refresh)
                try await credentialStore.save(saved)
                guard current == generation else { return }
                credentials = saved
                credentialRevision = UUID()
                defaults.set(false, forKey: "teamsSignedOut")
                await accept(session)
            } catch { guard current == generation else { return }; self.error = "The browser session could not be connected. Open Teams sign-in to try again." }
        }
    }

    func unlockSavedSignIn() async {
        guard keychainNeedsApproval, !isConnecting, !isClearingSignIn, !checkingWebSession, !loadingCredentials else { return }
        loadingCredentials = true
        let current = generation
        defer { loadingCredentials = false }
        do {
            guard var saved = try await credentialStore.load(interactive: true), current == generation else { return }
            if let pending = pendingFileRotation {
                if saved.handoff == pending.old.handoff && saved.refreshToken == pending.old.refreshToken {
                    do { try await credentialStore.save(pending.updated) }
                    catch TeamsCredentialError.outcomeUnknown {
                        if current == generation { credentialWriteUncertain = true; pendingFileRotation = nil }
                        throw TeamsCredentialError.outcomeUnknown
                    }
                    guard current == generation else { return }
                    saved = pending.updated
                }
                pendingFileRotation = nil
            }
            credentials = saved
            keychainNeedsApproval = false
            if let session = try? TeamsSessionHandoff.decode(saved.handoff), session.messaging != nil { await accept(session) }
            else { loadingCredentials = false; await renew() }
        } catch { guard current == generation else { return }; self.error = "Keychain access was not granted. Your saved chats remain available." }
    }

    func reconcileSavedSignIn() async {
        guard credentialWriteUncertain, !isConnecting, !loadingCredentials, !isClearingSignIn else { return }
        loadingCredentials = true
        let current = generation
        defer { loadingCredentials = false }
        do {
            let saved = try await credentialStore.load(interactive: false)
            guard current == generation else { return }
            credentialWriteUncertain = false
            keychainNeedsApproval = false
            credentials = saved
            if let saved, let session = try? TeamsSessionHandoff.decode(saved.handoff) {
                await accept(session)
            } else { error = "No saved sign-in was found. Connect to Teams to continue." }
        } catch { guard current == generation else { return }; self.error = "Saved sign-in could not be checked. Try again." }
    }

    func openSignIn() {
        guard !isClearingSignIn else { return }
        error = nil
        prepareWebView()
        showSignIn = true
    }

    private func prepareWebView() {
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let safariVersion = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "17.0"
            configuration.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.uiDelegate = self
            webView = view
            view.load(URLRequest(url: URL(string: "https://teams.cloud.microsoft/")!))
        }
    }

    func checkWebSession() async {
        guard !credentialWriteUncertain, !keychainNeedsApproval, !isConnecting, !checkingWebSession, !loadingCredentials, let webView, webView.url?.scheme == "https",
              webView.url?.host == "teams.cloud.microsoft" else { return }
        checkingWebSession = true
        let current = generation
        let revision = credentialRevision
        defer { checkingWebSession = false }
        do {
            guard let json = try await webView.evaluateJavaScript(Self.sessionScript) as? String,
                  let data = json.data(using: .utf8), current == generation, revision == credentialRevision, !isConnecting, !isClearingSignIn, self.webView === webView else { return }
            let candidate = try TeamsSessionHandoff.decode(data)
            guard candidate.messaging != nil else { return }
            let existing = credentials.flatMap { try? TeamsSessionHandoff.decode($0.handoff, at: .distantPast) }
            var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let refresh = object.removeValue(forKey: "refreshToken") as? String
            let sameIdentity = existing?.accountID == candidate.accountID && existing?.tenantID == candidate.tenantID
            if sameIdentity, let existing, let oldData = credentials?.handoff,
               let old = try JSONSerialization.jsonObject(with: oldData) as? [String: Any] {
                if existing.expiresAt > candidate.expiresAt {
                    object["csaBaseURL"] = old["csaBaseURL"]
                    object["accessToken"] = old["accessToken"]
                    object["expiresAt"] = old["expiresAt"]
                }
                let oldResources: [(String, Date?, Date?)] = [
                    ("messaging", existing.messaging?.expiresAt, candidate.messaging?.expiresAt),
                    ("search", existing.searchSession?.expiresAt, candidate.searchSession?.expiresAt),
                    ("directory", existing.directory?.expiresAt, candidate.directory?.expiresAt)
                ]
                if object["directoryBaseURL"] == nil { object["directoryBaseURL"] = old["directoryBaseURL"] }
                for (key, oldExpiry, newExpiry) in oldResources {
                    if let oldExpiry, oldExpiry > (newExpiry ?? .distantPast) { object[key] = old[key] }
                }
            }
            let handoff = try JSONSerialization.data(withJSONObject: object)
            let session = try TeamsSessionHandoff.decode(handoff)
            if sameIdentity, credentials?.refreshToken == nil, let refresh, !refresh.isEmpty {
                let saved = TeamsCredentials(handoff: handoff, refreshToken: refresh)
                try await credentialStore.save(saved)
                guard current == generation else { return }
                credentials = saved; credentialRevision = UUID()
                if !reader.connected { await accept(session) }
                return
            }
            if let existing, !reader.connected, session.accessToken == existing.accessToken,
               session.messaging?.accessToken == existing.messaging?.accessToken, sameIdentity {
                await accept(session)
                return
            }
            guard TeamsSessionSelection.shouldAcceptBrowser(session, replacing: existing, allowAccountSwitch: showSignIn) else { return }
            let saved = TeamsCredentials(handoff: handoff, refreshToken: sameIdentity ? (credentials?.refreshToken ?? refresh) : refresh)
            try await credentialStore.save(saved)
            guard current == generation else { return }
            credentials = saved
            credentialRevision = UUID()
            defaults.set(false, forKey: "teamsSignedOut")
            await accept(session)
        } catch is CancellationError { }
        catch TeamsCredentialError.outcomeUnknown {
            guard current == generation else { return }
            credentialWriteUncertain = true
            self.error = "Saved sign-in may have changed. Check saved sign-in in Settings before trying again."
        } catch TeamsCredentialError.interactionRequired {
            guard current == generation else { return }
            keychainNeedsApproval = true
            self.error = "Unlock the login Keychain in macOS, then choose Retry Saved Sign-in in Settings."
        } catch { }
    }

    func disconnect() {
        refreshCoordinator.reset()
        guard !isClearingSignIn else { return }
        generation = UUID()
        credentialRevision = UUID()
        fileCredentials = [:]; fileAcquisitions = [:]; fileRetryAfter = [:]; pendingFileRotation = nil
        isClearingSignIn = true
        defaults.set(true, forKey: "teamsSignedOut")
        credentialStore.invalidate()
        credentials = nil
        keychainNeedsApproval = false
        credentialWriteUncertain = false
        isConnecting = false
        reader.disconnect()
        expiresAt = nil
        lastToken = ""
        lastMessagingToken = ""
        webView?.stopLoading()
        webView = nil
        showSignIn = false
        Task { [weak self] in
            guard let self else { return }
            do { try await self.credentialStore.delete(); self.error = nil }
            catch { self.error = "Sign-out could not remove credentials from Keychain. They will not be restored; try disconnecting again." }
            await withCheckedContinuation { continuation in self.clearWebData { continuation.resume() } }
            self.isClearingSignIn = false
        }
    }

    func fileCredential(for resource: TeamsSharePointResource, accountID: String, tenantID: String, expectedAccountRevision: UUID) async throws -> TeamsFileCredential {
        guard !Task.isCancelled else { throw CancellationError() }
        guard !credentialWriteUncertain else { throw TeamsFileAuthorizationError.persistenceUncertain }
        guard !keychainNeedsApproval else { throw TeamsFileAuthorizationError.unavailable }
        let requestGeneration = generation
        guard let saved = credentials, let session = try? TeamsSessionHandoff.decode(saved.handoff, at: .distantPast),
              session.accountID == accountID, session.tenantID == tenantID,
              reader.connected, reader.accountScope == tenantID + ":" + accountID, reader.accountRevision == expectedAccountRevision else { throw TeamsFileAuthorizationError.staleAccount }
        let accountRevision = reader.accountRevision
        let cooldownKey = TeamsFileCooldownKey(resource: resource, account: accountID, tenant: tenantID, revision: accountRevision)
        if let cached = fileCredentials[resource], cached.accountID == accountID, cached.tenantID == tenantID,
           cached.accountRevision == accountRevision, cached.expiresAt.timeIntervalSince(now()) > 60 { return cached }
        if let pending = fileAcquisitions[resource] {
            guard pending.account == accountID, pending.tenant == tenantID else { throw TeamsFileAuthorizationError.busy }
            let value = try await waitForFileCredential(pending.task)
            try Task.checkCancellation()
            guard generation == requestGeneration, reader.connected, reader.accountScope == tenantID + ":" + accountID, reader.accountRevision == accountRevision else { throw TeamsFileAuthorizationError.staleAccount }
            return value
        }
        guard now() >= (fileRetryAfter[cooldownKey] ?? .distantPast) else { throw TeamsFileAuthorizationError.throttled }
        guard !isConnecting, !checkingWebSession, !loadingCredentials, !isClearingSignIn else { throw TeamsFileAuthorizationError.busy }
        guard let refresh = saved.refreshToken else { throw TeamsFileAuthorizationError.unavailable }
        isConnecting = true
        let current = generation, revision = credentialRevision, operation = UUID()
        let task = Task { @MainActor [self] () throws -> TeamsFileCredential in
            defer {
                if generation == current { isConnecting = false }
                if fileAcquisitions[resource]?.id == operation { fileAcquisitions[resource] = nil }
            }
            do {
                guard generation == current, revision == credentialRevision, !isClearingSignIn,
                      reader.connected, reader.accountScope == tenantID + ":" + accountID, reader.accountRevision == accountRevision else { throw TeamsFileAuthorizationError.staleAccount }
                let result = try await TeamsTokenRefreshClient(transport: transport).refreshSharePoint(tenantID: tenantID, refreshToken: refresh, resource: resource, at: now())
                let acquired = now()
                guard generation == current, revision == credentialRevision, !isClearingSignIn,
                      reader.connected, reader.accountScope == tenantID + ":" + accountID, reader.accountRevision == accountRevision else { throw TeamsFileAuthorizationError.staleAccount }
                if let rotated = result.refreshToken, !rotated.isEmpty {
                    var updated = saved; updated.refreshToken = rotated
                    do { try await credentialStore.save(updated) }
                    catch TeamsCredentialError.outcomeUnknown {
                        if generation == current, revision == credentialRevision, reader.accountRevision == accountRevision { credentialWriteUncertain = true }
                        throw TeamsFileAuthorizationError.persistenceUncertain
                    }
                    catch TeamsCredentialError.interactionRequired {
                        if generation == current, revision == credentialRevision, reader.accountRevision == accountRevision {
                            pendingFileRotation = (saved, updated); keychainNeedsApproval = true
                        }
                        throw TeamsCredentialError.interactionRequired
                    }
                    catch {
                        if generation == current, revision == credentialRevision, reader.accountRevision == accountRevision { credentialWriteUncertain = true }
                        throw TeamsFileAuthorizationError.persistenceUncertain
                    }
                    guard generation == current, revision == credentialRevision, !isClearingSignIn,
                          reader.connected, reader.accountScope == tenantID + ":" + accountID, reader.accountRevision == accountRevision else { throw TeamsFileAuthorizationError.staleAccount }
                    credentials = updated; credentialRevision = UUID()
                }
                guard let token = result.accessToken, !token.isEmpty, let lifetime = result.expiresIn, lifetime.isFinite, lifetime > 0 else { throw TeamsTokenRefreshError.invalidResponse }
                guard acquired.addingTimeInterval(lifetime) > now() else { throw TeamsTokenRefreshError.invalidResponse }
                let value = TeamsFileCredential(id: UUID(), token: token, resource: resource, accountID: accountID, tenantID: tenantID, accountRevision: accountRevision, connectionGeneration: current,
                                                acquiredAt: acquired, expiresAt: acquired.addingTimeInterval(lifetime), scope: result.scope)
                fileCredentials[resource] = value
                return value
            } catch {
                if generation == current, revision == credentialRevision, reader.accountRevision == accountRevision,
                   case let TeamsTokenRefreshError.http(status, delay) = error, status == 429 {
                    fileRetryAfter[cooldownKey] = now().addingTimeInterval(max(delay ?? 30, 0))
                }
                throw error
            }
        }
        fileAcquisitions[resource] = (operation, accountID, tenantID, task)
        let value = try await waitForFileCredential(task)
        try Task.checkCancellation()
        guard generation == requestGeneration, reader.connected, reader.accountScope == tenantID + ":" + accountID, reader.accountRevision == accountRevision else { throw TeamsFileAuthorizationError.staleAccount }
        return value
    }

    func fileCredential(for attachment: TeamsSharePointAttachment, accountID: String, tenantID: String) async throws -> TeamsFileCredential {
        guard attachment.accountScope == tenantID + ":" + accountID, reader.ownsSharePointAttachment(attachment),
              let resource = attachment.resource else { throw TeamsFileAuthorizationError.staleAccount }
        let credential = try await fileCredential(for: resource, accountID: accountID, tenantID: tenantID, expectedAccountRevision: attachment.accountRevision)
        guard ownsFileCredential(credential, attachment: attachment) else { throw TeamsFileAuthorizationError.staleAccount }
        return credential
    }

    func ownsFileCredential(_ credential: TeamsFileCredential, attachment: TeamsSharePointAttachment) -> Bool {
        generation == credential.connectionGeneration && reader.connected && reader.ownsSharePointAttachment(attachment)
            && attachment.resource == credential.resource && attachment.accountScope == credential.tenantID + ":" + credential.accountID
            && attachment.accountRevision == credential.accountRevision && credential.expiresAt > now()
    }

    func fileMetadata(for attachment: TeamsSharePointAttachment, accountID: String, tenantID: String,
                      client: TeamsSharePointMetadataClient = TeamsSharePointMetadataClient()) async throws -> TeamsSharePointMetadataSummary {
        let credential = try await fileCredential(for: attachment, accountID: accountID, tenantID: tenantID)
        guard ownsFileCredential(credential, attachment: attachment), !Task.isCancelled else { throw TeamsFileAuthorizationError.staleAccount }
        let summary = try await client.read(attachment: attachment, bearer: credential.token)
        guard ownsFileCredential(credential, attachment: attachment), !Task.isCancelled else { throw TeamsFileAuthorizationError.staleAccount }
        return summary
    }

    func filePreview(for attachment: TeamsSharePointAttachment, client: TeamsSharePointContentClient = TeamsSharePointContentClient()) async throws -> Data {
        guard let saved = credentials, let session = try? TeamsSessionHandoff.decode(saved.handoff, at: .distantPast),
              let resource = attachment.resource, reader.ownsSharePointAttachment(attachment) else { throw TeamsFileAuthorizationError.staleAccount }
        let key = TeamsFileCooldownKey(resource: resource, account: session.accountID, tenant: session.tenantID, revision: attachment.accountRevision)
        guard now() >= (fileRetryAfter[key] ?? .distantPast) else { throw TeamsFileAuthorizationError.throttled }
        let credential = try await fileCredential(for: attachment, accountID: session.accountID, tenantID: session.tenantID)
        #if DEBUG
        await filePreviewAfterCredential?()
        #endif
        guard ownsFileCredential(credential, attachment: attachment), !Task.isCancelled else { throw TeamsFileAuthorizationError.staleAccount }
        guard now() >= (fileRetryAfter[key] ?? .distantPast) else { throw TeamsFileAuthorizationError.throttled }
        do {
            let image = try await client.preview(attachment: attachment, bearer: credential.token)
            guard ownsFileCredential(credential, attachment: attachment), !Task.isCancelled else { throw TeamsFileAuthorizationError.staleAccount }
            return image
        } catch {
            if ownsFileCredential(credential, attachment: attachment), case let TeamsMediaError.http(status, delay) = error {
                if status == 429 { fileRetryAfter[key] = now().addingTimeInterval(max(delay ?? 60, 1)) }
                if status == 401, fileCredentials[resource]?.id == credential.id { fileCredentials[resource] = nil }
            }
            throw error
        }
    }

    private func waitForFileCredential(_ task: Task<TeamsFileCredential, Error>) async throws -> TeamsFileCredential {
        let waiter = TeamsFileCredentialWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.continuation = continuation
                if Task.isCancelled { waiter.finish(.failure(CancellationError())); return }
                Task { @MainActor in waiter.finish(await task.result) }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(.failure(CancellationError())) }
        }
    }


    func renew() async {
        guard !credentialWriteUncertain, !keychainNeedsApproval, !isConnecting, !checkingWebSession, !loadingCredentials, !isClearingSignIn, now() >= retryAfter, var saved = credentials else { return }
        guard saved.refreshToken != nil else {
            startWebRecovery(reload: false)
            retryAfter = now().addingTimeInterval(120)
            error = "Teams needs sign-in to renew this session. Open sign-in if it does not reconnect automatically."
            return
        }
        isConnecting = true
        let current = generation
        defer { if current == generation { isConnecting = false } }
        do {
            let old = try TeamsSessionHandoff.decode(saved.handoff, at: .distantPast)
            guard UUID(uuidString: old.tenantID) != nil,
                  var payload = try JSONSerialization.jsonObject(with: saved.handoff) as? [String: Any] else {
                throw TeamsWebClientError.invalidSession
            }
            let deadline = now().addingTimeInterval(300)
            let coreDue = reader.sessionExpired || old.expiresAt < deadline || (old.messaging?.expiresAt ?? .distantPast) < deadline
            var resources: [(String, String)] = coreDue ? [("https://chatsvcagg.teams.microsoft.com/.default", "csa"), ("https://ic3.teams.office.com/.default", "messaging")] : []
            if (old.searchSession?.expiresAt ?? .distantPast) < deadline, now() >= (resourceRetryAfter["search"] ?? .distantPast) {
                resources.append(("https://outlook.office.com//.default", "search"))
            }
            if old.directoryBaseURL != nil, (old.directory?.expiresAt ?? .distantPast) < deadline, now() >= (resourceRetryAfter["directory"] ?? .distantPast) {
                resources.append(("https://api.spaces.skype.com/.default", "directory"))
            }
            for (resource, resourceKey) in resources {
                guard current == generation, let refresh = saved.refreshToken else { return }
                let result: TeamsTokenRefreshResponse
                do {
                    result = try await TeamsTokenRefreshClient(transport: transport).refresh(tenantID: old.tenantID, refreshToken: refresh, resource: resource, at: now())
                } catch {
                    guard current == generation else { return }
                    if error is CancellationError { throw error }
                    let terminal = (error as? TeamsTokenRefreshError) == .interactionRequired
                    if terminal {
                        saved.refreshToken = nil
                        try await credentialStore.save(saved)
                        guard current == generation else { return }
                        credentials = saved
                        credentialRevision = UUID()
                        startWebRecovery(reload: true)
                    }
                    var delay: TimeInterval = 900
                    if case let .http(_, retry)? = error as? TeamsTokenRefreshError { delay = retry ?? delay }
                    if resourceKey == "search" || resourceKey == "directory" {
                        resourceRetryAfter[resourceKey] = now().addingTimeInterval(max(120, delay))
                        if terminal { break }
                        continue
                    }
                    retryAfter = now().addingTimeInterval(max(120, delay))
                    throw error
                }
                let token = result.accessToken
                let lifetime = result.expiresIn
                guard current == generation else { return }
                if let rotated = result.refreshToken, !rotated.isEmpty {
                    saved.refreshToken = rotated
                    try await credentialStore.save(saved)
                    guard current == generation else { return }
                    credentials = saved
                    credentialRevision = UUID()
                }
                let expiration = now().timeIntervalSince1970 + lifetime
                let previousItem = payload[resourceKey]
                if resourceKey == "csa" {
                    payload["accessToken"] = token; payload["expiresAt"] = expiration
                } else if resourceKey == "messaging", var item = payload["messaging"] as? [String: Any] {
                    item["accessToken"] = token; item["expiresAt"] = expiration
                    payload["messaging"] = item
                } else if resourceKey == "search" || resourceKey == "directory" {
                    let route = resourceKey == "search" ? "https://substrate.office.com" : old.directoryBaseURL?.absoluteString
                    guard let route else { continue }
                    var item = payload[resourceKey] as? [String: Any] ?? ["baseURL": route]
                    item["accessToken"] = token; item["expiresAt"] = expiration
                    payload[resourceKey] = item
                } else { throw TeamsWebClientError.invalidSession }
                if resourceKey == "messaging" {
                    let core = try JSONSerialization.data(withJSONObject: payload)
                    let validated = try TeamsSessionHandoff.decode(core)
                    guard validated.accountID == old.accountID, validated.tenantID == old.tenantID else { throw TeamsWebClientError.invalidSession }
                    saved.handoff = core
                    try await credentialStore.save(saved)
                    guard current == generation else { return }
                    credentials = saved
                    credentialRevision = UUID()
                }
                if resourceKey == "search" || resourceKey == "directory" {
                    let trial = try JSONSerialization.data(withJSONObject: payload)
                    if (try? TeamsSessionHandoff.decode(trial, at: .distantPast)) == nil {
                        payload[resourceKey] = previousItem; resourceRetryAfter[resourceKey] = now().addingTimeInterval(900)
                    } else { resourceRetryAfter[resourceKey] = nil }
                }
            }
            let handoff = try JSONSerialization.data(withJSONObject: payload)
            let session = try TeamsSessionHandoff.decode(handoff)
            guard session.accountID == old.accountID, session.tenantID == old.tenantID, current == generation else {
                throw TeamsWebClientError.invalidSession
            }
            saved.handoff = handoff
            try await credentialStore.save(saved)
            guard current == generation else { return }
            credentials = saved
            credentialRevision = UUID()
            retryAfter = .distantPast
            isConnecting = false
            await accept(session)
        } catch {
            guard current == generation else { return }
            if case TeamsCredentialError.outcomeUnknown = error {
                credentialWriteUncertain = true
                self.error = "Saved sign-in may have changed. Check saved sign-in in Settings before trying again."
                return
            }
            if error is TeamsCredentialError {
                keychainNeedsApproval = true
                self.error = "Unlock the login Keychain in macOS, then choose Retry Saved Sign-in in Settings."
                retryAfter = now().addingTimeInterval(900)
                return
            }
            retryAfter = max(retryAfter, now().addingTimeInterval(120))
            self.error = "Teams could not renew your sign-in. Open sign-in if this persists; your cached chats and drafts remain on this Mac."
        }
    }

    private func startWebRecovery(reload: Bool) {
        if let webRecoveryOverride { webRecoveryOverride(); return }
        prepareWebView()
        if reload { webView?.load(URLRequest(url: URL(string: "https://teams.cloud.microsoft/")!)) }
    }

    private func accept(_ session: TeamsWebSession) async {
        guard !isConnecting else { return }
        let current = generation
        isConnecting = true
        defer { if current == generation { isConnecting = false } }
        do {
            let page = try await TeamsWebClient(session: session, transport: transport).chats(pageSize: 1)
            if session.messaging != nil, let chat = page.items.first {
                try await TeamsMessagingClient(session: session, transport: transport).verifyAccess(to: chat.id)
            }
            guard current == generation else { return }
            lastToken = session.accessToken
            lastMessagingToken = session.messaging?.accessToken ?? ""
            expiresAt = min(session.expiresAt, session.messaging?.expiresAt ?? session.expiresAt)
                defaults.set(session.accountID, forKey: "teamsAccountID")
            defaults.set(session.tenantID, forKey: "teamsTenantID")
            defaults.set(session.displayName, forKey: "teamsAccountName")
            await reader.connect(session: session)
            guard current == generation else { return }
            error = nil
            showSignIn = false
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--sharepoint-metadata-proof"), !sharePointProofStarted {
                sharePointProofStarted = true
                Task { await self.runSharePointMetadataProof(session: session) }
            }
            #endif
        } catch {
            guard current == generation else { return }
            self.error = (error as? TeamsWebClientError)?.localizedDescription ?? "The Teams connection could not be verified. Try again."
        }
    }

    #if DEBUG
    private func runSharePointMetadataProof(session: TeamsWebSession) async {
        var result: [String: Any] = ["candidate": false, "route": "site-file-id-metadata", "contentRequested": false]
        if let attachment = await reader.cachedSharePointProofCandidate() {
            result["candidate"] = true
            result["sameOrigin"] = attachment.resource != nil
            result["ownedBefore"] = reader.ownsSharePointAttachment(attachment)
            do {
                let metadata = try await fileMetadata(for: attachment, accountID: session.accountID, tenantID: session.tenantID)
                result["stage"] = "metadata"
                result["status"] = metadata.status
                result["mime"] = metadata.mimeType ?? "unknown"
                result["bytes"] = metadata.byteCount
                result["hasID"] = metadata.hasID; result["hasName"] = metadata.hasName; result["hasFile"] = metadata.hasFile
                result["ownedAfter"] = reader.ownsSharePointAttachment(attachment)
            } catch let failure as TeamsTokenRefreshError {
                result["stage"] = "authorization"
                switch failure {
                case .interactionRequired: result["error"] = "interactionRequired"
                case let .http(status, _): result["httpStatus"] = status
                case .invalidInput: result["error"] = "invalidInput"
                case .invalidResponse: result["error"] = "invalidResponse"
                case .network: result["error"] = "network"
                }
            } catch {
                result["stage"] = "unavailable"
            }
        } else { result["stage"] = "noEligibleCachedAttachment" }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/teams-sharepoint-proof.json"), options: .atomic)
        }
    }
    #endif

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        self.error = "The sign-in page could not load. Check your connection and try again."
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, url.scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private static let sessionScript = #"""
    (() => {
      if (location.origin !== 'https://teams.cloud.microsoft') return null;
      const decode = token => {
        const part = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
        return JSON.parse(decodeURIComponent(Array.from(atob(part), c => '%' + c.charCodeAt(0).toString(16).padStart(2, '0')).join('')));
      };
      for (const key of Object.keys(localStorage)) {
        if (!key.startsWith('msal.2|') || !key.includes('|accesstoken|') || !key.includes('https://chatsvcagg.teams.microsoft.com/')) continue;
        try {
          const token = JSON.parse(localStorage.getItem(key));
          if (token.clientId !== '5e3ce6c0-2b1f-4285-8d4b-75ee78787346' || Number(token.expiresOn) * 1000 <= Date.now() + 30000) continue;
          const claims = decode(token.secret);
          const routes = Object.keys(localStorage).filter(k => k.endsWith('.Discover.DISCOVER-REGION-GTM'));
          const matchingRoutes = routes.filter(k => k.includes(claims.oid));
          const matching = matchingRoutes.length === 1 ? matchingRoutes[0] : null;
          const routeKey = matching;
          if (!routeKey) continue;
          const route = JSON.parse(localStorage.getItem(routeKey)).item;
          let messaging;
          for (const messagingKey of Object.keys(localStorage)) {
            if (!messagingKey.startsWith('msal.2|') || !messagingKey.includes('|accesstoken|') || !/https:\/\/ic3(?:-non-cae)?\.teams\.office\.com/.test(messagingKey)) continue;
            try {
              const candidate = JSON.parse(localStorage.getItem(messagingKey));
              const identity = decode(candidate.secret);
              if (candidate.clientId !== token.clientId || candidate.homeAccountId !== token.homeAccountId || identity.oid !== claims.oid || identity.tid !== claims.tid || Number(candidate.expiresOn) * 1000 <= Date.now() + 30000) continue;
              if (!['https://ic3.teams.office.com', 'https://ic3-non-cae.teams.office.com'].includes(identity.aud.replace(/\/$/, ''))) continue;
              messaging = {baseURL: route.chatServiceAfd, accessToken: candidate.secret, expiresAt: Number(candidate.expiresOn)};
              break;
            } catch (_) {}
          }
          let refreshToken;
          for (const refreshKey of Object.keys(localStorage)) {
            if (!refreshKey.startsWith('msal.2|') || !refreshKey.includes('|refreshtoken|')) continue;
            try {
              const candidate = JSON.parse(localStorage.getItem(refreshKey));
              if (candidate.clientId === token.clientId && candidate.homeAccountId === token.homeAccountId && candidate.secret) {
                refreshToken = candidate.secret; break;
              }
            } catch (_) {}
          }
          const resource = (audience, baseURL) => {
            for (const resourceKey of Object.keys(localStorage)) {
              if (!resourceKey.startsWith('msal.2|') || !resourceKey.includes('|accesstoken|')) continue;
              try {
                const candidate = JSON.parse(localStorage.getItem(resourceKey));
                const identity = decode(candidate.secret);
                if (candidate.clientId !== token.clientId || candidate.homeAccountId !== token.homeAccountId || identity.oid !== claims.oid || identity.tid !== claims.tid || Number(candidate.expiresOn) * 1000 <= Date.now() + 30000) continue;
                if (identity.aud.replace(/\/$/, '') !== audience) continue;
                return {baseURL, accessToken: candidate.secret, expiresAt: Number(candidate.expiresOn)};
              } catch (_) {}
            }
          };
          const search = resource('https://outlook.office.com', 'https://substrate.office.com');
          const directory = resource('https://api.spaces.skype.com', route.middleTier);
          return JSON.stringify({csaBaseURL: route.chatSvcAggAfd, accessToken: token.secret, expiresAt: Number(token.expiresOn), messaging, search, directory, directoryBaseURL: route.middleTier, refreshToken});
        } catch (_) {}
      }
      return null;
    })()
    """#
}

private enum SessionPipe {
    static func read(_ path: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            guard descriptor >= 0 else { throw TeamsWebClientError.invalidSession }
            defer { close(descriptor) }
            var information = stat()
            guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFIFO,
                  information.st_uid == getuid(), information.st_mode & 0o077 == 0 else {
                throw TeamsWebClientError.invalidSession
            }
            var data = Data()
            let deadline = Date().addingTimeInterval(60)
            var buffer = [UInt8](repeating: 0, count: 8192)
            while Date() < deadline {
                try Task.checkCancellation()
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                    guard data.count <= 100_000 else { throw TeamsWebClientError.invalidSession }
                } else if count == 0 && !data.isEmpty { return data }
                else if count < 0 && errno != EAGAIN && errno != EINTR { throw TeamsWebClientError.invalidSession }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw TeamsWebClientError.invalidSession
        }.value
    }
}
