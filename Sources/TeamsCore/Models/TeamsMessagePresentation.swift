import Foundation
import SwiftSoup

public struct TeamsTextRun: Hashable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    public var code = false
    public var isMention = false
    public var link: URL?
    public init(text: String) { self.text = text }
}

public struct TeamsTextBlock: Hashable, Sendable {
    public enum Kind: String, Sendable { case paragraph, quote, code, image }
    public let kind: Kind
    public let runs: [TeamsTextRun]
    public let quoteGroup: Int?
    public let image: TeamsInlineImage?
    public let reply: TeamsReplyPreview?
    public var text: String { runs.map(\.text).joined() }
    public init(kind: Kind = .paragraph, runs: [TeamsTextRun], quoteGroup: Int? = nil, image: TeamsInlineImage? = nil, reply: TeamsReplyPreview? = nil) {
        self.kind = kind; self.runs = runs; self.quoteGroup = quoteGroup; self.image = image; self.reply = reply
    }
}

public struct TeamsReplyPreview: Hashable, Sendable {
    public let messageID: String?
    public let senderID: String?
    public let author: String
    public let date: Date?
    public let excerpt: String

    public func resolvedAuthor(original: TeamsWebMessage?, members: [TeamsWebMember]) -> String {
        if let name = original?.imDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let id = senderID ?? original?.senderID
        if let id, let member = members.first(where: { $0.mri == id || $0.objectId == id || "8:orgid:" + ($0.objectId ?? "") == id }),
           let name = member.preferredDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return author
    }
}

public struct TeamsInlineImage: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    public let alternativeText: String
    public let width: Int?
    public let height: Int?
    public var description: String { "TeamsInlineImage(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct TeamsMessageBody: Hashable, Sendable {
    public let text: String
    public let blocks: [TeamsTextBlock]
    public let hasUnsupportedContent: Bool
    public init(text: String, blocks: [TeamsTextBlock], hasUnsupportedContent: Bool = false) {
        self.text = text; self.blocks = blocks; self.hasUnsupportedContent = hasUnsupportedContent
    }
}

public struct TeamsMessageReaction: Identifiable, Hashable, Sendable {
    public let key: String
    public let userIDs: [String]
    public var id: String { key }
}

public struct TeamsFileLink: Identifiable, Hashable, Sendable {
    public let title: String
    public let url: URL
    public let preview: TeamsInlineImage?
    public let sharePoint: TeamsSharePointAttachment?
    public var id: String { url.absoluteString }
}

public struct TeamsSharePointAttachment: Hashable, Sendable {
    public let baseURL: URL
    public let objectURL: URL
    public let fileID: String
    public let accountScope: String
    public let accountRevision: UUID
    public let chatID: String
    public let messageID: String
    public let contextRevision: UUID?
    public init(baseURL: URL, objectURL: URL, fileID: String, accountScope: String, accountRevision: UUID, chatID: String, messageID: String, contextRevision: UUID? = nil) {
        self.baseURL = baseURL; self.objectURL = objectURL; self.fileID = fileID; self.accountScope = accountScope
        self.accountRevision = accountRevision; self.chatID = chatID; self.messageID = messageID; self.contextRevision = contextRevision
    }
    public var resource: TeamsSharePointResource? { TeamsSharePointResource(baseURL: baseURL, objectURL: objectURL) }
    public var supportsImagePreview: Bool { ["png", "jpg", "jpeg", "heic", "heif"].contains(objectURL.pathExtension.lowercased()) }
    public var supportsPDFPreview: Bool { objectURL.pathExtension.lowercased() == "pdf" }
    public var supportsPreview: Bool { supportsImagePreview || supportsPDFPreview }
}

public struct TeamsRenderedMessage: Identifiable, Hashable, Sendable {
    public let id: String
    public let author: Person
    public let createdAt: Date
    public let body: TeamsMessageBody
    public let isDeleted: Bool
    public let isEdited: Bool
    public let files: [TeamsFileLink]
    public let reactions: [TeamsMessageReaction]

