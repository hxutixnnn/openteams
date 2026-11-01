import AppKit
import SwiftUI

@MainActor final class ConversationSearchFocus {
    weak var field: NSTextField?
    func focus() {
        guard let field, let window = field.window, window.isKeyWindow else { return }
        window.makeFirstResponder(field)
    }
}

struct ConversationSearchField: NSViewRepresentable {
    @Binding var text: String
    let focus: ConversationSearchFocus
    let accessibilityName: String
    var submit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.placeholderString = "Search this conversation"
        field.bezelStyle = .roundedBezel
        field.cell?.sendsActionOnEndEditing = false
        field.setAccessibilityLabel(accessibilityName)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.focusOwner = focus
        focus.field = field
        return field
    }
    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if let old = field.focusOwner, old !== focus, old.field === field { old.field = nil }
        field.focusOwner = focus
        focus.field = field
    }
    static func dismantleNSView(_ field: SearchTextField, coordinator: Coordinator) {
        if field.focusOwner?.field === field { field.focusOwner?.field = nil }
        field.delegate = nil
        field.focusOwner = nil
        field.target = nil
        field.action = nil
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ConversationSearchField
        init(_ parent: ConversationSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        @objc func submit() { parent.submit() }
    }
}

final class SearchTextField: NSTextField {
    weak var focusOwner: ConversationSearchFocus?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let owner = focusOwner else { return }
        DispatchQueue.main.async { [weak self, weak owner] in
            guard let self, let owner, self.window != nil, self.focusOwner === owner, owner.field === self else { return }
            owner.focus()
        }
    }
}
