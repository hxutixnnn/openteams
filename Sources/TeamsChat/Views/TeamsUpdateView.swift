import SwiftUI
import AppKit

struct TeamsUpdateView: View {
    @ViewState private var updater = TeamsAppUpdater.shared
    @ViewState private var confirmInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenTeams Updates").font(.title2.bold())
            Text("Installed build: \(updater.revision.prefix(7))").foregroundStyle(.secondary)
            Text(updater.message).textSelection(.enabled)
                .accessibilityLabel("Update status").accessibilityValue(updater.message)
            if updater.busy { ProgressView().controlSize(.small) }
            Text("Updates build the latest main on this Mac using your existing signing identity. Xcode Command Line Tools and internet access are required. Your sign-in and chat data are retained.")
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
            if updater.available != nil && !updater.canInstall && !updater.busy {
                Text("Install the signed app in /Applications/OpenTeams.app to enable in-app installation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 480, alignment: .leading)
        .background(TeamsSurface.window)
        .confirmationDialog("Install the update and restart OpenTeams?", isPresented: $confirmInstall) {
            Button("Install and Restart") { updater.install() }
        } message: {
            Text("OpenTeams stays open while the update builds, then restarts to finish installation. The previous app is kept as a backup.")
        }
        .task {
            updater.refreshStatus()
            if updater.status == nil { await updater.check() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                updater.refreshStatus()
            }
        }
    }
}
