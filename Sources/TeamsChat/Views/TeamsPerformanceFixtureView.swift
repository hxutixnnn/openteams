#if DEBUG
import AppKit
import Observation
import SwiftUI
import TeamsCore

@MainActor enum TeamsPerformanceFixtureConfiguration {
    static let enabled = Bundle.main.object(forInfoDictionaryKey: "OpenTeamsPerformanceFixtureRoot") != nil || ProcessInfo.processInfo.arguments.contains("--performance-fixture")
    static let defaults = UserDefaults(suiteName: "OpenTeams.performance-fixture." + UUID().uuidString)!
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
        transport = PerformanceFixtureTransport(allowsSend: Bundle.main.object(forInfoDictionaryKey: "OpenTeamsFictionalSendEnabled") as? Bool == true, gate: gate)
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

    init(root: URL) {
        _controller = ViewState(initialValue: PerformanceFixtureController(root: root))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Isolated fixture · \(controller.store.accountID) · \(controller.ready ? "Ready" : "Loading")")
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
            TeamsReadContentView(store: controller.store, refreshCoordinator: controller.coordinator,
                                 notificationRouter: router, connect: {}, persistSelection: false)
        }
        .frame(minWidth: 1000, minHeight: 650)
        .task { await controller.connect("fixture-a") }
    }
}
#endif
