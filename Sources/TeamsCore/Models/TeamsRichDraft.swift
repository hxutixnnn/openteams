import Foundation
import CryptoKit

public struct TeamsRichDraft: Codable, Equatable, Sendable {
    public struct Mention: Codable, Equatable, Sendable {
        public let mri: String
        public let displayName: String
        public let occurrenceID: UUID
        public init(mri: String, displayName: String, occurrenceID: UUID = UUID()) { self.mri = mri; self.displayName = displayName; self.occurrenceID = occurrenceID }
        private enum CodingKeys: String, CodingKey { case mri, displayName, occurrenceID }
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mri = try container.decode(String.self, forKey: .mri)
            displayName = try container.decode(String.self, forKey: .displayName)
            occurrenceID = try container.decodeIfPresent(UUID.self, forKey: .occurrenceID) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        }
    }
    public struct Run: Codable, Equatable, Sendable {
        public var text: String
        public var bold = false
        public var italic = false
        public var underline = false
        public var strike = false
        public var code = false
        public var link: URL?
        public var mention: Mention?
        public init(text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, strike: Bool = false, code: Bool = false, link: URL? = nil, mention: Mention? = nil) {
            self.text = text; self.bold = bold; self.italic = italic; self.underline = underline; self.strike = strike; self.code = code; self.link = link; self.mention = mention
        }
    }
    public struct Block: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case paragraph, quote, codeBlock, bulletList, numberedList, listItem }
        public var kind: Kind
        public var runs: [Run]
        public var children: [Block]
        public init(kind: Kind = .paragraph, runs: [Run] = [], children: [Block] = []) { self.kind = kind; self.runs = runs; self.children = children }
    }
    public struct Serialized: Sendable {
        public let html: String
        public let mentionsJSON: String
    }
    public struct EditorLine: Equatable, Sendable {
        public let kind: Block.Kind
        public let depth: Int
        public let prefix: String
        public let runs: [Run]
        public init(kind: Block.Kind, depth: Int, prefix: String, runs: [Run]) { self.kind = kind; self.depth = depth; self.prefix = prefix; self.runs = runs }
    }
    public var blocks: [Block]
    public init(blocks: [Block]) { self.blocks = blocks }
    private enum CodingKeys: String, CodingKey { case blocks }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blocks = try container.decode([Block].self, forKey: .blocks)
        let legacy = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var ordinal = 0
        func migrate(_ block: inout Block) {
            var index = 0
            while index < block.runs.count {
                guard let mention = block.runs[index].mention, mention.occurrenceID == legacy else { index += 1; continue }
                var end = index, label = ""
                while end < block.runs.count, let next = block.runs[end].mention, next.occurrenceID == legacy,
                      next.mri == mention.mri, next.displayName == mention.displayName, label.count < mention.displayName.count {
                    label += block.runs[end].text; end += 1
                }
                if end == index { end += 1 }
                let input = "\(ordinal)\n\(mention.mri)\n\(mention.displayName)"
                let hex = SHA256.hash(data: Data(input.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
                let uuid = UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))") ?? UUID()
                for run in index..<end { block.runs[run].mention = .init(mri: mention.mri, displayName: mention.displayName, occurrenceID: uuid) }
                ordinal += 1; index = end
            }
            for child in block.children.indices { migrate(&block.children[child]) }
        }
        for index in blocks.indices { migrate(&blocks[index]) }
    }
    public init(plainText: String) { blocks = plainText.components(separatedBy: "\n").map { .init(runs: [.init(text: $0)]) } }
    public var isPlain: Bool {
        blocks.allSatisfy { $0.kind == .paragraph && $0.children.isEmpty && $0.runs.allSatisfy { !$0.bold && !$0.italic && !$0.underline && !$0.strike && !$0.code && $0.link == nil && $0.mention == nil } }
    }
    public var editorLines: [EditorLine] {
        var lines: [EditorLine] = []
        func append(_ block: Block, depth: Int) {
            switch block.kind {
            case .bulletList, .numberedList:
                for (index, item) in block.children.enumerated() {
                    let prefix = String(repeating: "  ", count: min(depth, 12)) + (block.kind == .bulletList ? "• " : "\(index + 1). ")
                    lines.append(.init(kind: block.kind, depth: depth, prefix: prefix, runs: item.runs))
                    for child in item.children { append(child, depth: depth + 1) }
                }
            case .quote:
                lines.append(.init(kind: .quote, depth: depth, prefix: "│ ", runs: block.runs))
                for child in block.children { append(child, depth: depth) }
            default:
                lines.append(.init(kind: block.kind, depth: depth, prefix: "", runs: block.runs))
                for child in block.children { append(child, depth: depth) }
            }
        }
        for block in blocks { append(block, depth: 0) }
        return lines
    }
    public var plainText: String { editorLines.map { $0.prefix + $0.runs.map(\.text).joined() }.joined(separator: "\n") }
    var legacyPlainText: String {
        func text(_ block: Block) -> String { ([block.runs.map(\.text).joined()] + block.children.map(text)).filter { !$0.isEmpty }.joined(separator: "\n") }
        return blocks.map(text).joined(separator: "\n")
    }
    public var contentText: String { editorLines.map { $0.runs.map(\.text).joined() }.joined(separator: "\n") }
    public init(editorLines: [EditorLine]) {
        var previousListDepth: Int?
        let editorLines = editorLines.map { line -> EditorLine in
            guard [.bulletList, .numberedList].contains(line.kind) else { previousListDepth = nil; return line }
            let depth = min(max(0, line.depth), previousListDepth.map { $0 + 1 } ?? 0)
            previousListDepth = depth
            return .init(kind: line.kind, depth: depth, prefix: line.prefix, runs: line.runs)
        }
        var index = 0
        func list(_ depth: Int, _ kind: Block.Kind) -> Block {
            var items: [Block] = []
            while index < editorLines.count, editorLines[index].depth == depth, editorLines[index].kind == kind {
                let line = editorLines[index]; index += 1
                var children: [Block] = []
                while index < editorLines.count, editorLines[index].depth > depth,
                      [.bulletList, .numberedList].contains(editorLines[index].kind) {
                    let next = editorLines[index]
                    children.append(list(next.depth, next.kind))
                }
                items.append(.init(kind: .listItem, runs: line.runs, children: children))
            }
            return .init(kind: kind, children: items)
        }
        var result: [Block] = []
        while index < editorLines.count {
            let line = editorLines[index]
            if [.bulletList, .numberedList].contains(line.kind) { result.append(list(line.depth, line.kind)) }
            else { result.append(.init(kind: [.quote, .codeBlock].contains(line.kind) ? line.kind : .paragraph, runs: line.runs)); index += 1 }
        }
        blocks = result
    }
    public func serialize() throws -> Serialized {
        guard blocks.count <= 1000 else { throw TeamsWebClientError.messageTooLarge }
        var mentions: [[String: String]] = []
        var nodes = 0
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        }
        func render(_ block: Block, depth: Int) throws -> String {
            nodes += 1
            guard depth <= 12, nodes <= 5000, block.runs.count <= 5000 else { throw TeamsWebClientError.messageTooLarge }
            let tag: String
            switch block.kind { case .paragraph: tag = "p"; case .quote: tag = "blockquote"; case .codeBlock: tag = "pre"; case .bulletList: tag = "ul"; case .numberedList: tag = "ol"; case .listItem: tag = "li" }
            func styled(_ run: Run) -> String {
                var value = escape(run.text).replacingOccurrences(of: "\n", with: "<br>")
                if run.code { value = "<code>\(value)</code>" }
                if run.bold { value = "<strong>\(value)</strong>" }
                if run.italic { value = "<em>\(value)</em>" }
                if run.underline { value = "<u>\(value)</u>" }
                if run.strike { value = "<s>\(value)</s>" }
                if let url = run.link, let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme), url.user == nil, url.password == nil,
                   url.absoluteString.rangeOfCharacter(from: .controlCharacters) == nil,
                   (scheme == "mailto" ? !url.path.isEmpty : (url.host?.isEmpty == false)) {
                    value = "<a href=\"\(escape(url.absoluteString))\">\(value)</a>"
                }
                return value
            }
            var body = "", index = 0
            while index < block.runs.count {
                let run = block.runs[index]
                if let mention = run.mention, !mention.mri.isEmpty, mention.mri.utf8.count <= 512,
                   mention.mri.rangeOfCharacter(from: .controlCharacters) == nil, !mention.displayName.isEmpty {
                    var end = index, text = "", content = ""
                    while end < block.runs.count, block.runs[end].mention == mention, text.count < mention.displayName.count {
                        text += block.runs[end].text; content += styled(block.runs[end]); end += 1
                    }
                    if text == mention.displayName {
                        let id = String(mentions.count)
                        mentions.append(["@type": "http://schema.skype.com/Mention", "itemid": id, "mri": mention.mri, "mentionType": "person", "displayName": mention.displayName])
                        body += "<span itemtype=\"http://schema.skype.com/Mention\" itemscope=\"\" itemid=\"\(id)\">\(content)</span>"
                        index = end; continue
                    }
                }
                body += styled(run); index += 1
            }
            for child in block.children { body += try render(child, depth: depth + 1) }
            if block.kind == .codeBlock { body = "<code>\(body)</code>" }
            return "<\(tag)>\(body)</\(tag)>"
        }
        let html = try blocks.map { try render($0, depth: 0) }.joined()
        guard html.utf8.count <= 28_000 else { throw TeamsWebClientError.messageTooLarge }
        let data = try JSONSerialization.data(withJSONObject: mentions, options: [.sortedKeys])
        guard data.count <= 28_000 else { throw TeamsWebClientError.messageTooLarge }
        return Serialized(html: html, mentionsJSON: String(decoding: data, as: UTF8.self))
    }
}
