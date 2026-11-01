#if DEBUG
import TeamsCore

enum PerformanceFixtureStartupConversation: String {
    case project, planning

    func initialChat(in chats: [TeamsWebChat]) -> TeamsWebChat? {
        if self == .planning, let planning = chats.first(where: { $0.id == "fixture-two" && $0.hidden != true && $0.isConversationDeleted != true }) {
            return planning
        }
        return chats.first { $0.hidden != true && $0.isConversationDeleted != true }
    }
}
#endif
