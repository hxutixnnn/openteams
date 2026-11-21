import AppKit
import SwiftUI

struct ChatWindowActions {
    var search: () -> Void
    var details: () -> Void
    var compose: () -> Void
    var canCompose = true
    var newChat: (() -> Void)? = nil
    var canInspect = true
    var findChats: (() -> Void)? = nil
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
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { openWindow(id: "updates") }
        }
        CommandGroup(after: .help) {
            Button("Send Feedback…") {
                if actions != nil { FeedbackView.screenshotWindow = NSApp.keyWindow }
                openWindow(id: "feedback")
            }
                .keyboardShortcut("f", modifiers: [.command, .control, .option])
        }
        CommandMenu("Conversation") {
            Button("New Chat") { actions?.newChat?() }
                .disabled(actions?.newChat == nil)
            Divider()
            Button("Search Teams") { actions?.findChats?() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(actions?.findChats == nil)
            Button("Find in Conversation") { actions?.search() }
                .keyboardShortcut("f")
                .disabled(actions?.canInspect != true)
            Button("Conversation Details") { actions?.details() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions?.canInspect != true)
            Button("Focus Composer") { actions?.compose() }
                .keyboardShortcut("l")
                .disabled(actions?.canCompose != true)
        }
        SidebarCommands()
    }
}
