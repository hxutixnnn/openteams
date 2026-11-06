import SwiftUI
import AppKit

struct TeamsUpdateView: View {
    @ViewState private var updater = TeamsAppUpdater.shared
    @ViewState private var confirmInstall = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenTeams Updates").font(.title2.bold())
            Text("Installed build: \(updater.revision.prefix(7))").foregroundStyle(.secondary)
            Text(updater.message).textSelection(.enabled)
                .accessibilityLabel("Update status").accessibilityValue(updater.message)
            if updater.busy { ProgressView().controlSize(.small) }
            Text("Updates build the latest main on this Mac using your existing signing identity. macOS 27, a macOS 27 SDK, Swift 6.4 or later, and internet access are required. Compatible Command Line Tools or Xcode can provide the build tools. Your sign-in and chat data are retained.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Check for Updates") { Task { await updater.check() } }
                    .disabled(updater.busy)
                if updater.available != nil {
                    Button("Install Update…") { confirmInstall = true }
                        .disabled(!updater.canInstall)
                }
                if let log = updater.logURL {
                    Button("Show Update Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                }
            }
            if let issue = updater.prerequisiteIssue {
                Text(issue).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Recheck Build Tools") { Task { await updater.checkPrerequisites() } }
            }
            if updater.available != nil && Bundle.main.bundleURL.path != "/Applications/OpenTeams.app" && !updater.busy {
                Text("Install the signed app in /Applications/OpenTeams.app to enable in-app installation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 480, height: 480)
        .confirmationDialog("Install the update and restart OpenTeams?", isPresented: $confirmInstall) {
            Button("Install and Restart") { updater.install() }
        } message: {
            Text("OpenTeams stays open while the update builds, then restarts to finish installation. The previous app is kept as a backup.")
        }
        .task {
            await updater.checkPrerequisites()
            updater.refreshStatus()
            if updater.status == nil { await updater.check() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                updater.refreshStatus()
            }
        }
    }
}
