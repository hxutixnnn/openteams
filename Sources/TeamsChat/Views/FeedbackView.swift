import AppKit
import ScreenCaptureKit
import SwiftUI
import TeamsCore

struct FeedbackView: View {
    @MainActor static weak var screenshotWindow: NSWindow?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.controlActiveState) private var activeState
    @State private var title = ""
    @State private var details = ""
    @State private var includeScreenshot = false
    @State private var hasToken = false
    @State private var sending = false
    @State private var error: String?
    @State private var issueURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let issueURL {
                Text("Thank you for your feedback.").font(.headline)
                Link("View issue on GitHub", destination: issueURL)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                TextField("Title", text: $title)
                Text("Details").font(.headline)
                TextEditor(text: $details)
                    .frame(height: 150)
                    .border(.separator)
                    .accessibilityLabel("Feedback details")
                Toggle("Include screenshot of the OpenTeams window", isOn: $includeScreenshot)
                Text("Screenshots can contain names and messages. They stay on this Mac and are never uploaded automatically. After sending, Finder will reveal the PNG so you can review it before attaching it yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !hasToken {
                    Text("No GitHub token is saved. Add one in Settings to send feedback.")
                    Button("Open Settings…") { openSettings() }
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Open Settings…") { openSettings() }
                }
                HStack {
                    if sending { ProgressView().controlSize(.small); Text("Sending…") }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Send") { Task { await send() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasToken || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .disabled(sending)
        .interactiveDismissDisabled(sending)
        .onAppear { hasToken = GitHubTokenStore.contains() }
        .onChange(of: activeState) { _, state in
            if state != .inactive { hasToken = GitHubTokenStore.contains() }
        }
    }

    @MainActor private func send() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            guard try GitHubTokenStore.load().flatMap(GitHubTokenStore.normalized) != nil else {
                hasToken = false
                return
            }
            let screenshot: URL?
            if includeScreenshot {
                screenshot = try await captureWindow()
            } else {
                screenshot = nil
            }
            let report = GitHubIssueReport.feedback(title: title, details: details, screenshotCapturedLocally: screenshot != nil)
            let issue = try await GitHubIssueClient.keychainBacked().create(report)
            issueURL = issue.url
            NSWorkspace.shared.open(issue.url)
            if let screenshot { NSWorkspace.shared.activateFileViewerSelecting([screenshot]) }
        } catch GitHubIssueError.notConfigured {
            hasToken = false
        } catch GitHubIssueError.unauthorized {
            error = "GitHub rejected the token. Update it in Settings and try again."
        } catch {
            self.error = "Could not send feedback. Check your connection, GitHub token permissions, and screenshot access, then try again."
        }
    }

    @MainActor private func captureWindow() async throws -> URL {
        guard let window = Self.screenshotWindow, window.isVisible else {
            throw CocoaError(.fileNoSuchFile)
        }
        let number = CGWindowID(window.windowNumber)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == number }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.frame.width * window.backingScaleFactor)
        configuration.height = Int(target.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let directory = URL.applicationSupportDirectory.appending(path: "TeamsChat/Feedback")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: UUID().uuidString + ".png")
        try png.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
