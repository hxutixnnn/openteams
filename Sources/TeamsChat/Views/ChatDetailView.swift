import SwiftUI
import TeamsCore

struct ChatDetailView: View {
    var store: FixtureChatStore
    let conversation: Conversation
    @Binding var jumpToMessage: String?
    let focusComposer: UUID
    @AppStorage("compactMessages") private var compact = false
    @ViewState<String?> private var newestLocalMessage: String? = nil

    private var messages: [ChatMessage] { store.messages(in: conversation.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ConversationIcon(conversation: conversation, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.subtitle).font(.callout.weight(.medium))
                    Text("\(conversation.memberIDs.count) \(conversation.memberIDs.count == 1 ? "person" : "people") · Sample conversation")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 14 : 24) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !Calendar.current.isDate(message.createdAt, inSameDayAs: messages[index - 1].createdAt) {
                                dateSeparator(message.createdAt)
                            }
                            MessageRow(message: message, person: store.person(message.authorID), compact: compact) { emoji in
                                store.toggleReaction(emoji, messageID: message.id)
                            }
                            .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("timeline-bottom")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: conversation.id) { _, _ in
                    proxy.scrollTo("timeline-bottom", anchor: .bottom)
                }
                .onChange(of: newestLocalMessage) { _, value in
                    guard value != nil else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("timeline-bottom", anchor: .bottom) }
                }
                .onChange(of: jumpToMessage) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }

            ComposerView(text: Binding(
                get: { store.draft(in: conversation.id) },
                set: { store.setDraft($0, in: conversation.id) }
            ), conversationID: conversation.id, focusRequest: focusComposer, persistenceError: store.persistenceError, persistsDrafts: store.persistsDrafts) {
                newestLocalMessage = store.sendDraft(in: conversation.id)?.id
            }
            .padding(.horizontal, 20).padding(.bottom, 10).padding(.top, 8)
        }
    }

    private func dateSeparator(_ date: Date) -> some View {
        HStack(spacing: 14) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.vertical, 2)
    }
}
