import AppKit
import Foundation
import TeamsCore

@MainActor
final class TeamsRefreshCoordinator {
    private final class WeakWindow { weak var value: NSWindow?; init(_ value: NSWindow) { self.value = value } }
    private let reader: TeamsReaderStore
    private let defaults: UserDefaults
    private let tickInterval: TimeInterval
    private var windows: [UUID: (chatID: String, active: Bool)] = [:]
    private var windowRefs: [UUID: WeakWindow] = [:]
    private var loop: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var policy: TeamsRefreshPolicy

    init(reader: TeamsReaderStore, defaults: UserDefaults = .standard, tickInterval: TimeInterval = 15, maintenanceInterval: TimeInterval = 60) {
        self.reader = reader; self.defaults = defaults; self.tickInterval = max(1, tickInterval)
        self.policy = TeamsRefreshPolicy(maintenanceInterval: maintenanceInterval)
    }
    func start() {
        guard loop == nil else { return }
        reader.onServerChatSnapshot = { [weak self] snapshot in self?.received(snapshot) }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        let active = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        observers = [(NSWorkspace.shared.notificationCenter, wake), (NotificationCenter.default, active)]
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.tickInterval else { return }
                do { try await Task.sleep(for: .milliseconds(Int64(delay * 1_000))) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }
    func updateWindow(_ id: UUID, chatID: String, active: Bool) {
        windows[id] = (chatID, active)
    }
    func attachWindow(_ id: UUID, window: NSWindow) { windowRefs[id] = WeakWindow(window) }
    func removeWindow(_ id: UUID) { windows.removeValue(forKey: id); windowRefs.removeValue(forKey: id) }
    var hasWindows: Bool { !windows.isEmpty }
    func notificationWindow() -> UUID? {
        if let key = NSApp.keyWindow, let match = windowRefs.first(where: { $0.value.value === key }) { return match.key }
        for window in NSApp.orderedWindows {
            if let match = windowRefs.first(where: { $0.value.value === window }) { return match.key }
        }
        return nil
    }
    func activateNotificationWindow() -> UUID? {
        guard let id = notificationWindow(), let window = windowRefs[id]?.value else { return nil }
        window.makeKeyAndOrderFront(nil)
        return id
    }
    func stop() {
        loop?.cancel(); loop = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []; reader.onServerChatSnapshot = nil
    }
    func reset() { TeamsNotifications.reset(); policy.reset() }
    func refreshNow() { policy.forceMaintenance(); tick() }
    private func received(_ snapshot: TeamsServerChatSnapshot) {
        guard reader.connected, snapshot.accountScope == reader.accountScope else { return }
        let updates = TeamsNotifications.updates(chats: snapshot.chats, accountID: reader.accountID, accountScope: snapshot.accountScope)
        guard defaults.bool(forKey: "teamsNotificationsEnabled") else { return }
        for chat in updates {
            guard let message = chat.lastMessage,
                  let destination = TeamsNotificationDestination(accountScope: snapshot.accountScope, chatID: chat.id, messageID: message.id) else { continue }
            TeamsNotifications.post(destination: destination, title: reader.conversationTitle(chat))
        }
    }
    func tick(at now: Date = Date()) {
        let activeChats = Set(windows.values.filter(\.active).map(\.chatID).filter { !$0.isEmpty })
        let hasActiveWindow = windows.values.contains { $0.active }
        let notifications = defaults.bool(forKey: "teamsNotificationsEnabled")
        let decision = policy.decide(at: now, accountScope: reader.accountScope, connected: reader.connected,
                                     hasActiveWindow: hasActiveWindow, activeChatIDs: activeChats, notificationsEnabled: notifications)
        let account = reader.accountScope
        if decision.refreshLists {
            Task { guard reader.accountScope == account, reader.connected else { return }; await reader.refreshChats() }
            Task { guard reader.accountScope == account, reader.connected else { return }; await reader.refreshConversationFolders() }
        }
        for id in decision.chatIDs { Task { guard reader.accountScope == account, reader.connected else { return }; await reader.refreshConversation(id) } }
    }
}
