#if DEBUG
import AppKit
import Observation
import SwiftUI
import TeamsCore

@MainActor enum TeamsPerformanceFixtureConfiguration {
    static let enabled = Bundle.main.object(forInfoDictionaryKey: "OpenTeamsPerformanceFixtureRoot") != nil || ProcessInfo.processInfo.arguments.contains("--performance-fixture")
    static let startupConversation = PerformanceFixtureStartupConversation(rawValue: Bundle.main.object(forInfoDictionaryKey: "OpenTeamsFixtureStartupConversation") as? String ?? "project") ?? .project
    static let defaults = UserDefaults(suiteName: "OpenTeams.performance-fixture." + UUID().uuidString)!
    static let appearance = TeamsPerformanceFixtureAppearanceState()
    static let root: URL? = {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "OpenTeamsPerformanceFixtureRoot") as? String else { return nil }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard root.path.hasPrefix(temporary.path + "/"),
              root.lastPathComponent.hasPrefix("openteams-app-e2e-"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.json").path) else { return nil }
        return root
    }()
}

@MainActor @Observable final class TeamsPerformanceFixtureAppearanceState {
    var selection = "System"
    var colorScheme: ColorScheme? { selection == "Dark" ? .dark : selection == "Light" ? .light : nil }
}

struct TeamsPerformanceFixtureAppearance: ViewModifier {
    @Bindable private var appearance = TeamsPerformanceFixtureConfiguration.appearance

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}

@MainActor @Observable private final class PerformanceFixtureController {
    let store: TeamsReaderStore
    let coordinator: TeamsRefreshCoordinator
    let gate: TeamsCachedLoadGate?
    private let transport: PerformanceFixtureTransport
    private let cacheRoot: URL
    private(set) var busy = false
    private(set) var ready = false

    init(root: URL) {
        gate = Bundle.main.object(forInfoDictionaryKey: "OpenTeamsCachedLoadHoldEnabled") as? Bool == true
            ? TeamsCachedLoadGate(traceURL: root.appendingPathComponent("cached-load-trace.jsonl")) : nil
        transport = PerformanceFixtureTransport(allowsSend: Bundle.main.object(forInfoDictionaryKey: "OpenTeamsFictionalSendEnabled") as? Bool == true, gate: gate,
            sendOutcome: PerformanceFixtureTransport.SendOutcome(rawValue: Bundle.main.object(forInfoDictionaryKey: "OpenTeamsFixtureSendOutcome") as? String ?? "accepted") ?? .accepted,
            sendDelay: Bundle.main.object(forInfoDictionaryKey: "OpenTeamsFixtureSendDelay") as? Double ?? 0,
            sendObservationURL: root.appendingPathComponent("send-observation.json"))
        cacheRoot = root.appendingPathComponent("ReadCache")
        store = TeamsReaderStore(cacheRoot: root.appendingPathComponent("ReadCache"), transport: transport,
                                 mediaFactory: { _ in throw TeamsMediaError.unavailable })
        store.cachedLoadGate = gate
        coordinator = TeamsRefreshCoordinator(reader: store, defaults: TeamsPerformanceFixtureConfiguration.defaults)
    }

    func connect(_ account: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if let count = Bundle.main.object(forInfoDictionaryKey: "OpenTeamsCachedHistoryCount") as? Int, [200, 2000].contains(count) {
            let cache = TeamsReadCache(root: cacheRoot, accountID: account, tenantID: "fixture-tenant")
            for chatID in ["fixture-one", "fixture-two"] {
                if let history = try? await cache.history(in: chatID) {
                    await transport.reserveSendIDs(history.messages)
                    if history.messages.isEmpty {
                        let messages = await transport.cachedMessages(count: count, account: account)
                        try? await cache.save(.init(messages: messages, messageToken: "older"), in: chatID)
                    }
                }
            }
        }
        await store.connect(session: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/fixture")!,
            accessToken: "fictional-only-" + account, expiresAt: .distantFuture, accountID: account, tenantID: "fixture-tenant",
            displayName: account, messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/fixture")!,
                accessToken: "fictional-only-" + account, expiresAt: .distantFuture)))
        ready = true
    }

    func append() async {
        busy = true
        defer { busy = false }
        await transport.append()
        await store.refreshConversation("fixture-one")
    }
}

struct TeamsPerformanceFixtureView: View {
    var body: some View {
        if let root = TeamsPerformanceFixtureConfiguration.root {
            PerformanceFixtureContent(root: root)
        } else {
            Text("Fixture storage is unavailable. Prepare a fresh fixture bundle.").padding()
        }
    }
}

private struct PerformanceFixtureContent: View {
    @ViewState<PerformanceFixtureController> private var controller: PerformanceFixtureController
    @ViewState<TeamsNotificationRouter> private var router = TeamsNotificationRouter()
    @ViewState<FixtureChatStore> private var sampleStore = FixtureChatStore(draftURL: nil)
    @ViewState<Bool> private var sampleWorkspace = false
    @ViewState<Bool> private var inlineImage = false
    @Bindable private var appearance = TeamsPerformanceFixtureConfiguration.appearance

