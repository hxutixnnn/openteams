import Foundation
import Testing
@testable import TeamsCore

struct TeamsRichDraftTests {
    @Test func orphanedNestedItemBecomesTopLevelAfterParentDeletion() throws {
        let lines: [TeamsRichDraft.EditorLine] = [
            .init(kind: .numberedList, depth: 1, prefix: "  1. ", runs: [.init(text: "Second")]),
            .init(kind: .numberedList, depth: 0, prefix: "2. ", runs: [.init(text: "Third")])
        ]
        let draft = TeamsRichDraft(editorLines: lines)
        #expect(draft.plainText == "1. Second\n2. Third")
        #expect(try draft.serialize().html == "<ol><li>Second</li><li>Third</li></ol>")
    }
    @Test func serializesFormattingAndSemanticMentionsSafely() throws {
        let person = TeamsRichDraft.Mention(mri: "8:orgid:example", displayName: "Ánh & Co")
        let draft = TeamsRichDraft(blocks: [.init(runs: [.init(text: "Hello <world> ", bold: true), .init(text: "Ánh & Co", mention: person), .init(text: " and "), .init(text: "Ánh & Co", mention: person), .init(text: " bad", link: URL(string: "javascript:alert(1)"))]), .init(kind: .numberedList, children: [.init(kind: .listItem, runs: [.init(text: "First")], children: [.init(kind: .bulletList, children: [.init(kind: .listItem, runs: [.init(text: "Nested", italic: true)])])])])])
        let result = try draft.serialize()
        #expect(result.html.contains("<strong>Hello &lt;world&gt; </strong>"))
        #expect(result.html.contains("itemid=\"0\">Ánh &amp; Co</span>"))
        #expect(result.html.contains("itemid=\"1\">Ánh &amp; Co</span>"))
        #expect(result.html.contains("<ol><li>First<ul><li><em>Nested</em></li></ul></li></ol>"))
        #expect(!result.html.contains("javascript:"))
        let mentions = try #require(JSONSerialization.jsonObject(with: Data(result.mentionsJSON.utf8)) as? [[String: String]])
        #expect(mentions.map { $0["itemid"] } == ["0", "1"])
        #expect(mentions.allSatisfy { $0["mri"] == "8:orgid:example" })
        let restored = try JSONDecoder().decode(TeamsRichDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored == draft)
        #expect(TeamsRichDraft(editorLines: draft.editorLines) == draft)
        let rendered = TeamsBodyParser.parse(result.html)
        #expect(rendered.blocks.flatMap(\.runs).contains { $0.isMention && $0.text == "Ánh & Co" })
        #expect(rendered.text.contains("1. First"))
        #expect(rendered.text.contains("• Nested"))
    }
    @Test func staleMentionFallsBackToTextAndOversizedHTMLFails() throws {
        let stale = TeamsRichDraft.Mention(mri: "8:orgid:example", displayName: "Person")
        let serialized = try TeamsRichDraft(blocks: [.init(runs: [.init(text: "Edited", mention: stale)])]).serialize()
        #expect(serialized.mentionsJSON == "[]")
        #expect(!serialized.html.contains("Mention"))
        #expect(throws: TeamsWebClientError.messageTooLarge) { try TeamsRichDraft(plainText: String(repeating: "<", count: 8_000)).serialize() }
    }
    @Test func splitMentionFragmentsRejoinWithoutCollapsingRepeatedMentions() throws {
        let mention = TeamsRichDraft.Mention(mri: "8:orgid:example", displayName: "Person")
        let draft = TeamsRichDraft(blocks: [.init(runs: [.init(text: "Per", bold: true, mention: mention), .init(text: "son", mention: mention), .init(text: "Person", mention: mention)])])
        let serialized = try draft.serialize()
        let mentions = try #require(JSONSerialization.jsonObject(with: Data(serialized.mentionsJSON.utf8)) as? [[String: String]])
        #expect(mentions.count == 2)
        #expect(serialized.html.contains("itemid=\"0\"><strong>Per</strong>son</span>"))
        #expect(serialized.html.contains("itemid=\"1\">Person</span>"))
    }
    @Test func readerRetainsUnderlineAndStrike() {
        let body = TeamsBodyParser.parse("<p><u>under</u> <s>struck</s></p>")
        #expect(body.blocks.flatMap(\.runs).contains { $0.text == "under" && $0.underline })
        #expect(body.blocks.flatMap(\.runs).contains { $0.text == "struck" && $0.strike })
    }
    @Test func readerKeepsMarkersWithParagraphWrappedListItems() {
        let body = TeamsBodyParser.parse("<ol><li><p>First</p><ul><li><p>Nested</p></li></ul></li><li><p>Second</p></li></ol>")
        #expect(body.blocks.map(\.text) == ["1. First", "  • Nested", "2. Second"])
        let spaced = TeamsBodyParser.parse("<ol><li>\n  <p>First</p></li><li>\n  <p>Second</p></li></ol>")
        #expect(spaced.blocks.map(\.text) == ["1. First", "2. Second"])
    }
}
