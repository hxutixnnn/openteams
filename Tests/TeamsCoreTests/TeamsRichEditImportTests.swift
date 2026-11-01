import Foundation
import Testing
@testable import TeamsCore

struct TeamsRichEditImportTests {
    @Test func importsSemanticMentionsReplyFormattingAndNestedLists() throws {
        let mentions = #"[{"itemid":"0","mri":"8:orgid:person","mentionType":"person","displayName":"Ada"},{"itemid":"1","mri":"8:orgid:person","mentionType":"person","displayName":"Ada"}]"#
        let html = #"<blockquote itemscope="" itemtype="http://schema.skype.com/Reply" itemid="123"><strong itemprop="mri" itemid="8:orgid:sender">Sam</strong><span itemprop="time" itemid="123"></span><p itemprop="preview">Earlier</p></blockquote><p><strong>Hello</strong> <span itemtype="http://schema.skype.com/Mention" itemscope="" itemid="0">Ada</span><span itemtype="http://schema.skype.com/Mention" itemscope="" itemid="1">Ada</span></p><ul><li>One<ol><li>Two</li></ol></li></ul>"#
        let message = TeamsWebMessage(id: "456", content: html, messageType: "RichText/Html", properties: .object(["mentions": .string(mentions)]))
        let imported = try TeamsRichEditImport(message: message)
        #expect(imported.reply?.messageID == "123" && imported.reply?.sender == "8:orgid:sender")
        #expect(imported.document.blocks[0].runs[0].bold)
        let found = imported.document.blocks[0].runs.compactMap(\.mention)
        #expect(found.count == 2 && found[0].mri == found[1].mri && found[0].occurrenceID != found[1].occurrenceID)
        #expect(imported.document.blocks[1].children[0].children[0].kind == .numberedList)
        let serialized = try imported.document.serialize()
        #expect(serialized.html.contains("itemid=\"0\"") && serialized.html.contains("itemid=\"1\""))
    }
    @Test func refusesUnrepresentableAndUnresolvedContent() throws {
        for html in [#"<p><span itemtype="http://schema.skype.com/Mention" itemid="0">Ada</span></p>"#, "<ol start=\"4\"><li>Four</li></ol>", "<p><img src=\"https://example.com/a\"/></p>", "<table><tr><td>Cell</td></tr></table>"] {
            #expect(throws: TeamsRichEditImport.ImportError.self) { try TeamsRichEditImport(message: .init(id: "1", content: html, messageType: "RichText/Html")) }
        }
    }
    @Test func htmlWhitespaceWrappersAndMetadataLabelAreRestored() throws {
        let mentions = #"[{"itemid":"0","userId":"8:orgid:person","mentionType":"person","displayName":"Ada &amp; Co"}]"#
        let html = "<p>First &amp; more<br />next</p>\n <p><span itemscope itemtype=\"http://schema.skype.com/Mention\" itemid=\"0\">Old Name</span></p>\n<ul>\n<li><p>One</p></li></ul><blockquote><p>Quoted</p></blockquote>"
        let imported = try TeamsRichEditImport(message: .init(id: "1", content: html, messageType: "RichText/Html", properties: .object(["mentions": .string(mentions)])))
        #expect(imported.document.blocks.count == 4)
        #expect(imported.document.blocks[0].runs.map(\.text).joined() == "First & more\nnext")
        #expect(imported.document.blocks[1].runs.first?.text == "Ada & Co")
        #expect(imported.document.blocks[1].runs.first?.mention?.mri == "8:orgid:person")
        #expect(imported.document.blocks[2].children.first?.runs.first?.text == "One")
        #expect(imported.document.blocks[3].runs.first?.text == "Quoted")
    }
    @Test func semanticReplyWhitespaceAndStaleOrEmptyMentionLabels() throws {
        let mentions = #"[{"itemid":"0","userId":"8:orgid:person","displayName":"Ada &amp; Co"},{"itemid":"1","userId":"8:orgid:other","displayName":"Lin"}]"#
        let html = #"<blockquote itemscope itemtype="http://schema.skype.com/Reply" itemid="123"> "# + "\n" + #"<strong itemprop="mri" itemid="8:orgid:sender">Sam</strong> <span itemprop="time" itemid="123"></span> <p itemprop="preview">Earlier</p> </blockquote><p><span itemscope itemtype="http://schema.skype.com/Mention" itemid="0"><strong>Old</strong> Name</span><span itemscope itemtype="http://schema.skype.com/Mention" itemid="1"></span></p>"#
        let imported = try TeamsRichEditImport(message: .init(id: "1", content: html, messageType: "RichText/Html", properties: .object(["mentions": .string(mentions)])))
        #expect(imported.reply?.preview == "Earlier")
        #expect(imported.document.blocks[0].runs.map(\.text) == ["Ada & Co", "Lin"])
        #expect(imported.document.blocks[0].runs[0].bold)
        #expect(imported.document.blocks[0].runs[0].mention?.mri == "8:orgid:person")
    }
    @Test func codeBlockImportSerializationIsStable() throws {
        let first = try TeamsRichEditImport(message: .init(id: "1", content: "<pre><code>let x = 1</code></pre>", messageType: "RichText/Html"))
        let html = try first.document.serialize().html
        #expect(html == "<pre><code>let x = 1</code></pre>")
        let second = try TeamsRichEditImport(message: .init(id: "1", content: html, messageType: "RichText/Html"))
        #expect(try second.document.serialize().html == html)
    }
}

