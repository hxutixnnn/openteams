import AppKit
import SwiftUI
import TeamsCore

struct MessageRow: View {
    let message: ChatMessage
    let person: Person
    let compact: Bool
    let react: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PersonAvatar(person: person, size: compact ? 28 : 34)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(person.id == ChatFixtures.me ? "You" : person.name)
                        .font(.callout.weight(.semibold))
                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.caption).foregroundStyle(.tertiary)
                    if message.isEdited { Text("Edited").font(.caption).foregroundStyle(.tertiary) }
                }
                if let quote = message.quote {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(ChatTheme.accent.opacity(0.6)).frame(width: 3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(quote.author).font(.caption.weight(.semibold))
                            Text(quote.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal, 10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                Text(message.text)
                    .font(.system(size: compact ? 13 : 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = message.code {
                    Text(code).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                if let attachment = message.attachment { AttachmentCard(attachment: attachment) }
                if !message.reactions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.reactions, id: \.emoji) { reaction in
                            Button { react(reaction.emoji) } label: {
                                HStack(spacing: 5) {
                                    Text(reaction.emoji)
                                    Text("\(reaction.count)").font(.caption.weight(.medium)).monospacedDigit()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(reaction.includesMe ? ChatTheme.accent.opacity(0.12) : Color.secondary.opacity(0.07), in: Capsule())
                                .overlay(Capsule().strokeBorder(reaction.includesMe ? ChatTheme.accent.opacity(0.35) : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(reaction.emoji), \(reaction.count) reactions\(reaction.includesMe ? ", includes you" : "")")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
            Menu("React in Demo") {
                ForEach(["👍", "💜", "🙌", "😊"], id: \.self) { emoji in
                    Button(emoji) { react(emoji) }
                }
            }
        }
    }
}

struct AttachmentCard: View {
    let attachment: ChatAttachment
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: attachment.symbol).font(.title2).foregroundStyle(ChatTheme.accent)
                .frame(width: 36, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.name).font(.callout.weight(.medium))
                Text(attachment.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("Sample").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10).frame(maxWidth: 360)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
        .help("Sample attachment preview")
    }
}