    public init(_ message: TeamsWebMessage, people: [String: Person] = [:], accountScope: String? = nil, accountRevision: UUID? = nil, chatID: String? = nil, contextRevision: UUID? = nil) {
        id = message.id
        let rawID = message.senderID ?? "unknown"
        let senderID = rawID.hasPrefix("https://") ? URL(string: rawID)?.lastPathComponent ?? rawID : rawID
        author = Person(id: senderID, name: message.imDisplayName.flatMap { $0.isEmpty ? nil : $0 }
                        ?? people[senderID]?.name ?? "Teams")
        createdAt = message.arrivalDate ?? Date(timeIntervalSince1970: 0)
        let properties: [String: TeamsWebJSONValue]
        if case let .object(value)? = message.properties { properties = value } else { properties = [:] }
        func positive(_ value: TeamsWebJSONValue?) -> Bool {
            switch value {
            case .number(let number): number > 0
            case .string(let string): string != "0" && !string.isEmpty && string != "false"
            case .bool(let flag): flag
            default: false
            }
        }
        isDeleted = positive(properties["deletetime"]) || positive(properties["deleteTime"])
        isEdited = positive(properties["edittime"]) || positive(properties["editTime"])
        files = isDeleted ? [] : Self.fileLinks(properties["files"], accountScope: accountScope, accountRevision: accountRevision, chatID: chatID, messageID: message.id, contextRevision: contextRevision)
        reactions = isDeleted ? [] : Self.reactionList(properties["emotions"])
        if isDeleted {
            body = TeamsMessageBody(text: "Message deleted", blocks: [.init(runs: [.init(text: "Message deleted")])])
        } else {
            body = TeamsBodyParser.parse(message.content ?? "", messageType: message.messageType)
        }
    }

    private static func reactionList(_ value: TeamsWebJSONValue?) -> [TeamsMessageReaction] {
        let raw: TeamsWebJSONValue?
        if case let .string(encoded)? = value, encoded.utf8.count <= 128_000 {
            raw = try? JSONDecoder().decode(TeamsWebJSONValue.self, from: Data(encoded.utf8))
        } else { raw = value }
        guard case let .array(items)? = raw else { return [] }
        var seen = Set<String>()
        return items.prefix(100).compactMap { item in
            guard case let .object(fields) = item, let key = fields["key"]?.stringValue, !key.isEmpty,
                  key.utf8.count <= 128, seen.insert(key).inserted,
                  case let .array(users)? = fields["users"] else { return nil }
            let ids = users.prefix(500).compactMap { user -> String? in
                guard case let .object(fields) = user, let id = fields["mri"]?.stringValue, !id.isEmpty else { return nil }
                return id
            }
            return ids.isEmpty ? nil : TeamsMessageReaction(key: key, userIDs: ids)
        }
    }

