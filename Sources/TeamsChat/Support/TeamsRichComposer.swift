import AppKit
import SwiftUI
import TeamsCore

struct TeamsComposerCommand: Equatable {
    enum Action: Equatable { case bold, italic, underline, strike, code, bulletList, numberedList, quote, indent, outdent, link(URL?), mention(TeamsRichDraft.Mention) }
    let action: Action
    let id = UUID()
}

private extension NSAttributedString.Key {
    static let teamsMention = NSAttributedString.Key("TeamsMentionIdentity")
    static let teamsCode = NSAttributedString.Key("TeamsCode")
    static let teamsBlock = NSAttributedString.Key("TeamsBlock")
    static let teamsCodeBlock = NSAttributedString.Key("TeamsCodeBlock")
    static let teamsSoftBreak = NSAttributedString.Key("TeamsSoftBreak")
}

struct TeamsRichComposer: NSViewRepresentable {
    @Binding var document: TeamsRichDraft
    let conversationID: String
    let focusRequest: UUID
    let command: TeamsComposerCommand?
    let sendOnReturn: Bool
    let send: () -> Void
    var editable = true
    var members: [TeamsWebMember] = []
    var accountID = ""
    var mentionPicker: TeamsMentionPickerState? = nil
    var editorReady: ((RichComposerTextView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = RichComposerTextView(); editor.delegate = context.coordinator
        editor.isEditable = editable
        editor.isRichText = true; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 7, height: 10); editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Message composer")
        editor.handleListReturn = { [weak coordinator = context.coordinator, weak editor] in
            guard let coordinator, let editor else { return false }
            return coordinator.insertListReturn(in: editor)
        }
        editor.listDeletionCompleted = { [weak coordinator = context.coordinator, weak editor] state, selection in
            guard let coordinator, let editor else { return }
            coordinator.publish(editor)
            coordinator.registerUndo(editor, state: state, selection: selection)
        }
        editor.handleMentionKey = { [weak coordinator = context.coordinator, weak editor] event in
            guard let coordinator, let editor else { return false }
            return coordinator.handleMentionKey(event, editor: editor)
        }
        editor.compositionStateChanged = { [weak coordinator = context.coordinator, weak editor] in
            guard let coordinator, let editor else { return }
            if editor.hasMarkedText() { coordinator.parent.mentionPicker?.clear(owner: coordinator.mentionOwner) }
            else { coordinator.scheduleMentions(editor) }
        }
        editor.textStorage?.setAttributedString(Self.attributed(document))
        context.coordinator.lastPublished = document
        scroll.documentView = editor
        if let editorReady { DispatchQueue.main.async { [weak editor] in if let editor { editorReady(editor) } } }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? RichComposerTextView else { return }
        let coordinator = context.coordinator
        editor.isEditable = editable
        let old = coordinator.parent
        var invalidateSuggestions = old.conversationID != conversationID || old.accountID != accountID || old.editable != editable || old.members != members || old.mentionPicker !== mentionPicker
        editor.sendOnReturn = sendOnReturn; editor.send = send
        if old.conversationID != conversationID || old.accountID != accountID {
            editor.unmarkText(); editor.undoManager?.removeAllActions(); coordinator.lastPublished = nil; coordinator.invalidMentions = []
            coordinator.suppressedMention = nil
        }
        coordinator.parent = self
        let equivalentPlain = coordinator.lastPublished.map { $0.isPlain && document.isPlain && $0.plainText == document.plainText } ?? false
        if coordinator.lastPublished != document && !equivalentPlain && !editor.hasMarkedText() {
            invalidateSuggestions = true; coordinator.suppressedMention = nil
            editor.textStorage?.setAttributedString(Self.attributed(document))
            editor.setSelectedRange(NSRange(location: (document.plainText as NSString).length, length: 0))
            coordinator.lastPublished = document
            if document.plainText.isEmpty { editor.undoManager?.removeAllActions() }
        }
        if old.focusRequest != focusRequest { editor.window?.makeFirstResponder(editor) }
        if let command, coordinator.lastCommand != command.id {
            coordinator.lastCommand = command.id
            coordinator.apply(command.action, to: editor)
        }
        if invalidateSuggestions { coordinator.blockMentionsUntilTextChange = true; coordinator.invalidateMentions(editor, oldPicker: old.mentionPicker) }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.destroyMentions()
    }
    private static func attributed(_ document: TeamsRichDraft) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for (index, line) in document.editorLines.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])) }
            if !line.prefix.isEmpty {
                output.append(NSAttributedString(string: line.prefix, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor, .teamsBlock: ["kind": line.kind.rawValue, "depth": String(line.depth), "prefix": line.prefix]]))
            }
            for run in line.runs {
                var font = run.code || line.kind == .codeBlock ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) : NSFont.systemFont(ofSize: 14)
                if run.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
                if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if run.code { attrs[.teamsCode] = true }
                if line.kind == .codeBlock { attrs[.teamsCodeBlock] = true }
                if let url = run.link { attrs[.link] = url }
                if let mention = run.mention {
                    attrs[.teamsMention] = ["mri": mention.mri, "name": mention.displayName, "occurrence": mention.occurrenceID.uuidString]
                    attrs[.foregroundColor] = NSColor.controlAccentColor; attrs[.backgroundColor] = NSColor.controlAccentColor.withAlphaComponent(0.12)
                }
                let value = NSMutableAttributedString(string: run.text, attributes: attrs)
                let text = run.text as NSString
                var offset = 0
                while offset < text.length {
                    let next = text.range(of: "\n", options: [], range: NSRange(location: offset, length: text.length - offset))
                    if next.location == NSNotFound { break }
                    value.addAttribute(.teamsSoftBreak, value: true, range: next)
                    offset = NSMaxRange(next)
                }
                output.append(value)
            }
        }
        return output
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TeamsRichComposer
        var lastPublished: TeamsRichDraft?
        var lastCommand: UUID?
        var invalidMentions: Set<UUID> = []
        let mentionOwner = UUID()
        var mentionRevision = 0
        var mentionActive = true
        var blockMentionsUntilTextChange = false
        struct MentionQuery: Equatable { let range: NSRange; let text: String; let conversationID: String }
        var suppressedMention: MentionQuery?
        init(_ parent: TeamsRichComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? RichComposerTextView else { return }
            guard !editor.hasMarkedText() else { parent.mentionPicker?.clear(owner: mentionOwner); return }
            blockMentionsUntilTextChange = false
            publish(editor)
            scheduleMentions(editor)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? RichComposerTextView else { return }
            scheduleMentions(editor)
        }
        func scheduleMentions(_ editor: RichComposerTextView) {
            DispatchQueue.main.async { [weak self, weak editor] in guard let self, self.mentionActive, let editor else { return }; self.updateMentions(editor) }
        }
        func invalidateMentions(_ editor: RichComposerTextView, oldPicker: TeamsMentionPickerState?) {
            mentionRevision += 1
            DispatchQueue.main.async { [weak self, weak editor, weak oldPicker] in
                guard let self, self.mentionActive else { return }
                oldPicker?.clear(owner: self.mentionOwner)
                if let editor { self.updateMentions(editor) }
            }
        }
        func destroyMentions() {
            mentionActive = false; mentionRevision += 1
            let picker = parent.mentionPicker, owner = mentionOwner
            DispatchQueue.main.async { picker?.clear(owner: owner) }
        }
        private func mentionQuery(_ editor: RichComposerTextView) -> MentionQuery? {
            guard parent.editable, !editor.hasMarkedText(), let storage = editor.textStorage else { return nil }
            let selection = editor.selectedRange(), text = storage.string as NSString
            guard selection.length == 0, selection.location != NSNotFound, selection.location <= text.length else { return nil }
            let cursor = selection.location
            func adjacentHas(_ offset: Int, punctuation: String) -> Bool {
                let range = text.rangeOfComposedCharacterSequence(at: offset)
                let value = text.substring(with: range)
                let forbidden = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: punctuation))
                return value.unicodeScalars.contains { forbidden.contains($0) }
            }
            if cursor < text.length, adjacentHas(cursor, punctuation: "_-’'") { return nil }
            var index = cursor
            while index > 0, cursor - index < 80 {
                let character = text.character(at: index - 1)
                if character == 10 || character == 13 { return nil }
                if character == 64 || character == 0xff20 { index -= 1; break }
                index -= 1
            }
            guard index < cursor, [64, 0xff20].contains(Int(text.character(at: index))) else { return nil }
            if index > 0, adjacentHas(index - 1, punctuation: "_@./:\\") { return nil }
            let range = NSRange(location: index, length: cursor - index)
            var unsafe = false
            storage.enumerateAttributes(in: range) { attributes, _, stop in
                if attributes[.link] != nil || attributes[.teamsMention] != nil { unsafe = true; stop.pointee = true }
            }
            guard !unsafe else { return nil }
            let query = text.substring(with: range)
            guard query.dropFirst().rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return .init(range: range, text: query, conversationID: parent.conversationID)
        }
        private func candidates(for query: MentionQuery) -> [TeamsMentionCandidate] {
            let fragment = String(query.text.dropFirst())
            var seen: Set<String> = [], output: [TeamsMentionCandidate] = []
            for member in parent.members {
                guard member.kind == .person, let mri = member.mri, !mri.isEmpty,
                      let name = member.preferredDisplayName, !name.isEmpty, mri.caseInsensitiveCompare("8:orgid:" + parent.accountID) != .orderedSame,
                      seen.insert(mri.lowercased()).inserted else { continue }
                if TeamsMentionCandidate.matches(name: name, fragment: fragment) { output.append(.init(id: mri, name: name)); if output.count == 5 { break } }
            }
            return output
        }
        private func updateMentions(_ editor: RichComposerTextView) {
            guard !blockMentionsUntilTextChange, let picker = parent.mentionPicker, let query = mentionQuery(editor) else { parent.mentionPicker?.clear(owner: mentionOwner); return }
            if let suppressedMention, query != suppressedMention { self.suppressedMention = nil }
            guard query != suppressedMention else { picker.clear(owner: mentionOwner); return }
            let items = candidates(for: query)
            guard !items.isEmpty else { picker.clear(owner: mentionOwner); return }
            let revision = mentionRevision
            picker.show(owner: mentionOwner, candidates: items) { [weak self, weak editor] index in
                guard let self, self.mentionActive, self.mentionRevision == revision, let editor, items.indices.contains(index), self.mentionQuery(editor) == query,
                      self.candidates(for: query) == items else { return }
                self.insertMention(items[index], replacing: query.range, editor: editor)
            }
        }
        private func insertMention(_ candidate: TeamsMentionCandidate, replacing range: NSRange, editor: RichComposerTextView) {
            guard let storage = editor.textStorage, !editor.hasMarkedText(), NSMaxRange(range) <= storage.length else { return }
            let before = NSAttributedString(attributedString: storage), beforeSelection = editor.selectedRange()
            let mention = TeamsRichDraft.Mention(mri: candidate.id, displayName: candidate.name)
            var attrs = editor.typingAttributes
            attrs[.teamsMention] = ["mri": mention.mri, "name": mention.displayName, "occurrence": mention.occurrenceID.uuidString]
            attrs[.foregroundColor] = NSColor.controlAccentColor; attrs[.backgroundColor] = NSColor.controlAccentColor.withAlphaComponent(0.12)
            attrs[.link] = nil; attrs[.teamsBlock] = nil; attrs[.teamsSoftBreak] = nil
            let insertion = NSMutableAttributedString(string: mention.displayName, attributes: attrs)
            attrs[.teamsMention] = nil; attrs[.foregroundColor] = NSColor.labelColor; attrs[.backgroundColor] = nil
            insertion.append(NSAttributedString(string: " ", attributes: attrs))
            parent.mentionPicker?.clear(owner: mentionOwner)
            editor.window?.makeFirstResponder(editor)
            editor.undoManager?.disableUndoRegistration(); editor.insertingSelectedMention = true
            editor.insertText(insertion, replacementRange: range)
            editor.insertingSelectedMention = false; editor.undoManager?.enableUndoRegistration()
            editor.typingAttributes = attrs
            publish(editor); registerUndo(editor, state: before, selection: beforeSelection, label: "Insert mention")
        }
        func handleMentionKey(_ event: NSEvent, editor: RichComposerTextView) -> Bool {
            guard !editor.hasMarkedText(), let picker = parent.mentionPicker, picker.isOwned(by: mentionOwner),
                  let query = mentionQuery(editor), query != suppressedMention else { return false }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isDisjoint(with: [.option, .control, .shift]) else { return false }
            if modifiers.contains(.command), event.keyCode != 36 && event.keyCode != 76 { return false }
            switch event.keyCode {
            case 125: picker.move(1, owner: mentionOwner); return true
            case 126: picker.move(-1, owner: mentionOwner); return true
            case 36, 76, 48: picker.select(picker.selected); return true
            case 53: suppressedMention = query; picker.clear(owner: mentionOwner); return true
            default: return false
            }
        }
        func publish(_ editor: RichComposerTextView) {
            guard let storage = editor.textStorage else { return }
            let text = storage.string as NSString
            var lines: [TeamsRichDraft.EditorLine] = []
            var markerRanges: [NSRange?] = []
            var softBreaks: [Bool] = []
            var mentionAppearance: [(NSRange, Bool)] = []
            var offset = 0
            while offset <= text.length {
                let remainder = NSRange(location: offset, length: text.length - offset)
                let newline = text.range(of: "\n", options: [], range: remainder)
                let end = newline.location == NSNotFound ? text.length : newline.location
                var range = NSRange(location: offset, length: end - offset)
                var kind = TeamsRichDraft.Block.Kind.paragraph, depth = 0, prefix = ""
                var markerRange: NSRange?
                let styleOffset = range.length > 0 ? range.location : (newline.location == NSNotFound ? NSNotFound : newline.location)
                if styleOffset != NSNotFound, storage.attribute(.teamsCodeBlock, at: styleOffset, effectiveRange: nil) as? Bool == true { kind = .codeBlock }
                if range.length > 0, let marker = storage.attribute(.teamsBlock, at: range.location, effectiveRange: nil) as? [String: String],
                   let raw = marker["kind"], let candidate = TeamsRichDraft.Block.Kind(rawValue: raw), [.bulletList, .numberedList, .quote].contains(candidate),
                   let markerText = marker["prefix"], let markerDepth = marker["depth"].flatMap(Int.init), (0...12).contains(markerDepth),
                   (markerText as NSString).length <= range.length, text.substring(with: NSRange(location: offset, length: (markerText as NSString).length)) == markerText {
                    kind = candidate; depth = markerDepth; prefix = markerText
                    markerRange = NSRange(location: offset, length: (markerText as NSString).length)
                    range.location += (markerText as NSString).length; range.length -= (markerText as NSString).length
                }
                var runs: [TeamsRichDraft.Run] = []
                var ranges: [NSRange] = []
                if range.length > 0 {
                    storage.enumerateAttributes(in: range) { attrs, span, _ in
                        let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 14)
                        let traits = NSFontManager.shared.traits(of: font)
                        let mentionData = attrs[.teamsMention] as? [String: String]
                        let mention = mentionData.flatMap { data -> TeamsRichDraft.Mention? in
                            guard let mri = data["mri"], let name = data["name"], let id = data["occurrence"].flatMap(UUID.init(uuidString:)) else { return nil }
                            return .init(mri: mri, displayName: name, occurrenceID: id)
                        }
                        runs.append(.init(text: text.substring(with: span), bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask), underline: (attrs[.underlineStyle] as? Int ?? 0) != 0, strike: (attrs[.strikethroughStyle] as? Int ?? 0) != 0, code: attrs[.teamsCode] as? Bool == true, link: attrs[.link] as? URL, mention: mention))
                        ranges.append(span)
                    }
                }
                var runIndex = 0
                while runIndex < runs.count {
                    guard let mention = runs[runIndex].mention else { runIndex += 1; continue }
                    var end = runIndex, label = ""
                    while end < runs.count, runs[end].mention == mention { label += runs[end].text; end += 1 }
                    if label != mention.displayName { invalidMentions.insert(mention.occurrenceID) }
                    if label == mention.displayName, editor.undoManager?.isUndoing == true { invalidMentions.remove(mention.occurrenceID) }
                    if invalidMentions.contains(mention.occurrenceID) {
                        for index in runIndex..<end { runs[index].mention = nil }
                    }
                    for index in runIndex..<end { mentionAppearance.append((ranges[index], !invalidMentions.contains(mention.occurrenceID))) }
                    runIndex = end
                }
                lines.append(.init(kind: kind, depth: depth, prefix: prefix, runs: runs))
                markerRanges.append(markerRange)
                if newline.location == NSNotFound { break }
                softBreaks.append(storage.attribute(.teamsSoftBreak, at: newline.location, effectiveRange: nil) as? Bool == true || storage.attribute(.teamsCodeBlock, at: newline.location, effectiveRange: nil) as? Bool == true)
                offset = end + 1
            }
            var logicalLines: [TeamsRichDraft.EditorLine] = []
            var logicalMarkers: [NSRange?] = []
            for (index, line) in lines.enumerated() {
                if index > 0, softBreaks[index - 1], line.prefix.isEmpty, let previous = logicalLines.popLast() {
                    logicalLines.append(.init(kind: previous.kind, depth: previous.depth, prefix: previous.prefix,
                                              runs: previous.runs + [.init(text: "\n")] + line.runs))
                } else { logicalLines.append(line); logicalMarkers.append(markerRanges[index]) }
            }
            let result = TeamsRichDraft(editorLines: logicalLines)
            for (range, valid) in mentionAppearance {
                storage.addAttribute(.foregroundColor, value: valid ? NSColor.controlAccentColor : NSColor.labelColor, range: range)
                if valid { storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.12), range: range) }
                else { storage.removeAttribute(.backgroundColor, range: range) }
            }
            let canonical = result.editorLines
            if canonical.count == logicalLines.count {
                var selection = editor.selectedRange()
                for index in logicalLines.indices.reversed() {
                    guard let marker = logicalMarkers[index], logicalLines[index].prefix != canonical[index].prefix else { continue }
                    let line = canonical[index]
                    let replacement = NSAttributedString(string: line.prefix, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor, .teamsBlock: ["kind": line.kind.rawValue, "depth": String(line.depth), "prefix": line.prefix]])
                    let delta = replacement.length - marker.length
                    storage.replaceCharacters(in: marker, with: replacement)
                    if selection.location >= NSMaxRange(marker) { selection.location += delta }
                    else if selection.location >= marker.location { selection.location = marker.location + replacement.length }
                }
                if selection.location != NSNotFound, NSMaxRange(selection) <= storage.length { editor.setSelectedRange(selection) }
            }
            lastPublished = result; parent.document = result
        }
        func insertListReturn(in editor: RichComposerTextView) -> Bool {
            guard !editor.hasMarkedText(), let storage = editor.textStorage else { return false }
            let selection = editor.selectedRange(), text = storage.string as NSString
            guard selection.length == 0, selection.location <= text.length else { return false }
            let cursorLine = text.lineRange(for: selection)
            var line = cursorLine
            while line.location > 0, storage.attribute(.teamsSoftBreak, at: line.location - 1, effectiveRange: nil) as? Bool == true {
                let previous = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
                guard previous.location < line.location else { break }
                line = previous
            }
            guard line.length > 0, line.location < storage.length,
                  let marker = storage.attribute(.teamsBlock, at: line.location, effectiveRange: nil) as? [String: String],
                  let kind = marker["kind"], [TeamsRichDraft.Block.Kind.bulletList.rawValue, TeamsRichDraft.Block.Kind.numberedList.rawValue].contains(kind),
                  let prefix = marker["prefix"], let depth = marker["depth"].flatMap(Int.init),
                  (prefix as NSString).length <= line.length,
                  text.substring(with: NSRange(location: line.location, length: (prefix as NSString).length)) == prefix else { return false }
            let bodyStart = line.location + (prefix as NSString).length
            var bodyLength = NSMaxRange(cursorLine) - bodyStart
            if bodyLength > 0, text.substring(with: NSRange(location: NSMaxRange(cursorLine) - 1, length: 1)) == "\n" { bodyLength -= 1 }
            let body = text.substring(with: NSRange(location: bodyStart, length: max(bodyLength, 0)))
            let before = NSAttributedString(attributedString: storage), beforeSelection = selection
            editor.undoManager?.disableUndoRegistration()
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editor.insertText("", replacementRange: NSRange(location: line.location, length: (prefix as NSString).length))
            } else {
                let number = Int(prefix.trimmingCharacters(in: .whitespaces).split(separator: ".").first ?? "") ?? 0
                let next = String(repeating: "  ", count: min(max(depth, 0), 12)) + (kind == TeamsRichDraft.Block.Kind.bulletList.rawValue ? "• " : "\(number + 1). ")
                let insertion = NSMutableAttributedString(string: "\n")
                insertion.append(NSAttributedString(string: next, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor, .teamsBlock: ["kind": kind, "depth": String(depth), "prefix": next]]))
                editor.insertText(insertion, replacementRange: selection)
            }
            var typing = editor.typingAttributes; typing[.teamsBlock] = nil; typing[.foregroundColor] = NSColor.labelColor; editor.typingAttributes = typing
            publish(editor)
            editor.undoManager?.enableUndoRegistration()
            registerUndo(editor, state: before, selection: beforeSelection)
            return true
        }
        func registerUndo(_ editor: RichComposerTextView, state: NSAttributedString, selection: NSRange, label: String = "Format list") {
            editor.undoManager?.registerUndo(withTarget: editor) { [weak self] target in
                guard let self, let storage = target.textStorage else { return }
                let inverse = NSAttributedString(attributedString: storage), inverseSelection = target.selectedRange()
                self.registerUndo(target, state: inverse, selection: inverseSelection, label: label)
                storage.setAttributedString(state)
                if NSMaxRange(selection) <= storage.length { target.setSelectedRange(selection) }
                self.publish(target)
            }
            editor.undoManager?.setActionName(label)
        }
        func apply(_ action: TeamsComposerCommand.Action, to editor: RichComposerTextView) {
            guard !editor.hasMarkedText(), let storage = editor.textStorage else { return }
            editor.window?.makeFirstResponder(editor)
            let range = editor.selectedRange()
            if [.bulletList, .numberedList, .quote, .indent, .outdent].contains(action) {
                applyBlock(action, to: editor, storage: storage, selection: range)
                return
            }
            if case let .mention(person) = action {
                guard !person.displayName.isEmpty else { return }
                var attrs = editor.typingAttributes
                attrs[.teamsMention] = ["mri": person.mri, "name": person.displayName, "occurrence": person.occurrenceID.uuidString]
                attrs[.foregroundColor] = NSColor.controlAccentColor; attrs[.backgroundColor] = NSColor.controlAccentColor.withAlphaComponent(0.12)
                let insertion = NSAttributedString(string: person.displayName, attributes: attrs)
                editor.insertingSelectedMention = true
                editor.insertText(insertion, replacementRange: range)
                editor.insertingSelectedMention = false
                var typing = editor.typingAttributes; typing[.teamsMention] = nil; typing[.foregroundColor] = NSColor.labelColor; typing[.backgroundColor] = nil; editor.typingAttributes = typing
                publish(editor); return
            }
            func enabled(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
                let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 14)
                switch action {
                case .bold: return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
                case .italic: return NSFontManager.shared.traits(of: font).contains(.italicFontMask)
                case .underline: return (attrs[.underlineStyle] as? Int ?? 0) != 0
                case .strike: return (attrs[.strikethroughStyle] as? Int ?? 0) != 0
                case .code: return attrs[.teamsCode] as? Bool == true
                case .link, .mention, .bulletList, .numberedList, .quote, .indent, .outdent: return false
                }
            }
            func changed(_ attrs: [NSAttributedString.Key: Any], desired: Bool? = nil) -> [NSAttributedString.Key: Any] {
                var result = attrs
                let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 14)
                let manager = NSFontManager.shared
                let turnOn = desired ?? !enabled(attrs)
                switch action {
                case .bold, .italic:
                    let trait: NSFontTraitMask = action == .bold ? .boldFontMask : .italicFontMask
                    result[.font] = turnOn ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
                case .underline:
                    result[.underlineStyle] = turnOn ? NSUnderlineStyle.single.rawValue : 0
                case .strike:
                    result[.strikethroughStyle] = turnOn ? NSUnderlineStyle.single.rawValue : 0
                case .code:
                    result[.teamsCode] = turnOn
                    var replacement = turnOn ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) : NSFont.systemFont(ofSize: 14)
                    let traits = manager.traits(of: font)
                    if traits.contains(.boldFontMask) { replacement = manager.convert(replacement, toHaveTrait: .boldFontMask) }
                    if traits.contains(.italicFontMask) { replacement = manager.convert(replacement, toHaveTrait: .italicFontMask) }
                    result[.font] = replacement
                case let .link(url): result[.link] = url
                case .mention, .bulletList, .numberedList, .quote, .indent, .outdent: break
                }
                return result
            }
            if range.length == 0 { editor.typingAttributes = changed(editor.typingAttributes) }
            else if range.location != NSNotFound, NSMaxRange(range) <= storage.length {
                guard editor.shouldChangeText(in: range, replacementString: nil) else { return }
                var spans: [([NSAttributedString.Key: Any], NSRange)] = []
                storage.enumerateAttributes(in: range) { attrs, span, _ in spans.append((attrs, span)) }
                let desired = !spans.allSatisfy { enabled($0.0) }
                let keys: [NSAttributedString.Key]
                switch action { case .bold, .italic: keys = [.font]; case .underline: keys = [.underlineStyle]; case .strike: keys = [.strikethroughStyle]; case .code: keys = [.font, .teamsCode]; case .link: keys = [.link]; case .mention, .bulletList, .numberedList, .quote, .indent, .outdent: keys = [] }
                for (attrs, span) in spans {
                    let result = changed(attrs, desired: desired)
                    for key in keys {
                        if let value = result[key] { storage.addAttribute(key, value: value, range: span) }
                        else { storage.removeAttribute(key, range: span) }
                    }
                }
                editor.didChangeText(); publish(editor)
            }
        }

        private func applyBlock(_ action: TeamsComposerCommand.Action, to editor: RichComposerTextView, storage: NSTextStorage, selection: NSRange) {
            guard selection.location != NSNotFound, NSMaxRange(selection) <= storage.length else { return }
            let text = storage.string as NSString
            let paragraphRange = text.lineRange(for: selection)
            if paragraphRange.location > 0, storage.attribute(.teamsSoftBreak, at: paragraphRange.location - 1, effectiveRange: nil) as? Bool == true { return }
            var hasSoftBreak = false
            if paragraphRange.length > 0 {
                storage.enumerateAttribute(.teamsSoftBreak, in: paragraphRange) { value, _, stop in
                    if value as? Bool == true { hasSoftBreak = true; stop.pointee = true }
                }
            }
            guard !hasSoftBreak else { return }
            let target: TeamsRichDraft.Block.Kind = action == .bulletList ? .bulletList : (action == .numberedList ? .numberedList : .quote)
            var segments: [(NSRange, String, Int, TeamsRichDraft.Block.Kind?)] = []
            var offset = paragraphRange.location
            repeat {
                let remainder = NSRange(location: offset, length: NSMaxRange(paragraphRange) - offset)
                let newline = text.range(of: "\n", options: [], range: remainder)
                let end = newline.location == NSNotFound ? NSMaxRange(paragraphRange) : newline.location
                let line = NSRange(location: offset, length: end - offset)
                var prefix = "", depth = 0, existing: TeamsRichDraft.Block.Kind?
                if line.length > 0, let marker = storage.attribute(.teamsBlock, at: line.location, effectiveRange: nil) as? [String: String],
                   let raw = marker["kind"], let kind = TeamsRichDraft.Block.Kind(rawValue: raw), let value = marker["prefix"],
                   let level = marker["depth"].flatMap(Int.init), (value as NSString).length <= line.length,
                   text.substring(with: NSRange(location: line.location, length: (value as NSString).length)) == value {
                    prefix = value; depth = min(max(level, 0), 12); existing = kind
                }
                segments.append((line, prefix, depth, existing))
                if newline.location == NSNotFound || end + 1 >= NSMaxRange(paragraphRange) { break }
                offset = end + 1
            } while offset <= NSMaxRange(paragraphRange)
            let adjustDepth = action == .indent || action == .outdent
            if adjustDepth {
                guard segments.allSatisfy({ $0.3 == .bulletList || $0.3 == .numberedList }) else { return }
                if action == .outdent, segments.contains(where: { $0.2 == 0 }) { return }
                if action == .indent {
                    guard paragraphRange.location > 0 else { return }
                    var previous = text.lineRange(for: NSRange(location: paragraphRange.location - 1, length: 0))
                    while previous.location > 0, storage.attribute(.teamsSoftBreak, at: previous.location - 1, effectiveRange: nil) as? Bool == true {
                        let earlier = text.lineRange(for: NSRange(location: previous.location - 1, length: 0))
                        guard earlier.location < previous.location else { break }
                        previous = earlier
                    }
                    guard previous.location < storage.length,
                          let marker = storage.attribute(.teamsBlock, at: previous.location, effectiveRange: nil) as? [String: String],
                          let raw = marker["kind"], [TeamsRichDraft.Block.Kind.bulletList.rawValue, TeamsRichDraft.Block.Kind.numberedList.rawValue].contains(raw),
                          let previousDepth = marker["depth"].flatMap(Int.init), segments[0].2 <= previousDepth, segments.allSatisfy({ $0.2 < 12 }) else { return }
                }
            }
            let clear = segments.allSatisfy { $0.3 == target }
            let replacement = NSMutableAttributedString(string: "")
            for (index, segment) in segments.enumerated() {
                if index > 0 { replacement.append(NSAttributedString(string: "\n")) }
                let skip = (segment.1 as NSString).length
                if adjustDepth || !clear {
                    let kind = adjustDepth ? (segment.3 ?? target) : target
                    let depth = adjustDepth ? segment.2 + (action == .indent ? 1 : -1) : segment.2
                    let indent = String(repeating: "  ", count: depth)
                    let prefix = kind == .quote ? "│ " : indent + (kind == .bulletList ? "• " : "\(index + 1). ")
                    replacement.append(NSAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor, .teamsBlock: ["kind": kind.rawValue, "depth": String(depth), "prefix": prefix]]))
                }
                let body = NSRange(location: segment.0.location + skip, length: segment.0.length - skip)
                if body.length > 0 { replacement.append(storage.attributedSubstring(from: body)) }
            }
            let hadTrailingNewline = NSMaxRange(paragraphRange) > 0 && NSMaxRange(paragraphRange) <= text.length &&
                text.substring(with: NSRange(location: NSMaxRange(paragraphRange) - 1, length: 1)) == "\n"
            if hadTrailingNewline {
                replacement.append(NSAttributedString(string: "\n"))
            }
            let before = NSAttributedString(attributedString: storage), beforeSelection = selection
            editor.undoManager?.disableUndoRegistration()
            editor.insertText(replacement, replacementRange: paragraphRange)
            let selectableLength = max(0, replacement.length - (hadTrailingNewline ? 1 : 0))
            editor.setSelectedRange(segments.count == 1 ? NSRange(location: paragraphRange.location + selectableLength, length: 0) : NSRange(location: paragraphRange.location, length: selectableLength))
            publish(editor)
            editor.undoManager?.enableUndoRegistration()
            registerUndo(editor, state: before, selection: beforeSelection)
        }
    }
}

