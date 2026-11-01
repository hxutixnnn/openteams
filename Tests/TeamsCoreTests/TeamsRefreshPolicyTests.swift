import Foundation
import Testing
@testable import TeamsCore

struct TeamsRefreshPolicyTests {
    @Test func singlePolicyCoalescesWindowsAndContinuesWithoutWindowsWhenEnabled() {
        var policy = TeamsRefreshPolicy()
        let now = Date(timeIntervalSince1970: 1_000)
        let first = policy.decide(at: now, accountScope: "a", connected: true, hasActiveWindow: true, activeChatIDs: ["one", "one", "two"], notificationsEnabled: false)
        #expect(first.refreshLists && first.chatIDs == ["one", "two"])
        let next = policy.decide(at: now.addingTimeInterval(15), accountScope: "a", connected: true, hasActiveWindow: true, activeChatIDs: ["one"], notificationsEnabled: false)
        #expect(!next.refreshLists && next.chatIDs == ["one"])
        let closed = policy.decide(at: now.addingTimeInterval(60), accountScope: "a", connected: true, hasActiveWindow: false, activeChatIDs: [], notificationsEnabled: true)
        #expect(closed.refreshLists && closed.chatIDs.isEmpty)
        let disabled = policy.decide(at: now.addingTimeInterval(120), accountScope: "a", connected: true, hasActiveWindow: false, activeChatIDs: [], notificationsEnabled: false)
        #expect(!disabled.refreshLists && disabled.chatIDs.isEmpty)
        let other = policy.decide(at: now.addingTimeInterval(121), accountScope: "b", connected: true, hasActiveWindow: true, activeChatIDs: ["two"], notificationsEnabled: false)
        #expect(other.refreshLists && other.chatIDs == ["two"])
        let offline = policy.decide(at: now.addingTimeInterval(200), accountScope: "b", connected: false, hasActiveWindow: true, activeChatIDs: ["two"], notificationsEnabled: true)
        #expect(!offline.refreshLists && offline.chatIDs.isEmpty)
    }
}
