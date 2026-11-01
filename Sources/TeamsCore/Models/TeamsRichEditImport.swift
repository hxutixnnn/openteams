import Foundation
import SwiftSoup

public struct TeamsRichEditImport: Sendable {
    public struct Reply: Equatable, Sendable {
        public let messageID: String
        public let sender: String
        public let name: String
        public let preview: String
        public let timestamp: Int64
    }
    public let document: TeamsRichDraft
    public let reply: Reply?

    public enum ImportError: Error { case unsupported }

    public init(message: TeamsWebMessage) throws {
        guard let content = message.content, content.utf8.count <= 28_000 else { throw ImportError.unsupported }
        if message.messageType == "Text" {
            document = TeamsRichDraft(plainText: content); reply = nil; return
        }
        guard message.messageType == "RichText/Html" else { throw ImportError.unsupported }
        let mentions: [String: TeamsRichDraft.Mention]
        if case let .object(properties)? = message.properties, let value = properties["mentions"] {
            guard case let .string(json) = value, let data = json.data(using: .utf8), data.count <= 28_000,
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ImportError.unsupported }
            var map: [String: TeamsRichDraft.Mention] = [:]
            for entry in array {
                guard let id = (entry["itemid"] ?? entry["itemId"]) as? String, !id.isEmpty, map[id] == nil,
                      let mri = (entry["mri"] ?? entry["userId"]) as? String, mri.lowercased().hasPrefix("8:orgid:"),
                      (entry["mentionType"] as? String ?? "person").lowercased() == "person" else { throw ImportError.unsupported }
                let rawName = entry["displayName"] as? String ?? ""
                guard let name = try? Parser.unescapeEntities(rawName, false) else { throw ImportError.unsupported }
                map[id] = .init(mri: mri, displayName: name)
            }
            mentions = map
        } else { mentions = [:] }
        guard !content.contains("<!"), let body = try? SwiftSoup.parseBodyFragment(content).body(),
              let root = try? RichEditHTMLParser.convert(body) else { throw ImportError.unsupported }
        var used: Set<String> = []
        struct Style { var bold = false; var italic = false; var underline = false; var strike = false; var code = false; var link: URL?; var mention: TeamsRichDraft.Mention? }
        func inline(_ node: RichEditHTMLParser.Node, _ style: Style) throws -> [TeamsRichDraft.Run] {
            if node.tag == "#text" { return [.init(text: node.text, bold: style.bold, italic: style.italic, underline: style.underline, strike: style.strike, code: style.code, link: style.link, mention: style.mention)] }
            var next = style
            switch node.tag {
            case "strong", "b": next.bold = true
            case "em", "i": next.italic = true
            case "u": next.underline = true
            case "s", "strike", "del": next.strike = true
            case "code": next.code = true
            case "br": guard node.attributes.isEmpty, node.children.isEmpty else { throw ImportError.unsupported }; return [.init(text: "\n", bold: style.bold, italic: style.italic, underline: style.underline, strike: style.strike, code: style.code, link: style.link, mention: style.mention)]
            case "a":
                guard Set(node.attributes.keys) == ["href"], let raw = node.attributes["href"], let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme), url.user == nil, url.password == nil else { throw ImportError.unsupported }; next.link = url
            case "span":
                guard node.attributes["itemtype"] == "http://schema.skype.com/Mention", let id = node.attributes["itemid"], let mention = mentions[id], used.insert(id).inserted, node.attributes.keys.allSatisfy({ ["itemscope", "itemtype", "itemid"].contains($0) }) else { throw ImportError.unsupported }
                next.mention = mention
            default: throw ImportError.unsupported
            }
            if !["span", "a"].contains(node.tag), !node.attributes.isEmpty { throw ImportError.unsupported }
            let runs = try node.children.flatMap { try inline($0, next) }
            if node.tag == "span", let mention = next.mention {
                let label = runs.map(\.text).joined()
                if mention.displayName.isEmpty {
                    guard !label.isEmpty else { throw ImportError.unsupported }
                    let restored = TeamsRichDraft.Mention(mri: mention.mri, displayName: label, occurrenceID: mention.occurrenceID)
                    return runs.map { run in var value = run; value.mention = restored; return value }
                }
                if label != mention.displayName {
                    var first = runs.first ?? .init(text: "", bold: next.bold, italic: next.italic, underline: next.underline, strike: next.strike, code: next.code, link: next.link, mention: mention)
                    first.text = mention.displayName; return [first]
                }
            }
            return runs
        }
        func block(_ node: RichEditHTMLParser.Node, depth: Int) throws -> TeamsRichDraft.Block {
            guard depth <= 12, node.attributes.isEmpty else { throw ImportError.unsupported }
            let kind: TeamsRichDraft.Block.Kind
            switch node.tag { case "p": kind = .paragraph; case "blockquote": kind = .quote; case "pre": kind = .codeBlock; case "ul": kind = .bulletList; case "ol": kind = .numberedList; case "li": kind = .listItem; default: throw ImportError.unsupported }
            if kind == .bulletList || kind == .numberedList {
                let items = node.children.filter { !($0.tag == "#text" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                guard items.allSatisfy({ $0.tag == "li" }) else { throw ImportError.unsupported }
                return .init(kind: kind, children: try items.map { try block($0, depth: depth + 1) })
            }
            var runs: [TeamsRichDraft.Run] = [], children: [TeamsRichDraft.Block] = [], nested = false
            let significant = node.children.filter { !($0.tag == "#text" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            let contentNodes: [RichEditHTMLParser.Node]
            if (kind == .listItem || kind == .quote), significant.first?.tag == "p", significant.filter({ $0.tag == "p" }).count == 1 {
                contentNodes = significant.flatMap { $0.tag == "p" && $0.attributes.isEmpty ? $0.children : [$0] }
            } else if kind == .codeBlock, significant.count == 1, significant[0].tag == "code", significant[0].attributes.isEmpty {
                contentNodes = significant[0].children
            } else { contentNodes = node.children }
            for child in contentNodes {
                if ["ul", "ol"].contains(child.tag), kind == .listItem { nested = true; children.append(try block(child, depth: depth + 1)) }
                else { guard !nested else { throw ImportError.unsupported }; runs += try inline(child, Style()) }
            }
            if kind == .codeBlock {
                let text = runs.map(\.text).joined()
                guard !text.isEmpty else { throw ImportError.unsupported }
            }
            return .init(kind: kind, runs: runs, children: children)
        }
        var blocks: [TeamsRichDraft.Block] = [], selectedReply: Reply?
        for node in root.children {
            if node.tag == "#text", node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if node.tag == "blockquote", node.attributes["itemtype"] == "http://schema.skype.com/Reply" {
                let elements = node.children.filter { !($0.tag == "#text" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                guard selectedReply == nil, blocks.isEmpty, node.attributes.keys.allSatisfy({ ["itemscope", "itemtype", "itemid"].contains($0) }),
                      let id = node.attributes["itemid"], id.range(of: "^[0-9]{1,32}$", options: .regularExpression) != nil,
                      let sender = elements.first(where: { $0.attributes["itemprop"] == "mri" }), let mri = sender.attributes["itemid"], !mri.isEmpty,
                      let time = elements.first(where: { $0.attributes["itemprop"] == "time" })?.attributes["itemid"].flatMap(Int64.init), time > 0,
                      let preview = elements.first(where: { $0.attributes["itemprop"] == "preview" }),
                      sender.tag == "strong", Set(sender.attributes.keys) == ["itemprop", "itemid"],
                      preview.tag == "p", Set(preview.attributes.keys) == ["itemprop"],
                      elements.first(where: { $0.attributes["itemprop"] == "time" }).map({ $0.tag == "span" && Set($0.attributes.keys) == ["itemprop", "itemid"] && $0.children.isEmpty }) == true,
                      sender.children.allSatisfy({ $0.tag == "#text" }), preview.children.allSatisfy({ $0.tag == "#text" }),
                      elements.count == 3 else { throw ImportError.unsupported }
                let name = sender.children.map(\.text).joined(), text = preview.children.map(\.text).joined()
                guard !name.isEmpty, !text.isEmpty else { throw ImportError.unsupported }
                selectedReply = .init(messageID: id, sender: mri, name: name, preview: text, timestamp: time)
            } else { blocks.append(try block(node, depth: 0)) }
        }
        guard !blocks.isEmpty, used.count == mentions.count else { throw ImportError.unsupported }
        document = .init(blocks: blocks); reply = selectedReply
    }
}

private enum RichEditHTMLParser {
    final class Node {
        let tag: String; let attributes: [String: String]; var children: [Node] = []; var text = ""
        init(_ tag: String, _ attributes: [String: String] = [:]) { self.tag = tag; self.attributes = attributes }
    }
    static func convert(_ element: Element) throws -> Node {
        var count = 0
        func visit(_ source: SwiftSoup.Node, depth: Int) throws -> Node {
            count += 1
            guard count <= 5000, depth <= 32 else { throw TeamsRichEditImport.ImportError.unsupported }
            if let text = source as? TextNode { let result = Node("#text"); result.text = text.getWholeText(); return result }
            guard let element = source as? Element else { throw TeamsRichEditImport.ImportError.unsupported }
            let attributes = Dictionary((element.getAttributes()?.asList() ?? []).map { ($0.getKey().lowercased(), $0.getValue()) }, uniquingKeysWith: { first, _ in first })
            let result = Node(element.tagName().lowercased(), attributes)
            result.children = try element.getChildNodes().map { try visit($0, depth: depth + 1) }
            return result
        }
        return try visit(element, depth: 0)
    }
}
