import Foundation

public enum TeamsTimelineUpdate {
    public struct Decision: Equatable, Sendable {
        public let scrollToBottom: Bool
        public let newMessageCount: Int
    }
    public static func decide(previous: [String], current: [String], atBottom: Bool) -> Decision {
        let count = appendedCount(previous: previous, current: current)
        return Decision(scrollToBottom: count > 0 && atBottom, newMessageCount: atBottom ? 0 : count)
    }
    public static func appendedCount(previous: [String], current: [String]) -> Int {
        guard let last = previous.last, let index = current.firstIndex(of: last) else { return 0 }
        let known = Set(previous)
        return current.dropFirst(index + 1).filter { !known.contains($0) }.count
    }
}
