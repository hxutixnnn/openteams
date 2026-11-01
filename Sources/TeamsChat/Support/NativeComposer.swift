import AppKit
import SwiftUI

struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    let conversationID: String
    let focusRequest: UUID
    let sendOnReturn: Bool
    let send: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func measuredHeight(text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text + " ", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(1, width - 14), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 5
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height + 20)
        return min(140, max(42, height))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = ComposerTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 7, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Message composer")
        scroll.documentView = editor
        editor.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        let previousID = context.coordinator.parent.conversationID
        let previousFocus = context.coordinator.parent.focusRequest
        editor.sendOnReturn = sendOnReturn
        editor.send = send
        if previousID != conversationID {
            editor.unmarkText()
            editor.undoManager?.removeAllActions()
        }
        context.coordinator.parent = self
        if editor.string != text && !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            if text.isEmpty { editor.undoManager?.removeAllActions() }
        }
        if previousFocus != focusRequest { editor.window?.makeFirstResponder(editor) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        init(_ parent: NativeComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

class ComposerTextView: NSTextView {
    var sendOnReturn = false
    var send: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !hasMarkedText() {
            if modifiers.contains(.command) || (sendOnReturn && modifiers.isDisjoint(with: [.shift, .option, .control])) {
                send?()
                return
            }
        }
        super.keyDown(with: event)
    }
}
