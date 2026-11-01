import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Testing
@testable import TeamsCore

private actor MediaTransportFixture: TeamsMediaFetching {
    let account: String
    let tenant: String
    var requests: [URLRequest] = []
    var unauthorizedOnce = false
    var mismatched = false
    var throttleAuth = false
    var throttleApps = false
    var animated = false
    var imageData: Data?
    var appsData: Data?
    var holdApps = false
    var pendingApps: CheckedContinuation<Void, Never>?
    var appsStarted: CheckedContinuation<Void, Never>?
    var customStatus = 200
    var holdCustom = false
    var pendingCustom: CheckedContinuation<Void, Never>?
    var customStarted: CheckedContinuation<Void, Never>?
    init(account: String, tenant: String) { self.account = account; self.tenant = tenant }
    func setCustomStatus(_ status: Int) { customStatus = status }
    func holdNextCustom() { holdCustom = true }
    func waitForCustom() async { if pendingCustom == nil { await withCheckedContinuation { customStarted = $0 } } }
    func releaseCustom() { pendingCustom?.resume(); pendingCustom = nil }
    func setUnauthorized() { unauthorizedOnce = true }
    func setMismatched() { mismatched = true }
    func setThrottle() { throttleAuth = true }
    func setAppsThrottle() { throttleApps = true }
    func setAnimated() { animated = true }
    func setImageData(_ data: Data) { imageData = data }
    func setAppsData(_ data: Data) { appsData = data }
    func holdNextApps() { holdApps = true }
    func waitForApps() async { if pendingApps == nil { await withCheckedContinuation { appsStarted = $0 } } }
    func releaseApps() { pendingApps?.resume(); pendingApps = nil }
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let isAuth = request.url!.host == "teams.microsoft.com"
        var status = 200
        let data: Data
        if isAuth {
            if throttleAuth { status = 429 }
            let token = try mediaJWT(["skypeid": "orgid:" + (mismatched ? UUID().uuidString : account), "tid": tenant, "exp": Date().timeIntervalSince1970 + 3600])
            data = try JSONSerialization.data(withJSONObject: ["tokens": ["skypeToken": token, "expiresIn": 3600], "regionGtms": ["ams": "https://us-api.asm.skype.com", "other": ["nested": true]]])
        } else if request.url!.path.hasSuffix("/apps/chatentitlements"), let appsData {
            if throttleApps { status = 429 }
            if holdApps {
                holdApps = false
                await withCheckedContinuation { continuation in
                    pendingApps = continuation; appsStarted?.resume(); appsStarted = nil
                }
            }
            data = appsData
        } else {
            if request.url!.path.hasSuffix("/properties/pictureV2") {
                status = customStatus
                if holdCustom {
                    holdCustom = false
                    await withCheckedContinuation { continuation in pendingCustom = continuation; customStarted?.resume(); customStarted = nil }
                }
            }
            if unauthorizedOnce { unauthorizedOnce = false; status = 401 }
            data = imageData ?? Data(base64Encoded: animated ? "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7" : "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII=")!
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": isAuth || request.url!.path.hasSuffix("/apps/chatentitlements") ? "application/json" : (animated ? "image/gif" : "image/png"), "Retry-After": "120"])!)
    }
    func snapshot() -> [URLRequest] { requests }
}

private func mediaJWT(_ claims: [String: Any]) throws -> String {
    let bytes = try JSONSerialization.data(withJSONObject: claims)
    return "e30." + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
}

