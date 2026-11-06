#if DEBUG
import AppKit
import PDFKit
import CoreText
import SwiftUI
import TeamsCore

struct TeamsFilePreviewFixtureView: View {
    @ViewState<UUID> private var epoch = UUID()
    @ViewState<Bool> private var connected = true
    private var isPDF: Bool { ProcessInfo.processInfo.arguments.contains("--file-preview-pdf-fixture") }
    private var sample: TeamsRenderedMessage {
        let name = isPDF ? "Sample document.pdf" : "Sample image.png"
        let files = "[{\"version\":2,\"id\":\"file\",\"title\":\"\(name)\",\"baseUrl\":\"https://example.sharepoint.com/sites/team\",\"objectUrl\":\"https://example.sharepoint.com/sites/team/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)\"}]"
        let message = TeamsWebMessage(id: "message", imDisplayName: "Fixture", properties: .object(["files": .string(files)]))
        return TeamsRenderedMessage(message, accountScope: "fixture:account", accountRevision: epoch, chatID: "chat")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Attachment preview fixture").font(.title2)
            Button("Disconnect fixture") { connected = false }
            TeamsMessageRow(message: sample, compact: false, grouped: false, accountID: "account", canEdit: false, canReact: false,
                            mediaRevision: epoch, mediaRefreshRevision: epoch,
                            actions: previewFixtureActions(loadPreview: { _ in
                                if ProcessInfo.processInfo.arguments.contains("--file-preview-failure-fixture") { throw TeamsMediaError.unavailable }
                                if ProcessInfo.processInfo.arguments.contains("--file-preview-disconnect-fixture") {
                                    connected = false
                                    try await Task.sleep(for: .seconds(60))
                                }
                                if ProcessInfo.processInfo.arguments.contains("--file-preview-loading-fixture") { try await Task.sleep(for: .seconds(60)) }
                                if isPDF { return makeSamplePDF() }
                                let image = NSImage(size: NSSize(width: 640, height: 400))
                                image.lockFocus()
                                NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 640, height: 400).fill()
                                NSColor.systemYellow.setFill(); NSBezierPath(ovalIn: NSRect(x: 220, y: 100, width: 200, height: 200)).fill()
                                ("Sample PDF preview" as NSString).draw(at: NSPoint(x: 28, y: 350), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black])
                                image.unlockFocus()
                                return image.tiffRepresentation!
                            }), filePreviewConnected: connected)
            Spacer()
        }.padding(24).frame(minWidth: 700, minHeight: 500)
    }
    private func previewFixtureActions(loadPreview: @escaping (TeamsSharePointAttachment) async throws -> Data) -> TeamsMessageRowActions {
        let actions = TeamsMessageRowActions()
        actions.loadImage = { _, _ in throw TeamsMediaError.unavailable }
        actions.loadPhoto = { _ in throw TeamsMediaError.unavailable }
        actions.replyAuthor = { _ in "Fixture" }
        actions.loadFilePreview = loadPreview
        return actions
    }

    private func makeSamplePDF() -> Data {
        let bytes = NSMutableData()
        let consumer = CGDataConsumer(data: bytes)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for label in ["FIRST PAGE — SELECTABLE TEXT", "SECOND PAGE — SELECTABLE TEXT"] {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.systemTeal.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
            let text = NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = CGPoint(x: 42, y: 720)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }
}
#endif
