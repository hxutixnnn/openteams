import AppKit
import SwiftUI
import TeamsCore

struct TeamsMessageRow: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    let message: TeamsRenderedMessage
    let compact: Bool
    let grouped: Bool
    let accountID: String
    let canEdit: Bool
    let canReact: Bool
    let mediaRevision: UUID
    let mediaRefreshRevision: UUID
    let actions: TeamsMessageRowActions
    var filePreviewConnected = true
    var filePreviewIdentity: UUID? = nil
    var contextActionsOnly = false
    var deletionStage: TeamsPendingDeletion.Stage? = nil
    var deletionMessage: String? = nil
    var canDelete = true

    nonisolated static func == (lhs: TeamsMessageRow, rhs: TeamsMessageRow) -> Bool {
        lhs.message == rhs.message && lhs.compact == rhs.compact && lhs.grouped == rhs.grouped
            && lhs.accountID == rhs.accountID && lhs.canEdit == rhs.canEdit && lhs.canReact == rhs.canReact
            && lhs.mediaRevision == rhs.mediaRevision && lhs.mediaRefreshRevision == rhs.mediaRefreshRevision
            && lhs.actions === rhs.actions && lhs.filePreviewConnected == rhs.filePreviewConnected
            && lhs.filePreviewIdentity == rhs.filePreviewIdentity && lhs.contextActionsOnly == rhs.contextActionsOnly
            && lhs.deletionStage == rhs.deletionStage && lhs.deletionMessage == rhs.deletionMessage
            && lhs.canDelete == rhs.canDelete
    }
    @FocusState private var actionsFocused: Bool
    @ViewState<Bool> private var isHovered = false
    @ViewState<Bool> private var showReactionPicker = false
    @ViewState<Set<Int>> private var expandedReplies = []
    @ViewState<TeamsFileLink?> private var previewFile = nil

    private var isMe: Bool {
        message.author.id == accountID || message.author.id == "8:orgid:\(accountID)"
    }
    private var textAccent: Color {
        colorScheme == .dark ? Color(red: 0.72, green: 0.70, blue: 1.0) : Color(red: 0.23, green: 0.20, blue: 0.55)
    }
    private let quickReactions = [("like", "👍", "Like"), ("heart", "❤️", "Love"), ("laugh", "😆", "Laugh"), ("surprised", "😮", "Surprised")]
    private func mine(_ key: String) -> Bool {
        message.reactions.contains { $0.key == key && ($0.userIDs.contains(accountID) || $0.userIDs.contains("8:orgid:" + accountID)) }
    }

    var body: some View {
        #if DEBUG
        TeamsBenchmarkCounters.noteRowBody(message.id)
        #endif
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if grouped { Color.clear.accessibilityHidden(true) }
                else { PersonAvatar(person: message.author, size: compact ? 28 : 32, revision: mediaRevision, refreshRevision: mediaRefreshRevision, loadPhoto: actions.loadPhoto) }
            }
            .frame(width: compact ? 28 : 32, height: grouped ? 1 : (compact ? 28 : 32))
            VStack(alignment: .leading, spacing: 4) {
                if !grouped {
                    HStack(spacing: 8) {
                        Text(isMe ? "You" : message.author.name).font(.callout.weight(.semibold))
                        Text(message.createdAt, format: .dateTime.hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        if message.isEdited { Text("Edited").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let deletionStage {
                    HStack {
                        Text(deletionMessage ?? (deletionStage == .accepted ? "Deletion accepted; check status." : (deletionStage == .rejected ? "Deletion was rejected." : "Deletion may have succeeded; check status.")))
                        if deletionStage == .rejected { Button("Dismiss") { actions.action("dismiss-delete") } }
                        else { Button("Check status") { actions.action("check-delete") } }
                    }.font(.caption).foregroundStyle(.secondary).buttonStyle(.link)
                }
                if message.isDeleted {
                    Text("This message was deleted.").font(.callout).italic().foregroundStyle(.secondary)
                } else {
                    ForEach(Array(blockGroups.enumerated()), id: \.offset) { _, group in
                        if let block = group.first, let reply = block.reply, let groupID = block.quoteGroup {
                            replyCard(reply, groupID: groupID)
                        } else if group.first?.quoteGroup != nil {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(ChatTheme.accent.opacity(0.6)).frame(width: 3)
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(group.enumerated()), id: \.offset) { _, block in blockView(block) }
                                }.foregroundStyle(.secondary).padding(.vertical, 8)
                            }
                            .padding(.horizontal, 8)
                            .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous))
                        } else if let block = group.first { blockView(block) }
                    }
                    if message.body.blocks.isEmpty && !message.body.text.isEmpty {
                        Text(message.body.text).font(.system(size: compact ? 13 : 14))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if grouped && message.isEdited { Text("Edited").font(.caption2).foregroundStyle(.secondary) }
                    if !message.reactions.isEmpty {
                      ReactionFlowLayout(spacing: 5) {
                            ForEach(message.reactions) { reaction in
                                let selected = mine(reaction.key)
                                let symbol = TeamsReactionPresentation.symbol(for: reaction.key)
                                let name = TeamsReactionPresentation.name(for: reaction.key)
                                Button { actions.action(selected ? "remove:" + reaction.key : reaction.key) } label: {
                                    Text("\(symbol == "✦" ? "✦ " + String(name.prefix(16)) : symbol) \(reaction.userIDs.count)")
                                        .font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(selected ? ChatTheme.accent.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                                        .overlay(Capsule().strokeBorder(selected ? ChatTheme.accent.opacity(0.45) : .clear))
                                }.buttonStyle(.plain).disabled(!canReact)
                                    .help(selected ? "Remove reaction" : "Add reaction")
                                    .accessibilityLabel("\(name), \(reaction.userIDs.count) reactions\(selected ? ", includes you; remove reaction" : "; add reaction")")
                            }
                            Menu {
                                ForEach(quickReactions, id: \.0) { key, symbol, label in
                                    Button { actions.action(mine(key) ? "remove:" + key : key) } label: {
                                        Text("\(symbol) \(label)\(mine(key) ? " ✓" : "")")
                                    }
                                }
                            } label: { Label("Add reaction", systemImage: "face.smiling").labelStyle(.iconOnly).font(.caption) }
                                .menuStyle(.borderlessButton).foregroundStyle(.secondary).fixedSize().disabled(!canReact)
                                .help("Add reaction").accessibilityLabel("Add reaction")
                    }
                    }
                    ForEach(message.files) { file in
                        VStack(alignment: .leading, spacing: 6) {
                            if let preview = file.preview {
                                TeamsInlineImageView(image: preview, revision: mediaRevision, refreshRevision: mediaRefreshRevision, load: actions.loadImage)
                            }
                            Link(destination: file.url) {
                                Label(file.title, systemImage: "doc.fill")
                                    .font(.callout).lineLimit(2)
                            }
                            if file.sharePoint?.supportsPreview == true, actions.loadFilePreview != nil {
                                Button("Preview") { previewFile = file }.buttonStyle(.link)
                                    .disabled(!filePreviewConnected)
                                    .accessibilityLabel("Preview \(file.title)")
                            }
                        }
                    }
                    if message.body.hasUnsupportedContent {
                        Text("Some content is unavailable.").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(isMe ? "You" : message.author.name), \(message.createdAt.formatted(date: .omitted, time: .shortened))\(message.isEdited ? ", edited" : "")")
        .padding(.vertical, grouped ? 4 : (compact ? 6 : 8))
        .contentShape(Rectangle())
        .onHover { hovered in
            #if DEBUG
            TeamsBenchmarkCounters.hoverChanges += 1
            #endif
            isHovered = hovered
        }
        .focusable()
        .focused($actionsFocused)
        .overlay(alignment: .topLeading) {
            if grouped && isHovered {
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: compact ? 28 : 32)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !contextActionsOnly && (isHovered || actionsFocused || showReactionPicker) && !message.isDeleted {
                HStack(spacing: 2) {
                    if message.reactions.isEmpty {
                        Button { showReactionPicker.toggle() } label: { Image(systemName: "face.smiling") }
                            .disabled(!canReact).help("Add reaction").accessibilityLabel("Add reaction")
                            .popover(isPresented: $showReactionPicker, arrowEdge: .top) {
                                HStack(spacing: 4) {
                                    ForEach(quickReactions, id: \.0) { key, symbol, label in
                                        Button { showReactionPicker = false; actions.action(mine(key) ? "remove:" + key : key) } label: { Text(symbol) }
                                            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
                                    }
                                }.padding(8)
                            }
                    }
                    Button { actions.action("reply") } label: { Image(systemName: "arrowshape.turn.up.left") }
                        .help("Reply").accessibilityLabel("Reply to message")
                    Menu {
                        Button("Copy Message") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.body.text, forType: .string)
                        }
                        Button("Mark Unread") { actions.action("unread") }
                        if isMe {
                            if canEdit { Button("Edit Message") { actions.action("edit") } }
                            Button("Delete Message", role: .destructive) { actions.action("delete") }.disabled(!canDelete)
                        }
                    } label: { Image(systemName: "ellipsis") }
                        .help("More message options").accessibilityLabel("More message options")
                }
                .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
                .padding(5)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: TeamsSurface.controlRadius))
                .offset(y: -8)
            }
        }
        .contextMenu {
            if !message.isDeleted {
                Button("Copy Message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body.text, forType: .string)
                }
            }
            if !contextActionsOnly && !message.isDeleted {
                Button("Reply") { actions.action("reply") }
                Menu("React") {
                    ForEach(quickReactions, id: \.0) { key, symbol, label in
                        Button("\(symbol) \(mine(key) ? "Remove " : "")\(label)") { actions.action(mine(key) ? "remove:" + key : key) }
                    }
                }.disabled(!canReact)
                Button("Mark Unread") { actions.action("unread") }
                if isMe {
                    if canEdit { Button("Edit Message") { actions.action("edit") } }
                    Button("Delete Message", role: .destructive) { actions.action("delete") }.disabled(!canDelete)
                }
            }
        }
        .sheet(item: $previewFile) { file in
            if let attachment = file.sharePoint, let loadFilePreview = actions.loadFilePreview {
                TeamsFilePreviewSheet(file: file, attachment: attachment, load: loadFilePreview)
            }
        }
        .onChange(of: filePreviewConnected) { _, connected in if !connected { previewFile = nil } }
        .onChange(of: filePreviewIdentity) { _, _ in previewFile = nil }
        .onChange(of: message.files) { _, files in if let selected = previewFile, !files.contains(selected) { previewFile = nil } }
    }

    private func replyCard(_ reply: TeamsReplyPreview, groupID: Int) -> some View {
        let expanded = expandedReplies.contains(groupID)
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(ChatTheme.accent.opacity(0.6)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(actions.replyAuthor(reply)).font(.caption.weight(.semibold)).lineLimit(1)
                    if let date = reply.date { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption2) }
                    Spacer(minLength: 4)
                    Button {
                        if expanded { expandedReplies.remove(groupID) } else { expandedReplies.insert(groupID) }
                    } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                        .help(expanded ? "Collapse quote" : "Expand quote")
                        .accessibilityLabel(expanded ? "Collapse quote" : "Expand quote")
                    if let id = reply.messageID, actions.canJumpToMessage(id) {
                        Button { actions.jumpToMessage(id) } label: { Image(systemName: "arrow.up.left") }
                            .help("Show original message").accessibilityLabel("Show original message")
                    }
                }.foregroundStyle(.secondary)
                    .font(.caption2).buttonStyle(.borderless)
                if !reply.excerpt.isEmpty {
                    Text(reply.excerpt).font(.system(size: compact ? 13 : 14)).foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 1).textSelection(.enabled)
                }
            }.padding(.vertical, 8)
        }
        .padding(.horizontal, 8)
        .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous))
    }

    private var blockGroups: [[TeamsTextBlock]] {
        var groups: [[TeamsTextBlock]] = []
        for block in message.body.blocks {
            if let id = block.quoteGroup,
               let last = groups.last?.last, last.quoteGroup == id {
                groups[groups.count - 1].append(block)
            } else { groups.append([block]) }
        }
        return groups
    }

    @ViewBuilder private func blockView(_ block: TeamsTextBlock) -> some View {
        switch block.kind {
        case .paragraph:
            richText(block).lineSpacing(3)
        case .quote:
            richText(block)
        case .code:
            Text(block.runs.map(\.text).joined()).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: TeamsSurface.cardRadius, style: .continuous))
        case .image:
            if let image = block.image {
                TeamsInlineImageView(image: image, revision: mediaRevision, refreshRevision: mediaRefreshRevision, load: actions.loadImage)
            }
        }
    }

    private func richText(_ block: TeamsTextBlock) -> some View {
        Text(attributed(block.runs))
            .font(.system(size: compact ? 13 : 14))
            .tint(textAccent)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func attributed(_ runs: [TeamsTextRun]) -> AttributedString {
        #if DEBUG
        TeamsBenchmarkCounters.rowText += 1
        #endif
        var result = AttributedString()
        for run in runs {
            var value = AttributedString(run.text)
            var font = Font.system(size: compact ? 13 : 14, design: run.code ? .monospaced : .default)
            if run.bold || run.isMention { font = font.weight(.semibold) }
            if run.italic { font = font.italic() }
            value.font = font
            if run.underline { value.underlineStyle = .single }
            if run.strike { value.strikethroughStyle = .single }
            if run.isMention || run.link != nil { value.foregroundColor = textAccent }
            if let link = run.link { value.link = link }
            result.append(value)
        }
        return result
    }
}

