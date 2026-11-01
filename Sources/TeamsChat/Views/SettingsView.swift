import SwiftUI

struct SettingsView: View {
    var connection: TeamsConnection
    @Environment(\.openWindow) private var openWindow
    @AppStorage("teamsNotificationsEnabled") private var notificationsEnabled = false
    @ViewState<Bool> private var notificationDenied = false
    @AppStorage("compactMessages") private var compact = false
    @AppStorage("sendOnReturn") private var sendOnReturn = false
    @AppStorage("sendTeamsOnReturn") private var sendTeamsOnReturn = false

    var body: some View {
        Form {
            Section("Teams account") {
                LabeledContent("Account", value: connection.reader.accountName)
                LabeledContent("Status", value: connection.reader.connected ? "Connected" : "Disconnected")
                if let expiry = connection.expiresAt {
                    LabeledContent("Session expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                }
                if let error = connection.error { Text(error).foregroundStyle(.secondary) }
                HStack {
                    if connection.keychainNeedsApproval {
                        Button("Retry Saved Sign-in") { Task { await connection.unlockSavedSignIn() } }
                    }
                    if connection.credentialWriteUncertain {
                        Button("Check Saved Sign-in") { Task { await connection.reconcileSavedSignIn() } }
                    }
                    Button(connection.reader.connected ? "Reconnect to Teams" : "Connect to Teams") {
                        openWindow(id: "chat")
                        connection.openSignIn()
                    }.disabled(connection.isClearingSignIn)
                    Button("Disconnect") { connection.disconnect() }.disabled(connection.isClearingSignIn)
                }
                Text("Chats and downloaded messages stay separate for each account on this Mac. Your sign-in is stored in Keychain until you disconnect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Conversation") {
                Toggle("Notify about new messages while OpenTeams is open", isOn: Binding(
                    get: { notificationsEnabled },
                    set: { enabled in
                        if !enabled { notificationsEnabled = false; return }
                        Task {
                            let allowed = await TeamsNotifications.requestAuthorization()
                            notificationsEnabled = allowed
                            notificationDenied = !allowed
                        }
                    }))
                if notificationDenied { Text("Notifications are unavailable. Check macOS notification settings.").font(.caption).foregroundStyle(.secondary) }
                Toggle("Compact message spacing", isOn: $compact)
                Toggle("Press Return to send Teams messages", isOn: $sendTeamsOnReturn)
                Text("Chats refresh every minute while the window is active. Find in Conversation searches downloaded messages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sample workspace") {
                Button("Open Sample Workspace") { openWindow(id: "demo") }
                Toggle("Press Return to send demo messages", isOn: $sendOnReturn)
                Text("Fictional conversations with local sending and saved drafts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 590, height: 560)
    }
}