    private static func fileLinks(_ value: TeamsWebJSONValue?, accountScope: String?, accountRevision: UUID?, chatID: String?, messageID: String, contextRevision: UUID?) -> [TeamsFileLink] {
        let raw: TeamsWebJSONValue?
        if case let .string(encoded)? = value, encoded.utf8.count <= 128_000 {
            raw = try? JSONDecoder().decode(TeamsWebJSONValue.self, from: Data(encoded.utf8))
        } else { raw = value }
        guard case let .array(items)? = raw else { return [] }
        var seen = Set<URL>()
        return items.prefix(50).compactMap { item in
            guard case let .object(fields) = item else { return nil }
            let legacyURL: String?
            if case let .object(info)? = fields["fileInfo"] { legacyURL = info["fileUrl"]?.stringValue } else { legacyURL = nil }
            let address = (["openUrl", "shareUrl", "objectUrl"].compactMap { fields[$0]?.stringValue } + [legacyURL].compactMap { $0 }).first { value in
                guard let url = TeamsBodyParser.safeLink(value) else { return false }
                return url.scheme?.lowercased() == "https"
            }
            guard let address, let url = TeamsBodyParser.safeLink(address), seen.insert(url).inserted else { return nil }
            let title = fields["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = String((title?.isEmpty == false ? title! : "Open attachment").prefix(200))
            var preview: TeamsInlineImage?
            if case let .object(fields)? = fields["filePreview"], let raw = fields["previewUrl"]?.stringValue,
               raw.utf8.count <= 8192, let parts = URLComponents(string: raw), parts.scheme == "https",
               parts.host != nil, parts.user == nil, parts.password == nil, parts.fragment == nil, let previewURL = parts.url {
                func dimension(_ value: TeamsWebJSONValue?) -> Int? {
                    let number: Int?
                    switch value {
                    case .number(let n): number = NSDecimalNumber(decimal: n).intValue
                    case .string(let n): number = Int(n)
                    default: number = nil
                    }
                    guard let number, (1...16384).contains(number) else { return nil }
                    return number
                }
                preview = TeamsInlineImage(url: previewURL, alternativeText: label,
                                           width: dimension(fields["previewWidth"]), height: dimension(fields["previewHeight"]))
            }
            var attachment: TeamsSharePointAttachment?
            let fileID: String?, baseValue: String?, objectValue: String?
            if case .number(2)? = fields["version"] {
                fileID = fields["id"]?.stringValue; baseValue = fields["baseUrl"]?.stringValue; objectValue = fields["objectUrl"]?.stringValue
            } else if case let .object(info)? = fields["fileInfo"] {
                fileID = fields["itemid"]?.stringValue; baseValue = info["siteUrl"]?.stringValue; objectValue = info["fileUrl"]?.stringValue
            } else { fileID = nil; baseValue = nil; objectValue = nil }
            if let accountScope, let accountRevision, let chatID, let id = fileID,
               !id.isEmpty, id.utf8.count <= 1024, let base = baseValue.flatMap(URL.init(string:)),
               let object = objectValue.flatMap(URL.init(string:)),
               TeamsSharePointResource(baseURL: base, objectURL: object) != nil {
                attachment = TeamsSharePointAttachment(baseURL: base, objectURL: object, fileID: id, accountScope: accountScope,
                                                       accountRevision: accountRevision, chatID: chatID, messageID: messageID, contextRevision: contextRevision)
            }
            return TeamsFileLink(title: label, url: url, preview: preview, sharePoint: attachment)
        }
    }
}

public enum TeamsBodyParser {
    public static func safeLink(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme),
              url.user == nil, url.password == nil else { return nil }
        if scheme != "mailto" && url.host == nil { return nil }
        return url
    }

    public static func parse(_ html: String, messageType: String? = nil) -> TeamsMessageBody {
        let truncated = html.utf8.count > 1_000_000
        let input = truncated ? String(html.prefix(200_000)) : html
        if messageType == "Text" {
            return .init(text: input, blocks: [.init(runs: [.init(text: input)])], hasUnsupportedContent: truncated)
        }
        guard !html.isEmpty else {
            let fallback = messageType?.hasPrefix("ThreadActivity/") == true ? "Conversation activity" : "Message content is unavailable."
            return .init(text: fallback, blocks: [.init(runs: [.init(text: fallback)])], hasUnsupportedContent: true)
        }
        guard let document = try? SwiftSoup.parseBodyFragment(input), let body = document.body() else {
            return .init(text: "Message content is unavailable.", blocks: [], hasUnsupportedContent: true)
        }
        var parser = BodyTraversal()
        parser.unsupported = truncated
        for node in body.getChildNodes() { parser.visit(node, style: .init(text: "")) }
        parser.flush()
        let blocks = parser.blocks
        let text = blocks.map(\.text).joined(separator: "\n")
        return .init(text: text.isEmpty ? "Message content is unavailable." : text,
                     blocks: blocks, hasUnsupportedContent: parser.unsupported || text.isEmpty)
    }
}