@Suite struct TeamsMediaTests {
    let account = "12345678-1234-1234-1234-123456789abc"
    let tenant = "12345678-1234-1234-1234-123456789def"
    func session() throws -> TeamsWebSession {
        let expiry = Date().addingTimeInterval(3600)
        let bearer = try mediaJWT(["aud": "https://api.spaces.skype.com", "oid": account, "tid": tenant, "exp": expiry.timeIntervalSince1970])
        return TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "opaque", expiresAt: expiry, accountID: account, tenantID: tenant, displayName: "Test", directory: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/mt/amer")!, accessToken: bearer, expiresAt: expiry))
    }
    @Test func installedAgentsUseScopedAuthAndFilterInstalledFirstBots() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        let body = #"{"type":"fixture","value":{"entitlements":[{"id":"one","state":"Installed","installedVersion":"1"},{"id":"hidden","state":"InstalledAndHidden","entitlementType":"App"},{"id":"notify","state":"Installed","entitlementType":"App"},{"id":"user","state":"AdminPreInstalled","entitlementType":"AgenticUser"}],"definitions":[{"id":"one","name":"Base","bots":[{"id":"base"}]},{"id":"hidden","name":"Hidden","bots":[{"id":"hiddenbot"}]},{"id":"notify","name":"Notifications","bots":[{"id":"notifybot","isNotificationOnly":true}]},{"id":"user","name":"Agentic"}],"installedDefinitions":{"one_1":{"id":"one","name":"First","bots":[{"id":"first"},{"id":"second"}]},"one":{"id":"one","name":"Fallback","bots":[{"id":"fallback"}]}}}}"#
        await transport.setAppsData(Data(body.utf8))
        let client = try TeamsMediaClient(session: session(), transport: transport)
        let agents = try await client.installedAgents(in: "19:fixture@thread.v2")
        #expect(agents.map(\.name) == ["First", "Agentic"])
        #expect(agents.map(\.id) == ["first", "user"])
        let requests = await transport.snapshot()
        #expect(requests.count == 2 && requests[1].url?.host == "teams.cloud.microsoft")
        #expect(requests[1].url?.path.hasSuffix("/apps/chatentitlements") == true)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(requests[1].value(forHTTPHeaderField: "x-skypetoken")?.hasPrefix("e30.") == true)
        await transport.setAppsData(Data("{}".utf8))
        do { _ = try await client.installedAgents(in: "chat"); Issue.record("Expected invalid envelope") } catch { }
    }
    @Test func installedAgentDefinitionFallsBackToIDBeforeBase() throws {
        let body = #"{"value":{"entitlements":[{"id":"one","state":"InstalledAndFavorited","entitlementType":"","installedVersion":"missing"},{"id":"unknown","state":"Installed","entitlementType":"Other"}],"definitions":[{"id":"one","name":"Base","bots":[{"id":"base"}]},{"id":"unknown","name":"Unknown","bots":[{"id":"unknown"}]}],"installedDefinitions":{"one":{"id":"one","name":"Fallback","bots":[{"id":"fallback"}]}}}}"#
        let envelope = try JSONDecoder().decode(TeamsInstalledAppsEnvelope.self, from: Data(body.utf8))
        #expect(envelope.agents().map(\.name) == ["Fallback"])
    }
    @Test(arguments: [false, true]) func delayedInstalledAgentsDiscardedAfterRenewalOrDisconnect(disconnect: Bool) async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        await transport.setAppsData(Data(#"{"value":{"entitlements":[],"definitions":[]}}"#.utf8))
        await transport.holdNextApps()
        let initial = try session()
        let client = try TeamsMediaClient(session: initial, transport: transport)
        let pending = Task { try await client.installedAgents(in: "fixture") }
        await transport.waitForApps()
        if disconnect {
            await client.invalidate()
        } else {
            let expiry = Date().addingTimeInterval(3600)
            let bearer = try mediaJWT(["aud": "https://api.spaces.skype.com", "oid": account, "tid": tenant, "exp": expiry.timeIntervalSince1970, "fixture": "renewed"])
            let renewed = TeamsWebSession(baseURL: initial.baseURL, accessToken: initial.accessToken, expiresAt: expiry, accountID: account, tenantID: tenant, displayName: "Test", directory: .init(baseURL: initial.directory!.baseURL, accessToken: bearer, expiresAt: expiry))
            try await client.update(session: renewed)
        }
        await transport.releaseApps()
        do { _ = try await pending.value; Issue.record("Expected stale read cancellation") } catch is CancellationError { } catch { Issue.record("Unexpected error") }
    }
    @Test func installedAgentRetryHonorsMediaCooldown() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        await transport.setAppsData(Data())
        await transport.setAppsThrottle()
        let client = try TeamsMediaClient(session: session(), transport: transport)
        for _ in 0..<2 {
            do { _ = try await client.installedAgents(in: "fixture"); Issue.record("Expected throttle") }
            catch let TeamsMediaError.http(status, _) { #expect(status == 429) }
        }
        #expect(await transport.snapshot().count == 2)
    }
    @Test func mediaReadUsesDiscoveredHostAndRefreshesOnceAfterUnauthorized() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        await transport.setUnauthorized()
        let client = try TeamsMediaClient(session: session(), transport: transport)
        _ = try await client.image(at: URL(string: "https://us-api.asm.skype.com/v1/objects/example/views/imgo")!)
        _ = try await client.image(at: URL(string: "https://us-api.asm.skype.com/v1/objects/example/views/imgo")!)
        let requests = await transport.snapshot()
        #expect(requests.count == 4)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization")?.hasPrefix("skype_token ") == true)
    }
    @Test func mismatchedIdentityAndUntrustedHostsNeverReceiveMediaCredentials() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        await transport.setMismatched()
        let client = try TeamsMediaClient(session: session(), transport: transport)
        do { _ = try await client.image(at: URL(string: "https://us-api.asm.skype.com/v1/objects/example/views/imgo")!); Issue.record("Expected rejection") } catch { }
        #expect(await transport.snapshot().count == 1)
        #expect(!TeamsMediaClient.isAllowed(URL(string: "https://attacker.example/v1/objects/example/views/imgo")!, hosts: ["us-api.asm.skype.com"]))
        #expect(!TeamsMediaClient.isAllowed(URL(string: "https://us-api.asm.skype.com/v1/objects/example/views/imgo?token=secret")!, hosts: ["us-api.asm.skype.com"]))
        #expect(TeamsMediaClient.isAllowed(URL(string: "https://us-api.asm.skype.com/v1/objects/example/views/imgo?v=1")!, hosts: ["us-api.asm.skype.com"]))
        #expect(!TeamsMediaClient.validImage(Data("not an image".utf8)))
    }
    @Test func profilePhotoUsesDirectoryOriginAndCachesWithinSession() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        let client = try TeamsMediaClient(session: session(), transport: transport)
        _ = try await client.profilePhoto(for: "8:orgid:" + account)
        _ = try await client.profilePhoto(for: account)
        let requests = await transport.snapshot()
        #expect(requests.count == 1)
        #expect(requests[0].url?.host == "teams.cloud.microsoft")
        #expect(requests[0].url?.path.contains("/api/mt/amer/beta/users/") == true)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        do { _ = try await client.profilePhoto(for: "attacker.example"); Issue.record("Expected rejection") } catch { }
        #expect(await transport.snapshot().count == 1)
    }
    @Test func authThrottlePreservesStatusAndPreventsImmediateRetry() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        await transport.setThrottle()
        let client = try TeamsMediaClient(session: session(), transport: transport)
        for _ in 0..<2 {
            do { _ = try await client.image(at: URL(string: "https://us-api.asm.skype.com/v1/objects/example/views/imgo")!); Issue.record("Expected throttle") }
            catch let TeamsMediaError.http(status, delay) { #expect(status == 429); #expect((delay ?? 0) > 100) }
            catch { Issue.record("Unexpected error") }
        }
        #expect(await transport.snapshot().count == 1)
    }
    @Test func animatedGIFRetainsItsFrames() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        await transport.setAnimated()
        let client = try TeamsMediaClient(session: session(), transport: transport)
        let data = try await client.image(at: URL(string: "https://us-api.asm.skype.com/v1/objects/example/views/imgo")!)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
    }
    @Test func fullSizeUsesSeparateValidatedRenditionAndCache() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        let client = try TeamsMediaClient(session: session(), transport: transport)
        let url = URL(string: "https://us-api.asm.skype.com/v1/objects/example/views/imgo?v=1")!
        _ = try await client.image(at: url)
        _ = try await client.image(at: url, fullSize: true)
        _ = try await client.image(at: url, fullSize: true)
        let requests = await transport.snapshot()
        #expect(requests.count == 3)
        #expect(requests[2].url?.path == "/v1/objects/example/views/imgpsh_fullsize")
        #expect(requests[2].url?.query == "v=1")
        do { _ = try await client.image(at: URL(string: "https://attacker.example/v1/objects/example/views/imgo")!, fullSize: true); Issue.record("Expected rejection") } catch { }
        #expect(await transport.snapshot().count == 3)
    }
    @Test func fullSizeRetainsMorePixelsThanInline() async throws {
        let context = try #require(CGContext(data: nil, width: 2000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1500))
        let source = try #require(context.makeImage())
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        #expect(CGImageDestinationFinalize(destination))
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        await transport.setImageData(encoded as Data)
        let client = try TeamsMediaClient(session: session(), transport: transport)
        let url = URL(string: "https://us-api.asm.skype.com/v1/objects/example/views/imgo")!
        let inline = try await client.image(at: url)
        let full = try await client.image(at: url, fullSize: true)
        let inlineSource = try #require(CGImageSourceCreateWithData(inline as CFData, nil))
        let fullSource = try #require(CGImageSourceCreateWithData(full as CFData, nil))
        let inlineImage = try #require(CGImageSourceCreateImageAtIndex(inlineSource, 0, nil))
        let fullImage = try #require(CGImageSourceCreateImageAtIndex(fullSource, 0, nil))
        #expect(inlineImage.width == 1200)
        #expect(fullImage.width == 2000)
        #expect(fullImage.height == 1500)
    }
    @Test func customGroupPictureUsesTrustedRouteAndVersionedIdentity() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        let client = try TeamsMediaClient(session: session(), transport: transport)
        let members = [TeamsWebMember(mri: "8:orgid:12345678-1234-1234-1234-123456789aaa", displayName: "A", avatarETag: "one"),
                       TeamsWebMember(mri: "8:orgid:12345678-1234-1234-1234-123456789bbb", displayName: "B")]
        let chat = "19:group/one@thread.v2", picture = "version@https://untrusted.example/photo?a=1+2"
        _ = try await client.groupPhoto(for: members, chatID: chat, picture: picture, pictureVersion: "1")
        _ = try await client.groupPhoto(for: members, chatID: chat, picture: picture, pictureVersion: "1")
        var requests = await transport.snapshot()
        #expect(requests.count == 1 && requests[0].url?.host == "teams.cloud.microsoft")
        #expect(requests[0].url?.absoluteString.contains("19%3Agroup%2Fone%40thread.v2/properties/pictureV2") == true)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "documentUrl" })?.value == "https://untrusted.example/photo?a=1+2")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        _ = try await client.groupPhoto(for: members, chatID: chat, picture: picture, pictureVersion: "2")
        _ = try await client.groupPhoto(for: members, chatID: chat, picture: "version@replacement", pictureVersion: "2")
        let changed = [TeamsWebMember(mri: members[0].mri, displayName: "A", avatarETag: "two"), members[1]]
        _ = try await client.groupPhoto(for: changed, chatID: chat, picture: "version@replacement", pictureVersion: "2")
        _ = try await client.groupPhoto(for: changed, chatID: chat, picture: nil, pictureVersion: "2")
        _ = try await client.groupPhoto(for: changed, chatID: "other", picture: nil, pictureVersion: "2")
        requests = await transport.snapshot()
        #expect(requests.count == 6)
        #expect(requests[4].url?.path.hasSuffix("/mergedProfilePicturev2") == true)
        #expect(requests.allSatisfy { $0.url?.host == "teams.cloud.microsoft" })
    }
    @Test func customGroupFailureFallsBackButAuthAndCancellationDoNot() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        let members = [TeamsWebMember(mri: "8:orgid:12345678-1234-1234-1234-123456789aaa", displayName: "A"), TeamsWebMember(mri: "8:orgid:12345678-1234-1234-1234-123456789bbb", displayName: "B")]
        let client = try TeamsMediaClient(session: session(), transport: transport)
        await transport.setCustomStatus(404)
        _ = try await client.groupPhoto(for: members, chatID: "chat", picture: "v@doc")
        #expect(await transport.snapshot().count == 2)
        let authTransport = MediaTransportFixture(account: account, tenant: tenant)
        await authTransport.setCustomStatus(401)
        let authClient = try TeamsMediaClient(session: session(), transport: authTransport)
        do { _ = try await authClient.groupPhoto(for: members, chatID: "chat", picture: "v@doc"); Issue.record("Expected 401") } catch {}
        #expect(await authTransport.snapshot().count == 1)
        let delayed = MediaTransportFixture(account: account, tenant: tenant)
        await delayed.holdNextCustom()
        let delayedClient = try TeamsMediaClient(session: session(), transport: delayed)
        let task = Task { try await delayedClient.groupPhoto(for: members, chatID: "chat", picture: "v@doc") }
        await delayed.waitForCustom(); task.cancel(); await delayedClient.invalidate(); await delayed.releaseCustom()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch {}
        #expect(await delayed.snapshot().count == 1)
    }

    @Test func customGroupPicturesAreIsolatedByAccount() async throws {
        let otherAccount = "12345678-1234-1234-1234-123456789999"
        let expiry = Date().addingTimeInterval(3600)
        let otherToken = try mediaJWT(["aud": "https://api.spaces.skype.com", "oid": otherAccount, "tid": tenant, "exp": expiry.timeIntervalSince1970])
        let otherSession = TeamsWebSession(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "opaque", expiresAt: expiry, accountID: otherAccount, tenantID: tenant, displayName: "Other", directory: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/mt/amer")!, accessToken: otherToken, expiresAt: expiry))
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        let first = try TeamsMediaClient(session: session(), transport: transport)
        let second = try TeamsMediaClient(session: otherSession, transport: transport)
        _ = try await first.groupPhoto(for: [], chatID: "same-chat", picture: "v@doc")
        _ = try await second.groupPhoto(for: [], chatID: "same-chat", picture: "v@doc")
        let requests = await transport.snapshot()
        #expect(requests.count == 2)
        #expect(requests[0].url?.path.contains(account) == true)
        #expect(requests[1].url?.path.contains(otherAccount) == true)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") != requests[1].value(forHTTPHeaderField: "Authorization"))
    }

    @Test func groupPhotoUsesTwoOtherParticipantsOnDirectoryOrigin() async throws {
        let transport = MediaTransportFixture(account: account, tenant: tenant)
        let client = try TeamsMediaClient(session: session(), transport: transport)
        let members = [TeamsWebMember(mri: "8:orgid:" + account, displayName: "Self"),
                       TeamsWebMember(mri: "28:bot", objectId: "12345678-1234-1234-1234-123456789ccc", displayName: "0 Bot"),
                       TeamsWebMember(mri: "8:orgid:12345678-1234-1234-1234-123456789aaa", displayName: "A"),
                       TeamsWebMember(mri: "8:orgid:12345678-1234-1234-1234-123456789bbb", displayName: "B")]
        _ = try await client.groupPhoto(for: members)
        let requests = await transport.snapshot()
        #expect(requests.count == 1)
        #expect(requests[0].url?.host == "teams.cloud.microsoft")
        #expect(requests[0].url?.path.hasSuffix("/mergedProfilePicturev2") == true)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        let info = query?.first(where: { $0.name == "usersInfo" })?.value ?? ""
        #expect(!info.contains(account))
        #expect(!info.contains("123456789ccc"))
        #expect(info.contains("123456789aaa") && info.contains("123456789bbb"))
    }
}

