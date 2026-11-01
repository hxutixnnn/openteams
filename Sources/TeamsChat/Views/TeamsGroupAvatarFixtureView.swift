#if DEBUG
import SwiftUI
import Observation
import TeamsCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private actor GroupAvatarFixtureTransport: HTTPTransport {
    var picture: String? = "v1@first"
    var version = 1
    func setPicture(_ value: String?) { picture = value; version += 1 }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let members = [TeamsWebMember(mri: "8:orgid:12345678-1234-1234-1234-123456789aaa", displayName: "Ada"), TeamsWebMember(mri: "8:orgid:12345678-1234-1234-1234-123456789bbb", displayName: "Bob")]
        let chat = TeamsWebChat(id: "fixture", title: "Group avatar fixture", isOneOnOne: false, members: members, picture: picture, pictureMetadataPresent: true, threadVersion: String(version))
        let data = request.url!.path.hasSuffix("/messages") ? try JSONEncoder().encode(TeamsWebMessagePage(messages: [])) : try JSONEncoder().encode(TeamsWebChatPage(items: [chat]))
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private actor GroupAvatarFixtureMedia: TeamsMediaFetching {
    var waitFirst = ProcessInfo.processInfo.arguments.contains("--group-avatar-delay-fixture")
    var continuation: CheckedContinuation<Void, Never>?
    func release() { waitFirst = false; continuation?.resume(); continuation = nil }
    func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let document = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "documentUrl" })?.value
        if document == "first" && waitFirst { await withCheckedContinuation { continuation = $0 } }
        let rgb: (CGFloat, CGFloat, CGFloat) = document == "first" ? (0.1, 0.3, 0.95) : (document == "second" ? (0.9, 0.18, 0.15) : (0.1, 0.7, 0.3))
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let out = NSMutableData(), destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        return (out as Data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
    }
}
@MainActor @Observable private final class GroupAvatarFixtureController {
    let transport = GroupAvatarFixtureTransport()
    let media = GroupAvatarFixtureMedia()
    let store: TeamsReaderStore
    let coordinator: TeamsRefreshCoordinator
    init() {
        let media = self.media
        let store = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("group-avatar-fixture-" + UUID().uuidString), transport: transport, mediaFactory: { try TeamsMediaClient(session: $0, transport: media) })
        self.store = store
        coordinator = TeamsRefreshCoordinator(reader: store, defaults: UserDefaults(suiteName: "group-avatar-fixture-" + UUID().uuidString)!)
    }
    func start() async {
        let account = "12345678-1234-1234-1234-123456789abc", tenant = "12345678-1234-1234-1234-123456789def"
        let claims: [String: Any] = ["aud": "https://api.spaces.skype.com", "oid": account, "tid": tenant, "exp": 4_000_000_000]
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let token = "e30." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
        await store.connect(session: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: account, tenantID: tenant, displayName: "Fixture", directory: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/mt/amer")!, accessToken: token, expiresAt: .distantFuture)))
    }
    func set(_ value: String?) async { await transport.setPicture(value); await store.refreshChats() }
}
struct TeamsGroupAvatarFixtureView: View {
    @ViewState<GroupAvatarFixtureController> private var controller = GroupAvatarFixtureController()
    @ViewState<TeamsNotificationRouter> private var router = TeamsNotificationRouter()
    var body: some View {
        VStack {
            HStack {
                Button("First picture") { Task { await controller.set("v1@first") } }
                Button("Replace picture") { Task { await controller.set("v2@second") } }
                Button("Remove picture") { Task { await controller.set(nil) } }
                Button("Release old picture") { Task { await controller.media.release() } }
            }
            TeamsReadContentView(store: controller.store, refreshCoordinator: controller.coordinator, notificationRouter: router, connect: {}, persistSelection: false)
        }.task { await controller.start() }
    }
}
#endif