struct TeamsEditJournalTests {
    @Test func knownUndispatchedIntentReturnsToPrepared() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        let intent = TeamsPendingEdit(original: .init(id: "1", content: "before", messageType: "Text"), document: .init(plainText: "after"))
        #expect(try await cache.installPendingEdit(intent, in: "chat"))
        #expect(try await cache.updatePendingEdit(id: intent.id, in: "chat", messageID: "1", expected: .prepared, stage: .dispatched))
        #expect(try await cache.restoreUndispatchedEdit(id: intent.id, in: "chat", messageID: "1"))
        #expect(try await cache.pendingEdit(in: "chat", messageID: "1")?.stage == .prepared)
    }
    @Test func pendingEditIsAccountScopedAndCannotReplayUnknown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        let other = TeamsReadCache(root: root, accountID: "other", tenantID: "tenant")
        let original = TeamsWebMessage(id: "1", content: "before", messageType: "Text")
        let intent = TeamsPendingEdit(original: original, document: .init(plainText: "after"))
        let lease = try #require(await cache.acquireEditLease(in: "chat", messageID: "1"))
        #expect(try await cache.acquireEditLease(in: "chat", messageID: "1") == nil)
        #expect(try await cache.installPendingEdit(intent, in: "chat"))
        #expect(try await !cache.installPendingEdit(intent, in: "chat"))
        #expect(try await other.pendingEdit(in: "chat", messageID: "1") == nil)
        #expect(try await cache.updatePendingEdit(id: intent.id, in: "chat", messageID: "1", expected: .prepared, stage: .dispatched))
        let reopened = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        #expect(try await reopened.pendingEdit(in: "chat", messageID: "1")?.document.plainText == "after")
        #expect(try await !reopened.updatePendingEdit(id: intent.id, in: "chat", messageID: "1", expected: .dispatched, stage: .prepared))
        #expect(try await !reopened.clearPendingEdit(id: intent.id, in: "chat", messageID: "1"))
        #expect(try await reopened.updatePendingEdit(id: intent.id, in: "chat", messageID: "1", expected: .dispatched, stage: .uncertain))
        #expect(try await !reopened.clearPendingEdit(id: intent.id, in: "chat", messageID: "1"))
        #expect(try await reopened.confirmPendingEdit(id: intent.id, in: "chat", messageID: "1"))
        #expect(try await reopened.pendingEdit(in: "chat", messageID: "1") == nil)
        withExtendedLifetime(lease) { }
    }
}
