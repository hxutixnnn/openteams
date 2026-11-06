import SwiftUI
import TeamsCore

enum ChatTheme {
    static let accent = Color(red: 0.39, green: 0.36, blue: 0.76)
    static let colors: [Color] = [accent, .pink, .teal, .orange, .blue, .brown, .gray]
    static func color(_ index: Int) -> Color { colors[abs(index) % colors.count] }
}

struct PersonAvatar: View {
    let person: Person
    var size: CGFloat = 34
    var revision: UUID? = nil
    var refreshRevision: UUID? = nil
    var loadPhoto: ((String) async throws -> Data)? = nil
    @ViewState<NSImage?> private var photo = nil
    @ViewState<UUID?> private var loadedRevision = nil
    @ViewState<String?> private var loadedPersonID = nil
    var body: some View {
        Group {
            if loadedRevision == revision, loadedPersonID == person.id, let photo {
                Image(nsImage: photo).resizable().scaledToFill()
            } else {
                Text(person.initials)
                    .font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
        .task(id: (revision?.uuidString ?? "") + (refreshRevision?.uuidString ?? "") + person.id) {
            if loadedRevision == revision, loadedPersonID == person.id, photo != nil { return }
            photo = nil; loadedRevision = nil; loadedPersonID = nil
            guard let revision, let loadPhoto else { return }
            do { let result = try await loadPhoto(person.id); try Task.checkCancellation(); photo = NSImage(data: result); loadedRevision = revision; loadedPersonID = person.id }
            catch { }
        }
    }
}

struct ConversationIcon: View {
    let conversation: Conversation
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: conversation.symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(ChatTheme.color(conversation.colorIndex))
            .frame(width: size, height: size)
            .background(ChatTheme.color(conversation.colorIndex).opacity(0.12), in: RoundedRectangle(cornerRadius: TeamsSurface.cardRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}