    init(root: URL) {
        _controller = ViewState(initialValue: PerformanceFixtureController(root: root))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Isolated fixture · \(controller.store.accountID) · \(controller.ready ? "Ready" : "Loading")").lineLimit(1)
                Button("Account A") { Task { await controller.connect("fixture-a") } }
                Button("Account B") { Task { await controller.connect("fixture-b") } }
                Button("Append and refresh") { Task { await controller.append() } }
                Spacer()
                Button("Quit Fixture") { controller.gate?.invalidate(reason: "quit"); NSApp.terminate(nil) }
            }
            .padding(8)
            .disabled(controller.busy)
            if let gate = controller.gate {
                HStack {
                    Button("Arm next cold load") {
                        gate.arm(accountScope: controller.store.accountScope, accountRevision: controller.store.accountRevision)
                    }
                    .disabled(!controller.ready || controller.busy || gate.armed || gate.held != nil)
                    if let request = gate.held {
                        Text("Held · \(request.accountScope) · \(request.chatID) · \(request.id.uuidString)").textSelection(.enabled)
                        Button("Release held load") {
                            gate.release(request, accountScope: controller.store.accountScope, accountRevision: controller.store.accountRevision)
                        }
                    } else {
                        Text(gate.armed ? "Armed for next cold load" : "Unarmed")
                    }
                    Spacer()
                    if let error = gate.traceError { Text(error).foregroundStyle(.red) }
                }
                .font(.caption).padding(8)
            }
            HStack {
                Toggle("Sample Workspace", isOn: $sampleWorkspace).toggleStyle(.button)
                Toggle("Inline image", isOn: $inlineImage).toggleStyle(.button)
                Text("Appearance")
                ForEach(["System", "Light", "Dark"], id: \.self) { selection in
                    Button(selection) { appearance.selection = selection }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(appearance.selection == selection ? ChatTheme.accent : .secondary)
                        .accessibilityLabel("\(selection) appearance")
                        .accessibilityValue(appearance.selection == selection ? "Selected" : "Not selected")
                        .accessibilityAddTraits(appearance.selection == selection ? [.isSelected] : [])
                }
                Spacer()
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            if inlineImage {
                RoundedInlineImageFixtureView(revision: controller.store.mediaRevision)
            } else if sampleWorkspace {
                ContentView(store: sampleStore)
            } else {
                TeamsReadContentView(store: controller.store, refreshCoordinator: controller.coordinator,
                                     notificationRouter: router, connect: {}, persistSelection: false,
                                     fixtureStartupConversation: TeamsPerformanceFixtureConfiguration.startupConversation)
            }
        }
        .background(TeamsSurface.window)
        .frame(minWidth: 820, minHeight: 580)
        .task { await controller.connect("fixture-a") }
    }
}

private struct RoundedInlineImageFixtureView: View {
    let revision: UUID
    @ViewState<Bool> private var fullSizeRequested = false
    private let imageURL = URL(string: "https://us-api.asm.skype.com/v1/objects/rounded-fixture/views/imgo")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fictional inline image").font(.headline)
            Text(fullSizeRequested ? "Full-size requested" : "Thumbnail only").font(.caption)
            let message = TeamsWebMessage(id: "rounded-image", content: #"<p>Fictional image preview</p><img src="https://us-api.asm.skype.com/v1/objects/rounded-fixture/views/imgo" width="400" height="100" alt="Rounded fixture image">"#, messageType: "RichText/Html", imDisplayName: "Alex Example")
            TeamsMessageRow(message: TeamsRenderedMessage(message, accountScope: "rounded-fixture", accountRevision: revision, chatID: "image"), compact: false, grouped: false,
                accountID: "fixture-a", canEdit: false, canReact: false,
                mediaRevision: revision, mediaRefreshRevision: revision,
                loadImage: { image, fullSize in
                    guard image.url == imageURL else { throw TeamsMediaError.unsafeURL }
                    try Task.checkCancellation()
                    if fullSize { fullSizeRequested = true }
                    return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAZAAAABkCAIAAAAnqfEgAAABl0lEQVR4nO3YwQ3CMBAAwYCoDZpIBaGeVBCaSHc0wCMCS2iVmb+te63OvtyXbQIouP57AICjBAvIECwgQ7CADMECMgQLyBAsIEOwgAzBAjIEC8gQLCBDsIAMwQIyBAvIECwgQ7CADMECMgQLyBAsIOP2y+F9ncdNApzF4/n67qANC8gQLCBDsIBz/GENeZQCZ7CP+PK2YQEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAxm3URfs6j7oK4CMbFpAhWECGYAEZl/uy/XsGgENsWECGYAEZggVkCBaQIVhAhmABGYIFZAgWkCFYQIZgARmCBWQIFpAhWECGYAEZggVkCBaQIVhAhmABU8Ub1voLHfGLJMoAAAAASUVORK5CYII=")!
                }, loadPhoto: { _ in throw TeamsMediaError.unavailable },
                replyAuthor: { _ in "Alex Example" }, canJumpToMessage: { _ in false }, jumpToMessage: { _ in }, action: { _ in }, canDelete: false)
            Spacer()
        }
        .padding(20)
        .onChange(of: revision) { _, _ in fullSizeRequested = false }
    }
}
#endif