private struct BodyTraversal {
    var blocks: [TeamsTextBlock] = []
    var runs: [TeamsTextRun] = []
    var kind: TeamsTextBlock.Kind = .paragraph
    var quoteGroup: Int?
    var reply: TeamsReplyPreview?
    var nextQuoteGroup = 0
    var unsupported = false
    var imageCount = 0
    var lists: [(ordered: Bool, next: Int)] = []
    var pendingListMarker = false

    mutating func flush() {
        pendingListMarker = false
        guard !runs.isEmpty else { return }
        if kind != .code {
            runs[0].text = runs[0].text.trimmingCharacters(in: .newlines)
            runs[runs.count - 1].text = runs[runs.count - 1].text.trimmingCharacters(in: .newlines)
        }
        if !runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.init(kind: kind, runs: runs, quoteGroup: quoteGroup, reply: reply))
        }
        runs = []
    }

    mutating func append(_ text: String, style: TeamsTextRun) {
        guard !text.isEmpty else { return }
        if pendingListMarker && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        pendingListMarker = false
        var run = style
        run.text = text
        runs.append(run)
    }

    mutating func visit(_ node: Node, style: TeamsTextRun, depth: Int = 0) {
        guard depth < 100 else { unsupported = true; return }
        if let text = node as? TextNode {
            let value = kind == .code ? text.getWholeText()
                : text.getWholeText().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            append(value, style: style)
            return
        }
        guard let element = node as? Element else { return }
        let tag = element.tagName().lowercased()
        if ["script", "style", "iframe", "object", "embed", "svg", "noscript", "head"].contains(tag) { return }
        if tag == "swift" {
            unsupported = true
            if let encoded = try? element.attr("b64"), let data = Data(base64Encoded: encoded), data.count < 1_000_000,
               let json = try? JSONSerialization.jsonObject(with: data) {
                flush()
                for text in cardText(json).prefix(60) {
                    let parsed = TeamsBodyParser.parse(text)
                    blocks.append(contentsOf: parsed.blocks)
                }
            }
            return
        }
        if ["img", "attachment", "video", "audio"].contains(tag) {
            let alt = (try? element.attr("alt")) ?? ""
            if tag == "img", (try? element.attr("itemtype")) == "http://schema.skype.com/Emoji", !alt.isEmpty {
                append(alt, style: style)
                return
            }
            if tag == "img", imageCount < 20, let source = try? element.attr("src"), source.utf8.count <= 8192,
               let components = URLComponents(string: source), components.scheme?.lowercased() == "https",
               components.host != nil, components.user == nil, components.password == nil, components.fragment == nil,
               let url = components.url {
                func dimension(_ name: String) -> Int? {
                    guard let value = try? element.attr(name), let number = Int(value), (1...16384).contains(number) else { return nil }
                    return number
                }
                flush()
                let label = String((alt.isEmpty ? "Image" : alt).prefix(200))
                let image = TeamsInlineImage(url: url, alternativeText: label, width: dimension("width"), height: dimension("height"))
                blocks.append(.init(kind: .image, runs: [.init(text: "[\(label)]")], quoteGroup: quoteGroup, image: image, reply: reply))
                imageCount += 1
                return
            }
            unsupported = true
            append(alt.isEmpty ? "[\(tag == "attachment" ? "Attachment" : "Media")]" : "[\(alt)]", style: style)
            return
        }
        if tag == "br" { append("\n", style: style); return }
        let block = ["p", "div", "li", "blockquote", "pre", "h1", "h2", "h3", "h4", "tr", "title", "description"].contains(tag)
        let previousKind = kind
        let previousQuoteGroup = quoteGroup
        let previousReply = reply
        let paragraphStartsListItem = tag == "p" && element.parent()?.tagName().lowercased() == "li" && pendingListMarker
        if block && !paragraphStartsListItem { flush() }
        if tag == "blockquote" {
            kind = .quote
            nextQuoteGroup += 1
            quoteGroup = nextQuoteGroup
            reply = nil
            if (try? element.attr("itemtype")) == "http://schema.skype.com/Reply" {
                let id = (try? element.attr("itemid")) ?? ""
                let author = (try? element.select("[itemprop=mri]").first()?.text()) ?? ""
                let sender = (try? element.select("[itemprop=mri]").first()?.attr("itemid")) ?? ""
                let preview = (try? element.select("[itemprop=preview]").first()).flatMap { $0 }.map { excerptText($0) } ?? ""
                let time = (try? element.select("[itemprop=time]").first()?.attr("itemid")) ?? ""
                let milliseconds = Double(time)
                let date = milliseconds.flatMap { value -> Date? in
                    guard value.isFinite, value > 0, value < 100_000_000_000_000 else { return nil }
                    return Date(timeIntervalSince1970: value / 1000)
                }
                if !author.isEmpty || !preview.isEmpty {
                    reply = TeamsReplyPreview(messageID: id.isEmpty || id.utf8.count > 512 ? nil : id,
                                              senderID: sender.isEmpty || sender.utf8.count > 512 ? nil : sender,
                                              author: String((author.isEmpty ? "Unknown author" : author).prefix(200)),
                                              date: date, excerpt: String(preview.prefix(20_000)))
                }
            }
        }
        if tag == "pre" { kind = .code }
        var next = style
        if ["strong", "b", "h1", "h2", "h3", "h4", "title"].contains(tag) { next.bold = true }
        if ["em", "i"].contains(tag) { next.italic = true }
        if tag == "u" { next.underline = true }
        if ["s", "strike", "del"].contains(tag) { next.strike = true }
        if tag == "code" || tag == "pre" { next.code = true }
        if tag == "at" || (tag == "span" && (try? element.attr("itemtype")) == "http://schema.skype.com/Mention") { next.isMention = true }
        if tag == "a", let href = try? element.attr("href") { next.link = TeamsBodyParser.safeLink(href) }
        if tag == "ul" || tag == "ol" {
            let start = Int((try? element.attr("start")) ?? "") ?? 1
            lists.append((tag == "ol", min(max(start, 1), 100_000)))
        }
        if tag == "li" {
            let indent = String(repeating: "  ", count: max(0, lists.count - 1))
            if let last = lists.indices.last, lists[last].ordered {
                append("\(indent)\(lists[last].next). ", style: next)
                lists[last].next = min(lists[last].next + 1, 100_000)
            } else { append(indent + "• ", style: next) }
            pendingListMarker = true
        }
        if tag == "td" || tag == "th" { append("  ", style: next) }
        if tag == "uriobject", (try? element.select("img").isEmpty()) ?? true { unsupported = true }
        for child in element.getChildNodes() { visit(child, style: next, depth: depth + 1) }
        if tag == "ul" || tag == "ol" { _ = lists.popLast() }
        if block { flush(); kind = previousKind; quoteGroup = previousQuoteGroup; reply = previousReply }
    }

    private func excerptText(_ node: Node, depth: Int = 0) -> String {
        guard depth < 32 else { return "" }
        if let text = node as? TextNode { return text.getWholeText() }
        guard let element = node as? Element else { return "" }
        let tag = element.tagName().lowercased()
        if ["script", "style", "iframe", "object", "embed"].contains(tag) { return "" }
        if tag == "img" {
            let alt = (try? element.attr("alt")) ?? ""
            return alt.isEmpty ? "[Image]" : alt
        }
        if tag == "br" { return " " }
        return element.getChildNodes().map { excerptText($0, depth: depth + 1) }.joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func cardText(_ value: Any, depth: Int = 0) -> [String] {
        guard depth < 20 else { return [] }
        if let array = value as? [Any] { return array.flatMap { cardText($0, depth: depth + 1) } }
        guard let dictionary = value as? [String: Any] else { return [] }
        var result: [String] = []
        for key in ["title", "text", "subtitle"] {
            if let text = dictionary[key] as? String, !text.isEmpty { result.append(String(text.prefix(20_000))) }
        }
        for key in ["attachments", "content", "body", "items", "columns", "facts"] {
            if let child = dictionary[key] { result += cardText(child, depth: depth + 1) }
        }
        return result
    }
}
