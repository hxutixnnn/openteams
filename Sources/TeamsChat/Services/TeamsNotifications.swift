import Foundation
import CryptoKit
import OSLog
import UserNotifications
import TeamsCore

@MainActor
enum TeamsNotifications {
    private static var tracker = TeamsNotificationTracker()
    static func reset() { tracker.reset() }
    static func updates(chats: [TeamsWebChat], accountID: String, accountScope: String) -> [TeamsWebChat] {
        tracker.update(chats: chats, accountID: accountID, accountScope: accountScope)
    }
    static func requestAuthorization() async -> Bool {
        do { return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        catch { return false }
    }

    static func request(destination: TeamsNotificationDestination, title: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "New message in Teams"
        content.sound = .default
        content.userInfo = ["accountScope": destination.accountScope, "chatID": destination.chatID, "messageID": destination.messageID]
        let key = destination.accountScope + "\n" + destination.chatID + "\n" + destination.messageID
        let identifier = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
    static func post(destination: TeamsNotificationDestination, title: String) {
        UNUserNotificationCenter.current().add(request(destination: destination, title: title)) { error in
            if error != nil { Logger(subsystem: "dev.native.teamschat", category: "notifications").error("Could not schedule a notification") }
        }
    }
}