private actor DelayedMediaTransport: TeamsMediaFetching {
    let account: String
    let tenant: String
    var continuation: CheckedContinuation<Void, Never>?
    var calls = 0
    init(account: String, tenant: String) { self.account = account; self.tenant = tenant }
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        let token = try mediaJWT(["skypeid": "orgid:" + account, "tid": tenant, "exp": Date().timeIntervalSince1970 + 3600])
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["skypeToken": token, "expiresIn": 3600], "regionGtms": ["ams": "https://us-api.asm.skype.com"]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
    func isWaiting() -> Bool { continuation != nil }
    func resume() { continuation?.resume(); continuation = nil }
}

extension TeamsMediaTests {
    @Test func cancelledImageLoadDoesNotSendImageRequestAfterDelayedAuthorization() async throws {
        let transport = DelayedMediaTransport(account: account, tenant: tenant)
        let client = try TeamsMediaClient(session: session(), transport: transport)
        let task = Task { try await client.image(at: URL(string: "https://us-api.asm.skype.com/v1/objects/example/views/imgo")!) }
        while !(await transport.isWaiting()) { await Task.yield() }
        task.cancel()
        await client.invalidate()
        await transport.resume()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError { } catch { Issue.record("Unexpected error") }
        #expect(await transport.calls == 1)
    }
}