final class RichComposerTextView: ComposerTextView {
    var handleMentionKey: ((NSEvent) -> Bool)?
    var compositionStateChanged: (() -> Void)?
    var handleListReturn: (() -> Bool)?
    var listDeletionCompleted: ((NSAttributedString, NSRange) -> Void)?
    var insertingSelectedMention = false
    private var handlingListReplacement = false
    private func deleteListSelection(_ operation: () -> Void) -> Bool {
        let range = selectedRange()
        guard !hasMarkedText(), range.length > 0, let storage = textStorage, NSMaxRange(range) <= storage.length,
              (storage.string as NSString).substring(with: range).contains("\n") else { return false }
        var containsMarker = false
        storage.enumerateAttribute(.teamsBlock, in: range) { value, _, stop in
            if value != nil { containsMarker = true; stop.pointee = true }
        }
        guard containsMarker else { return false }
        let before = NSAttributedString(attributedString: storage)
        handlingListReplacement = true
        undoManager?.disableUndoRegistration()
        operation()
        undoManager?.enableUndoRegistration()
        handlingListReplacement = false
        listDeletionCompleted?(before, range)
        return true
    }
    override func deleteBackward(_ sender: Any?) {
        if !deleteListSelection({ super.deleteBackward(sender) }) { super.deleteBackward(sender) }
    }
    override func deleteForward(_ sender: Any?) {
        if !deleteListSelection({ super.deleteForward(sender) }) { super.deleteForward(sender) }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard !insertingSelectedMention else { super.insertText(insertString, replacementRange: replacementRange); return }
        if !handlingListReplacement, replacementRange.location == NSNotFound || replacementRange == selectedRange() {
            if deleteListSelection({ self.insertText(insertString, replacementRange: replacementRange) }) { return }
        }
        var attrs = typingAttributes
        if attrs[.teamsMention] != nil {
            attrs[.teamsMention] = nil; attrs[.foregroundColor] = NSColor.labelColor; attrs[.backgroundColor] = nil
            typingAttributes = attrs
        }
        if let text = insertString as? String {
            let destination = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            if hasMarkedText() { super.insertText(text, replacementRange: replacementRange) }
            else { super.insertText(NSAttributedString(string: text, attributes: typingAttributes), replacementRange: replacementRange) }
            let inserted = NSRange(location: destination.location, length: (text as NSString).length)
            if let storage = textStorage, inserted.location != NSNotFound, NSMaxRange(inserted) <= storage.length, inserted.length > 0 {
                storage.removeAttribute(.teamsMention, range: inserted)
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: inserted)
                storage.removeAttribute(.backgroundColor, range: inserted)
                didChangeText()
            }
        } else { super.insertText(insertString, replacementRange: replacementRange) }
    }
    override func keyDown(with event: NSEvent) {
        if !isEditable, event.keyCode == 36 || event.keyCode == 76 { return }
        if !hasMarkedText(), handleMentionKey?(event) == true { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !sendOnReturn, modifiers.isDisjoint(with: [.command, .shift, .option, .control]), handleListReturn?() == true { return }
        super.keyDown(with: event)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        compositionStateChanged?()
    }
    override func unmarkText() {
        super.unmarkText()
        compositionStateChanged?()
    }
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { insertText(text, replacementRange: selectedRange()) }
    }
}
