import SwiftUI
import WebKit

struct TeamsSignInView: View {
    var connection: TeamsConnection
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect to Teams").font(.headline)
                    Text("Sign in to Teams. This window closes when your chat session is ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if connection.isConnecting { ProgressView().controlSize(.small) }
                Button("Done") { connection.showSignIn = false }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            if let error = connection.error {
                HStack {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reload") { connection.webView?.reload() }
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            if let webView = connection.webView { TeamsSignInBrowser(webView: webView) }
            Text("Sign-in is stored securely in Keychain. Downloaded chats are saved on this Mac.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .modifier(TeamsInsetPanel())
        .background(TeamsSurface.window)
        .buttonBorderShape(.roundedRectangle(radius: TeamsSurface.controlRadius))
        .frame(width: 940, height: 720)
        .task {
            while !Task.isCancelled {
                await connection.checkWebSession()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

private struct TeamsSignInBrowser: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