private actor RacingMediaTransport: TeamsMediaFetching {
    let account: String
    let tenant: String
    var authCount = 0
    var firstWave: [String: CheckedContinuation<Void, Never>] = [:]
    var attempts: [String: Int] = [:]
    init(account: String, tenant: String) { self.account = account; self.tenant = tenant }
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.host == "teams.microsoft.com" {
            authCount += 1
            let base = try mediaJWT(["skypeid": "orgid:" + account, "tid": tenant, "exp": Date().timeIntervalSince1970 + 3600])
            let data = try JSONSerialization.data(withJSONObject: ["tokens": ["skypeToken": base + String(authCount), "expiresIn": 3600], "regionGtms": ["ams": "https://us-api.asm.skype.com"]])
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }
        let key = url.path.contains("/one/") ? "one" : "two"
        attempts[key, default: 0] += 1
        let first = attempts[key] == 1
        if first { await withCheckedContinuation { firstWave[key] = $0 } }
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII=")!
        return (data, HTTPURLResponse(url: url, statusCode: first ? 401 : 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
    }
    func ready() -> Bool { firstWave.count == 2 }
    func release(_ key: String) { firstWave.removeValue(forKey: key)?.resume() }
}

extension TeamsMediaTests {
    @Test func lateUnauthorizedFromOldTokenDoesNotDiscardNewToken() async throws {
        let transport = RacingMediaTransport(account: account, tenant: tenant)
        let client = try TeamsMediaClient(session: session(), transport: transport)
        let one = Task { try await client.image(at: URL(string: "https://us-api.asm.skype.com/v1/objects/one/views/imgo")!) }
        let two = Task { try await client.image(at: URL(string: "https://us-api.asm.skype.com/v1/objects/two/views/imgo")!) }
        while !(await transport.ready()) { await Task.yield() }
        await transport.release("one")
        while await transport.authCount < 2 { await Task.yield() }
        _ = try await one.value
        await transport.release("two")
        _ = try await two.value
        #expect(await transport.authCount == 2)
    }
}

private struct EmptyChatTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(#"{"items":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}

extension TeamsMediaTests {
    @MainActor @Test func readerRejectsDelayedMediaAfterAccountChange() async throws {
        let transport = DelayedMediaTransport(account: account, tenant: tenant)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TeamsReaderStore(cacheRoot: root, transport: EmptyChatTransport(), mediaFactory: { session in
            try TeamsMediaClient(session: session, transport: transport)
        })
        await store.connect(session: try session())
        let body = TeamsBodyParser.parse("<img src='https://us-api.asm.skype.com/v1/objects/example/views/imgo'>")
        let image = try #require(body.blocks.first?.image)
        let task = Task { try await store.imageData(for: image) }
        while !(await transport.isWaiting()) { await Task.yield() }
        await store.restoreAccount(accountID: "12345678-1234-1234-1234-123456789ccc", tenantID: tenant, displayName: "Other")
        await transport.resume()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError { } catch { Issue.record("Unexpected error") }
        #expect(await transport.calls == 1)
    }
}

private actor ThrottledQueueTransport: TeamsMediaFetching {
    var waiting: [Int: CheckedContinuation<Int, Never>] = [:]
    var calls = 0
    var peak = 0
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        let id = calls
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            waiting[id] = continuation
            peak = max(peak, waiting.count)
        }
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII=")!
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                     headerFields: ["Content-Type": "image/png", "Retry-After": "7200"])!)
    }
    func countWaiting() -> Int { waiting.count }
    func release(_ id: Int, status: Int) { waiting.removeValue(forKey: id)?.resume(returning: status) }
}

