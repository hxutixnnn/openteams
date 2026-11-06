import Foundation
import TeamsCore

final class TeamsMessageRowActions: Equatable {
    var loadImage: (TeamsInlineImage, Bool) async throws -> Data = { _, _ in throw TeamsMediaError.unavailable }
    var loadPhoto: (String) async throws -> Data = { _ in throw TeamsMediaError.unavailable }
    var replyAuthor: (TeamsReplyPreview) -> String = { _ in "" }
    var canJumpToMessage: (String) -> Bool = { _ in false }
    var jumpToMessage: (String) -> Void = { _ in }
    var action: (String) -> Void = { _ in }
    var loadFilePreview: ((TeamsSharePointAttachment) async throws -> Data)?

    nonisolated static func == (lhs: TeamsMessageRowActions, rhs: TeamsMessageRowActions) -> Bool {
        lhs === rhs
    }
}

@MainActor final class TeamsMessageRowActionCache {
    private var entries: [String: TeamsMessageRowActions] = [:]

    func actions(for key: String, configure: (TeamsMessageRowActions) -> Void) -> TeamsMessageRowActions {
        let actions = entries[key] ?? TeamsMessageRowActions()
        configure(actions)
        entries[key] = actions
        return actions
    }

    func reset() { entries.removeAll() }
}
