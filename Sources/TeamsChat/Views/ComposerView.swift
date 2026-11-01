import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    let conversationID: String
    let focusRequest: UUID
    let persistenceError: String?
    let persistsDrafts: Bool
    let send: () -> Void
    @AppStorage("sendOnReturn") private var sendOnReturn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    NativeComposer(text: $text, conversationID: conversationID, focusRequest: focusRequest,
                                   sendOnReturn: sendOnReturn, send: send)
                    if text.isEmpty {
                        Text("Write a message…")
                            .font(.system(size: 14)).foregroundStyle(.tertiary)
                            .padding(.leading, 12).padding(.top, 11)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 72)
                HStack(spacing: 10) {
                    Text(sendOnReturn ? "Return to send · Shift Return for a new line" : "⌘ Return to send")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button(action: send) {
                        Label("Send locally", systemImage: "arrow.up")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Add this message to the sample conversation")
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
            HStack {
                Image(systemName: persistenceError == nil ? "leaf" : "exclamationmark.triangle")
                Text(persistenceError ?? (persistsDrafts ? "Demo messages stay on this Mac. Drafts are saved as you type." : "Sample messages and drafts last until you quit."))
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 2)
        }
    }
}
