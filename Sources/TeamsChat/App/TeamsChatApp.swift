import AppKit
import SwiftUI
import TeamsCore
import TeamsCredentialBridge
import TeamsCredentialPersistence
import UserNotifications

@main
struct TeamsChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState<FixtureChatStore> private var store: FixtureChatStore
    private let showcaseDefaults: UserDefaults?
    @ViewState<TeamsConnection> private var connection: TeamsConnection
    #if DEBUG
    @ViewState<TeamsNotificationFixtureController> private var notificationFixture = TeamsNotificationFixtureController()
    #endif

    init() {
        #if DEBUG
        let showcase = ProcessInfo.processInfo.arguments.contains("--showcase")
        #else
        let showcase = false
        #endif
        showcaseDefaults = showcase ? UserDefaults(suiteName: "OpenTeams.showcase." + UUID().uuidString) : nil
        _store = ViewState(initialValue: FixtureChatStore(draftURL: showcase ? nil : URL.applicationSupportDirectory
            .appending(path: "TeamsChat/demo-drafts.json")))
        let reader = TeamsReaderStore(cacheRoot: URL.applicationSupportDirectory.appending(path: "TeamsChat/ReadCache"))
        let access: any TeamsCredentialAccess
        if !showcase, let fingerprint = Bundle.main.object(forInfoDictionaryKey: "TeamsSigningCertificate") as? String,
           let bridge = try? TeamsCredentialBridge(certificate: fingerprint) {
            access = TeamsHelperCredentialAccess(bridge: bridge)
        } else { access = TeamsUnavailableCredentialAccess() }
        _connection = ViewState(initialValue: TeamsConnection(reader: reader, credentialStore: access))
    }

    var body: some Scene {
        WindowGroup("OpenTeams", id: "chat") {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--showcase"), let showcaseDefaults {
                ContentView(store: store)
                    .defaultAppStorage(showcaseDefaults)
                    .tint(ChatTheme.accent)
                    .frame(minWidth: 820, minHeight: 580)
            } else if ProcessInfo.processInfo.arguments.contains("--context-preview-fixture") || ProcessInfo.processInfo.arguments.contains("--context-preview-pdf-fixture") || ProcessInfo.processInfo.arguments.contains("--context-preview-held-fixture") {
                TeamsContextPreviewFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--find-submit-fixture") {
                ConversationSearchFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--file-preview-fixture") || ProcessInfo.processInfo.arguments.contains("--file-preview-pdf-fixture") || ProcessInfo.processInfo.arguments.contains("--file-preview-failure-fixture") || ProcessInfo.processInfo.arguments.contains("--file-preview-loading-fixture") || ProcessInfo.processInfo.arguments.contains("--file-preview-disconnect-fixture") {
                TeamsFilePreviewFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--group-avatar-fixture") || ProcessInfo.processInfo.arguments.contains("--group-avatar-delay-fixture") {
                TeamsGroupAvatarFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--delete-fixture") {
                TeamsDeletionFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--shared-fixture") || ProcessInfo.processInfo.arguments.contains("--shared-error-fixture") || ProcessInfo.processInfo.arguments.contains("--shared-repeat-fixture") || ProcessInfo.processInfo.arguments.contains("--shared-auth-fixture") {
                TeamsSharedFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--new-chat-fixture") || ProcessInfo.processInfo.arguments.contains("--new-chat-auth-fixture") || ProcessInfo.processInfo.arguments.contains("--new-chat-restart-fixture") || ProcessInfo.processInfo.arguments.contains("--new-chat-success-fixture") {
                TeamsNewChatFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--timeline-fixture") {
                TeamsTimelineFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--account-draft-fixture") {
                TeamsAccountDraftFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--mention-fixture") {
                TeamsMentionFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--edit-fixture") || ProcessInfo.processInfo.arguments.contains("--rich-edit-fixture") || ProcessInfo.processInfo.arguments.contains("--rich-edit-structure-fixture") || ProcessInfo.processInfo.arguments.contains("--rich-edit-list-fixture") || ProcessInfo.processInfo.arguments.contains("--edit-menu-fixture") || ProcessInfo.processInfo.arguments.contains("--edit-unsupported-fixture") || ProcessInfo.processInfo.arguments.contains("--edit-rejected-fixture") {
                TeamsMessageEditFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--agents-retry-fixture") {
                TeamsAgentRetryFixtureView(controller: notificationFixture)
            } else if ProcessInfo.processInfo.arguments.contains("--notification-fixture") {
                TeamsNotificationFixtureView(controller: notificationFixture, appDelegate: appDelegate)
            } else {
                mainChat
            }
            #else
            mainChat
            #endif
        }
        .defaultSize(width: 1180, height: 800)
        .commands { ChatCommands() }

        Settings {
            SettingsView(connection: connection)
                .tint(ChatTheme.accent)
        }

        WindowGroup("Sample Workspace", id: "demo") {
            ContentView(store: store).tint(ChatTheme.accent).frame(minWidth: 820, minHeight: 580)
        }
        .defaultSize(width: 1180, height: 800)
    }

    private var mainChat: some View {
        TeamsChatRoot(connection: connection, appDelegate: appDelegate)
    }
}

private struct TeamsChatRoot: View {
    @Bindable var connection: TeamsConnection
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        TeamsReadContentView(store: connection.reader, refreshCoordinator: connection.refreshCoordinator, notificationRouter: appDelegate.notificationRouter, connect: connection.openSignIn, loadFilePreview: { try await connection.filePreview(for: $0) })
                .tint(ChatTheme.accent)
                .frame(minWidth: 820, minHeight: 580)
                .onAppear { appDelegate.configure(coordinator: connection.refreshCoordinator) { openWindow(id: "chat") } }
                .task { await connection.start() }
                .sheet(isPresented: $connection.showSignIn) { TeamsSignInView(connection: connection) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let notificationRouter = TeamsNotificationRouter()
    private weak var refreshCoordinator: TeamsRefreshCoordinator?
    private var openChatWindow: (() -> Void)?
    func configure(coordinator: TeamsRefreshCoordinator, openChatWindow: @escaping () -> Void) {
        self.refreshCoordinator = coordinator; self.openChatWindow = openChatWindow
    }
    func deliver(_ destination: TeamsNotificationDestination, requestID: String) {
        guard notificationRouter.receive(destination, requestID: requestID) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let owner = refreshCoordinator?.activateNotificationWindow()
        notificationRouter.assignOwner(owner)
        if refreshCoordinator?.hasWindows == false { openChatWindow?() }
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        NSApp.activate(ignoringOtherApps: true)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                             withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                             withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let info = response.notification.request.content.userInfo
        guard let account = info["accountScope"] as? String, let chat = info["chatID"] as? String,
              let message = info["messageID"] as? String,
              let destination = TeamsNotificationDestination(accountScope: account, chatID: chat, messageID: message) else { return }
        let requestID = response.notification.request.identifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.deliver(destination, requestID: requestID)
        }
    }
}
