import SwiftUI
import TeamsCore

struct SettingsView: View {
    var connection: TeamsConnection
    var isolated = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage("teamsNotificationsEnabled") private var notificationsEnabled = false
    @ViewState<Bool> private var notificationDenied = false
    @AppStorage("compactMessages") private var compact = false
    @AppStorage("sendOnReturn") private var sendOnReturn = false
    @AppStorage("sendTeamsOnReturn") private var sendTeamsOnReturn = false

    var body: some View {
        Form {
                Section("Teams Account") {
                    LabeledContent("Account", value: connection.reader.accountName)
                    LabeledContent("Status", value: connection.reader.connected ? "Connected" : "Disconnected")
                    if let expiry = connection.expiresAt {
                        LabeledContent("Session expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let error = connection.error { Text(error).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 8) {
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
                .disabled(isolated)
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
                        .disabled(isolated)
                    if notificationDenied { Text("Notifications are unavailable. Check macOS notification settings.").font(.caption).foregroundStyle(.secondary) }
                    Toggle("Compact message spacing", isOn: $compact)
                    Toggle("Press Return to send Teams messages", isOn: $sendTeamsOnReturn)
                    Text("Chats refresh every minute while the window is active. Find in Conversation searches downloaded messages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Sample Workspace") {
                    Button("Open Sample Workspace") { openWindow(id: "demo") }
                    Toggle("Press Return to send demo messages", isOn: $sendOnReturn)
                    Text("Fictional conversations with local sending and saved drafts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GitHubIssueReportingSection()
                    .disabled(isolated)
                Section("Updates") {
                    Button("Check for Updates…") { openWindow(id: "updates") }
                        .disabled(isolated)
                }
        }
        .formStyle(.grouped)
        .frame(width: 590, height: 560)
    }
}

private struct GitHubIssueReportingSection: View {
    @ViewState<String> private var draft = ""
    @ViewState<Bool> private var saved = false
    @ViewState<String?> private var message: String?

    var body: some View {
        Section("Issue Reporting") {
            if saved {
                LabeledContent("GitHub token", value: "Saved in Keychain")
                Button("Remove Token", role: .destructive) {
                    do {
                        try GitHubTokenStore.delete()
                        saved = false
                        message = nil
                    } catch { message = "The token could not be removed from Keychain." }
                }
            } else {
                SecureField("GitHub token", text: $draft)
                    .onSubmit(save)
                Button("Save to Keychain", action: save)
                    .disabled(GitHubTokenStore.normalized(draft) == nil)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Used only to file issues in \(GitHubIssueClient.defaultRepository). Create a fine-grained token for that repository with Issues read and write access. With a token saved, problems that automatic recovery cannot fix, or that keep repeating, are filed there automatically. Tokens, message text and personal details are removed before anything is sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { saved = GitHubTokenStore.contains() }
    }

    private func save() {
        guard GitHubTokenStore.normalized(draft) != nil else { return }
        do {
            try GitHubTokenStore.save(draft)
            draft = ""
            saved = true
            message = nil
        } catch { message = "The token could not be saved to Keychain." }
    }
}