private struct TeamsInlineImageView: View {
    let image: TeamsInlineImage
    let revision: UUID
    let refreshRevision: UUID
    let load: (TeamsInlineImage, Bool) async throws -> Data
    @ViewState<NSImage?> private var picture = nil
    @ViewState<Bool> private var failed = false
    @ViewState<UUID?> private var loadedRevision = nil
    @ViewState<URL?> private var loadedURL = nil
    @ViewState<Bool> private var showPreview = false
    @ViewState<Int> private var retryCount = 0
    @ViewState<NSImage?> private var fullPicture = nil

    private var aspect: CGFloat {
        guard let width = image.width, let height = image.height else { return 1.5 }
        return min(max(CGFloat(width) / CGFloat(height), 0.4), 3)
    }
    var body: some View {
        Color.clear.aspectRatio(aspect, contentMode: .fit).frame(maxWidth: 400, maxHeight: 320)
        .overlay(alignment: .leading) {
            if loadedRevision == revision, loadedURL == image.url, let picture {
                Button { showPreview = true } label: {
                    AnimatedTeamsImage(image: picture)
                        .aspectRatio(picture.size.width / max(picture.size.height, 1), contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: TeamsSurface.cardRadius, style: .continuous))
                }.buttonStyle(.plain).accessibilityLabel("Preview \(image.alternativeText)")
            } else if loadedRevision == revision && loadedURL == image.url && failed {
                HStack(spacing: 8) {
                    Label("\(image.alternativeText) unavailable", systemImage: "photo")
                    Button("Retry") { retryCount += 1 }.buttonStyle(.borderless)
                }.font(.callout)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading \(image.alternativeText)")
            }
        }
        .task(id: revision.uuidString + refreshRevision.uuidString + image.url.absoluteString + "-\(retryCount)") {
            fullPicture = nil
            if loadedRevision == revision, loadedURL == image.url, picture != nil { return }
            picture = nil; failed = false; loadedRevision = nil; loadedURL = nil
            do { let result = try await load(image, false); try Task.checkCancellation(); guard let decoded = NSImage(data: result) else { failed = true; loadedRevision = revision; loadedURL = image.url; return }; picture = decoded; loadedRevision = revision; loadedURL = image.url }
            catch is CancellationError { }
            catch { if !Task.isCancelled { failed = true; loadedRevision = revision; loadedURL = image.url } }
        }
        .sheet(isPresented: $showPreview) {
            if loadedRevision == revision, loadedURL == image.url, let picture {
                VStack(alignment: .trailing, spacing: 12) {
                    Button("Close") { showPreview = false }
                    let displayed = fullPicture ?? picture
                    AnimatedTeamsImage(image: displayed).aspectRatio(displayed.size.width / max(displayed.size.height, 1), contentMode: .fit)
                }
                .padding(20)
                .background(TeamsSurface.window)
                .frame(minWidth: 500, minHeight: 350)
                .task(id: revision.uuidString + image.url.absoluteString) {
                    fullPicture = nil
                    if let data = try? await load(image, true), !Task.isCancelled { fullPicture = NSImage(data: data) }
                }
            }
        }
        .onChange(of: showPreview) { _, showing in if !showing { fullPicture = nil } }
        .onChange(of: revision) { _, _ in fullPicture = nil; showPreview = false }
        .onChange(of: image.url) { _, _ in fullPicture = nil; showPreview = false }
    }
}

private struct AnimatedTeamsImage: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let view = FittingImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) { view.image = image }
}

private final class FittingImageView: NSImageView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}
