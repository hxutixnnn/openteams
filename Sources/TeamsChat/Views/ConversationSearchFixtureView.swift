#if DEBUG
import AppKit
import SwiftUI

struct ConversationSearchFixtureView: View {
    @ViewState<ConversationSearchFocus> private var focus = ConversationSearchFocus()
    @ViewState<String> private var query = ""
    @ViewState<String> private var other = ""
    @ViewState<String> private var submitted = ""
    @ViewState<Int> private var submits = 0
    @ViewState<Bool> private var visible = true
    @ViewState<Bool> private var oldControlCleared = false
    @ViewState<SearchTextField?> private var retainedOld = nil
    @FocusState private var otherFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Submits: \(submits) · Last: \(submitted)")
            if visible {
                ConversationSearchField(text: $query, focus: focus, accessibilityName: "Fixture search") {
                    submits += 1; submitted = query
                }.frame(width: 360, height: 24)
            }
            TextField("Other input", text: $other).focused($otherFocused).frame(width: 360)
            Button("Hide Search") { visible = false }
            Button("Show Search") { visible = true }
            Button("Queue removed field") {
                guard let current = focus.field, let parent = current.superview else { return }
                let old = SearchTextField()
                let bridge = ConversationSearchField(text: $query, focus: focus, accessibilityName: "Old search") { submits += 1 }
                let coordinator = bridge.makeCoordinator()
                old.target = coordinator; old.action = #selector(ConversationSearchField.Coordinator.submit)
                old.focusOwner = focus; focus.field = old
                parent.addSubview(old)
                ConversationSearchField.dismantleNSView(old, coordinator: coordinator)
                old.removeFromSuperview()
                retainedOld = old
                oldControlCleared = old.target == nil && old.action == nil && old.focusOwner == nil
                focus.field = current
                otherFocused = true
            }
            Text("Old control cleared: \(oldControlCleared)")
        }
        .padding(24).frame(minWidth: 600, minHeight: 400)
        .toolbar { Button("Find fixture") { visible = true; focus.focus() } }
        .focusedSceneValue(\.chatActions, ChatWindowActions(search: { visible = true; focus.focus() }, details: {}, compose: { otherFocused = true }))
    }
}
#endif