extension TeamsMediaTests {
    @Test func throttleBlocksQueuedReadsBeforeReleasingSlot() async throws {
        let transport = ThrottledQueueTransport()
        let client = try TeamsMediaClient(session: session(), transport: transport)
        let tasks = (1...5).map { i in Task {
            try await client.profilePhoto(for: String(format: "12345678-1234-1234-1234-%012d", i))
        } }
        while await transport.countWaiting() < 4 { await Task.yield() }
        await transport.release(1, status: 429)
        while await transport.countWaiting() > 3 { await Task.yield() }
        for id in 2...4 { await transport.release(id, status: 200) }
        var throttled = 0
        for task in tasks {
            do { _ = try await task.value }
            catch let TeamsMediaError.http(status, delay) { if status == 429 && (delay ?? 0) > 7100 { throttled += 1 } }
            catch { Issue.record("Unexpected error") }
        }
        #expect(throttled == 2)
        #expect(await transport.calls == 4)
        #expect(await transport.peak == 4)
    }
}

private actor GroupMetadataTransport: HTTPTransport {
    var list = #"{"id":"group","isOneOnOne":false,"threadVersion":1}"#
    var detail = #"{"id":"group","picture":"v1@first","threadVersion":1}"#
    var status = 200
    var reads = 0
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    func configure(list: String? = nil, detail: String? = nil, status: Int? = nil, hold: Bool? = nil) {
        if let list { self.list = list }; if let detail { self.detail = detail }
        if let status { self.status = status }; if let hold { self.hold = hold }
    }
    func release() { pending?.resume(); pending = nil }
    func waiting() -> Bool { pending != nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        var response = "{}", code = 200
        if path.hasSuffix("/teams/users/me/chats/group") {
            reads += 1; response = detail; code = status
            if hold { hold = false; await withCheckedContinuation { pending = $0 } }
        } else if path.hasSuffix("/teams/users/me/chats") { response = "{\"items\":[\(list)]}" }
        else { response = #"{"items":[]}"# }
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Retry-After":"120"])!)
    }
}

extension TeamsMediaTests {
    @MainActor private func metadataStore(_ transport: GroupMetadataTransport) -> TeamsReaderStore {
        TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: transport,
                         mediaFactory: { session in try TeamsMediaClient(session: session, transport: MediaTransportFixture(account: account, tenant: tenant)) })
    }
    @MainActor private func waitFor(_ predicate: @MainActor () async -> Bool) async {
        for _ in 0..<10000 { if await predicate() { return }; await Task.yield() }
        Issue.record("Timed out waiting for metadata fixture")
    }
    @MainActor @Test func metadataDetailCannotOverwriteNewerListPictureOrRemoval() async throws {
        for replacement in [#""v2@new""#, "null"] {
            let transport = GroupMetadataTransport(), store = metadataStore(transport)
            await transport.configure(hold: true); await store.connect(session: try session()); await store.loadConversation("group")
            await waitFor { await transport.waiting() }
            await transport.configure(list: "{\"id\":\"group\",\"isOneOnOne\":false,\"threadVersion\":2,\"picture\":\(replacement)}")
            await store.refreshChats(); await transport.release()
            for _ in 0..<100 { await Task.yield() }
            #expect(store.conversation("group")?.picture == (replacement == "null" ? nil : "v2@new"))
        }
    }
    @MainActor @Test func metadataRenewalAndVersionChangesPermitFreshReads() async throws {
        let transport = GroupMetadataTransport(), store = metadataStore(transport)
        await transport.configure(hold: true); await store.connect(session: try session()); await store.loadConversation("group")
        await waitFor { await transport.waiting() }
        await store.connect(session: try session()); await transport.release()
        await store.loadConversation("group")
        await waitFor { store.conversation("group")?.picture == "v1@first" }
        #expect(await transport.reads == 2)
        await transport.configure(list: #"{"id":"group","isOneOnOne":false,"threadVersion":2}"#, detail: #"{"id":"group","picture":"v2@second","threadVersion":2}"#)
        await store.refreshChats(); await store.loadConversation("group")
        await waitFor { store.conversation("group")?.picture == "v2@second" }
        await transport.configure(list: #"{"id":"group","isOneOnOne":false,"threadVersion":3}"#, detail: #"{"id":"group","picture":null,"threadVersion":3}"#)
        await store.refreshChats(); await store.loadConversation("group")
        await waitFor { store.conversation("group")?.picture == nil }
        #expect(await transport.reads == 4)
    }
    @MainActor @Test func metadataThrottleBlocksRepeatedSelection() async throws {
        let transport = GroupMetadataTransport(), store = metadataStore(transport)
        await transport.configure(status: 429); await store.connect(session: try session()); await store.loadConversation("group")
        await waitFor { store.retryNotBefore != nil }
        await store.loadConversation("group"); await store.loadConversation("group")
        for _ in 0..<100 { await Task.yield() }
        #expect(await transport.reads == 1)
    }
    @MainActor @Test func absentMetadataWithDifferentDetailVersionStaysFresh() async throws {
        let transport = GroupMetadataTransport(), store = metadataStore(transport)
        await transport.configure(detail: #"{"id":"group","threadVersion":2}"#)
        await store.connect(session: try session()); await store.loadConversation("group")
        await waitFor { await transport.reads == 1 }
        for _ in 0..<100 { await Task.yield() }
        await store.loadConversation("group"); await store.loadConversation("group")
        for _ in 0..<100 { await Task.yield() }
        #expect(await transport.reads == 1)
        #expect(store.conversation("group")?.pictureMetadataPresent == false)
        #expect(store.conversation("group")?.threadVersion == "1")
    }
}


private actor SharePointMetadataTransport: TeamsMediaFetching {
    var requests: [URLRequest] = []
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data = Data(#"{"id":"item","name":"file.pdf","file":{}}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!)
    }
}

extension TeamsMediaTests {
    @Test func sharePointMetadataUsesExactAttachmentOriginAndEscapedIdentity() async throws {
        let transport = SharePointMetadataTransport()
        let attachment = TeamsSharePointAttachment(baseURL: URL(string:"https://example.sharepoint.com/sites/team")!, objectURL: URL(string:"https://example.sharepoint.com/sites/team/file.pdf")!, fileID: "item/with?#", accountScope: "tenant:account", accountRevision: UUID(), chatID: "chat", messageID: "message")
        let summary = try await TeamsSharePointMetadataClient(transport: transport).read(attachment: attachment, bearer: "opaque")
        let requests = await transport.requests
        #expect(requests.count == 1 && requests[0].url?.host == "example.sharepoint.com")
        #expect(requests[0].url?.absoluteString.contains("items/item%2Fwith%3F%23/driveItem/") == true)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer opaque")
        #expect(summary.status == 200 && summary.hasID && summary.hasName && summary.hasFile)
        #expect(summary.byteCount > 0 && summary.mimeType == "application/json")
    }
}

private actor SharePointContentTransport: TeamsMediaFetching {
    var requests: [URLRequest] = []
    var status = 200
    var data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII=")!
    var mime = "image/png"
    var pending: CheckedContinuation<Void, Never>?
    var hold = false
    func configure(status: Int = 200, hold: Bool = false, data: Data? = nil, mime: String? = nil) { self.status = status; self.hold = hold; if let data { self.data = data }; if let mime { self.mime = mime } }
    func waiting() -> Bool { pending != nil }
    func release() { pending?.resume(); pending = nil }
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if hold { hold = false; await withCheckedContinuation { pending = $0 } }
        guard data.count <= limit else { throw TeamsMediaError.tooLarge }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":mime, "Retry-After":"120"])!)
    }
}

extension TeamsMediaTests {
    private func fileAttachment(_ object: String) -> TeamsSharePointAttachment {
        TeamsSharePointAttachment(baseURL: URL(string:"https://example.sharepoint.com/sites/team")!, objectURL: URL(string: object)!, fileID: "file", accountScope: "tenant:account", accountRevision: UUID(), chatID: "chat", messageID: "message")
    }
    @Test func fileContentPathEncodesOnceAndRejectsAmbiguity() async throws {
        let transport = SharePointContentTransport(), client = TeamsSharePointContentClient(transport: transport)
        let attachment = fileAttachment("https://example.sharepoint.com/sites/team/O%27Brien%20%2B%20%C3%81.png")
        let image = try await client.preview(attachment: attachment, bearer: "opaque")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.host == "example.sharepoint.com")
        #expect(request.url?.path.contains("/_api/web/GetFileByServerRelativeUrl(@a1)/$value") == true)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first?.value == "'/sites/team/O''Brien + Á.png'")
        #expect(components.percentEncodedQuery?.contains("%2B") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer opaque")
        #expect(!image.isEmpty)
        for suffix in ["percent%25.png", "hash%23.png", "slash%2Fname.png", "_api/evil.png", "document.docx"] {
            do { _ = try await client.preview(attachment: fileAttachment("https://example.sharepoint.com/sites/team/" + suffix), bearer: "opaque"); Issue.record("Ambiguous path accepted") } catch {}
        }
        #expect(await transport.requests.count == 1)
    }
    @Test func fileContentRejectsThrottleOversizeAndCancellation() async throws {
        let transport = SharePointContentTransport(), client = TeamsSharePointContentClient(transport: transport)
        let attachment = fileAttachment("https://example.sharepoint.com/sites/team/file.png")
        await transport.configure(status: 429)
        do { _ = try await client.preview(attachment: attachment, bearer: "opaque"); Issue.record("Expected throttle") } catch let TeamsMediaError.http(status, delay) { #expect(status == 429 && delay == 120) } catch { Issue.record("Unexpected error") }
        await transport.configure(data: Data(repeating: 0, count: 8_000_001))
        do { _ = try await client.preview(attachment: attachment, bearer: "opaque"); Issue.record("Oversize accepted") } catch {}
        let delayed = SharePointContentTransport(); await delayed.configure(hold: true)
        let delayedClient = TeamsSharePointContentClient(transport: delayed)
        let task = Task { try await delayedClient.preview(attachment: attachment, bearer: "opaque") }
        while !(await delayed.waiting()) { await Task.yield() }
        task.cancel(); await delayed.release()
        do { _ = try await task.value; Issue.record("Cancelled read published") } catch is CancellationError {} catch { Issue.record("Unexpected error") }
    }
    @Test func pdfPreviewValidatesTypeStructureAndPageBounds() async throws {
        func pdf(pages: Int, width: CGFloat = 612) throws -> Data {
            let bytes = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: bytes))
            var box = CGRect(x: 0, y: 0, width: width, height: 792)
            let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
            context.closePDF()
            return bytes as Data
        }
        let transport = SharePointContentTransport(), client = TeamsSharePointContentClient(transport: transport)
        let attachment = fileAttachment("https://example.sharepoint.com/sites/team/file.pdf")
        let valid = try pdf(pages: 2)
        await transport.configure(data: valid, mime: "application/pdf")
        #expect(try await client.preview(attachment: attachment, bearer: "opaque") == valid)
        await transport.configure(data: Data("%PDF-invalid".utf8), mime: "application/pdf")
        do { _ = try await client.preview(attachment: attachment, bearer: "opaque"); Issue.record("Malformed PDF accepted") } catch {}
        await transport.configure(data: valid, mime: "image/png")
        do { _ = try await client.preview(attachment: attachment, bearer: "opaque"); Issue.record("Wrong MIME accepted") } catch {}
        await transport.configure(data: try pdf(pages: 101), mime: "application/pdf")
        do { _ = try await client.preview(attachment: attachment, bearer: "opaque"); Issue.record("Too many PDF pages accepted") } catch {}
        await transport.configure(data: try pdf(pages: 1, width: 15000), mime: "application/pdf")
        do { _ = try await client.preview(attachment: attachment, bearer: "opaque"); Issue.record("Oversized PDF page accepted") } catch {}
        await transport.configure(status: 429, data: valid, mime: "application/pdf")
        do { _ = try await client.preview(attachment: attachment, bearer: "opaque"); Issue.record("Throttled PDF accepted") } catch let TeamsMediaError.http(status, delay) { #expect(status == 429 && delay == 120) } catch { Issue.record("Unexpected PDF throttle error") }
        let delayed = SharePointContentTransport(); await delayed.configure(hold: true, data: valid, mime: "application/pdf")
        let task = Task { try await TeamsSharePointContentClient(transport: delayed).preview(attachment: attachment, bearer: "opaque") }
        while !(await delayed.waiting()) { await Task.yield() }
        task.cancel(); await delayed.release()
        do { _ = try await task.value; Issue.record("Cancelled PDF published") } catch is CancellationError {} catch { Issue.record("Unexpected PDF cancellation error") }
    }
}
