import Foundation

public struct TeamsRefreshPolicy: Sendable {
    public struct Decision: Equatable, Sendable {
        public let refreshLists: Bool
        public let chatIDs: Set<String>
    }
    private var scope = ""
    private var lastMaintenance = Date.distantPast
    private let maintenanceInterval: TimeInterval
    public init(maintenanceInterval: TimeInterval = 60) { self.maintenanceInterval = max(1, maintenanceInterval) }
    public mutating func reset() { scope = ""; lastMaintenance = .distantPast }
    public mutating func forceMaintenance() { lastMaintenance = .distantPast }
    public mutating func decide(at now: Date, accountScope: String, connected: Bool, hasActiveWindow: Bool,
                                activeChatIDs: Set<String>, notificationsEnabled: Bool) -> Decision {
        guard connected, hasActiveWindow || notificationsEnabled else { return .init(refreshLists: false, chatIDs: []) }
        if scope != accountScope { scope = accountScope; lastMaintenance = .distantPast }
        let maintenance = now.timeIntervalSince(lastMaintenance) >= maintenanceInterval
        if maintenance { lastMaintenance = now }
        return .init(refreshLists: maintenance, chatIDs: hasActiveWindow ? activeChatIDs.filter { !$0.isEmpty } : [])
    }
}
