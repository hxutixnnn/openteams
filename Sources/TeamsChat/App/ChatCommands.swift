import SwiftUI

struct ChatWindowActions {
    var search: () -> Void
    var details: () -> Void
    var compose: () -> Void
    var canCompose = true
}

private struct ChatActionsKey: FocusedValueKey { typealias Value = ChatWindowActions }

extension FocusedValues {
    var chatActions: ChatWindowActions? {
        get { self[ChatActionsKey.self] }
        set { self[ChatActionsKey.self] = newValue }
    }
}

struct ChatCommands: Commands {
    @FocusedValue(\.chatActions) private var actions
    var body: some Commands {
        CommandMenu("Conversation") {
            Button("Find in Conversation") { actions?.search() }
                .keyboardShortcut("f")
                .disabled(actions == nil)
            Button("Conversation Details") { actions?.details() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Focus Composer") { actions?.compose() }
                .keyboardShortcut("l")
                .disabled(actions?.canCompose != true)
        }
        SidebarCommands()
    }
}
