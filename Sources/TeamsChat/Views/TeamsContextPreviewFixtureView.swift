#if DEBUG
import AppKit
import CoreText
import Observation
import SwiftUI
import TeamsCore

private actor ContextPreviewTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.url!.path.contains("/epochTimeStamp/") {
            let id = request.url!.lastPathComponent
            let fileName = ProcessInfo.processInfo.arguments.contains("--context-preview-pdf-fixture") ? "sample.pdf" : "sample.png"
            let files = "[{\"version\":2,\"id\":\"file\",\"title\":\"\(fileName)\",\"baseUrl\":\"https://example.sharepoint.com/sites/team\",\"objectUrl\":\"https://example.sharepoint.com/sites/team/\(fileName)\"}]"
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: [.init(id: id, content: "Context fixture", messageType: "Text", version: "1", properties: .object(["files": .string(files)]))]))
        } else { data = try JSONEncoder().encode(TeamsWebChatPage(items: [.init(id: "chat", title: "Context fixture")])) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private actor ContextPreviewGate {
    var pending: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { pending = $0 } }
    func release() { pending?.resume(); pending = nil }
}
@MainActor @Observable private final class ContextPreviewController {
    let store = TeamsReaderStore(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), transport: ContextPreviewTransport())
    let gate = ContextPreviewGate()
    var released = false
    func start() async {
        await store.connect(session: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "fixture", expiresAt: .distantFuture, accountID: "fixture", tenantID: "tenant", displayName: "Fixture", messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!, accessToken: "fixture", expiresAt: .distantFuture)))
    }
    func preview(_ attachment: TeamsSharePointAttachment) async throws -> Data {
        if ProcessInfo.processInfo.arguments.contains("--context-preview-held-fixture") { await gate.hold() }
        if attachment.supportsPDFPreview {
            let bytes = NSMutableData(), consumer = CGDataConsumer(data: bytes)!
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.systemTeal.cgColor); context.fill(box)
            let text = NSAttributedString(string: "CONTEXT PDF PREVIEW", attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 42, y: 720); CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage(); context.closePDF(); return bytes as Data
        }
        let image = NSImage(size: NSSize(width: 640, height: 400)); image.lockFocus()
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        NSColor.systemYellow.setFill(); NSBezierPath(ovalIn: NSRect(x: 220, y: 100, width: 200, height: 200)).fill()
        image.unlockFocus(); return image.tiffRepresentation!
    }
}
struct TeamsContextPreviewFixtureView: View {
    @ViewState<ContextPreviewController> private var controller = ContextPreviewController()
    @ViewState<Bool> private var showContext = false
    var body: some View {
        VStack(spacing: 16) {
            Text("Context preview fixture")
            Text(controller.released ? "Held result released" : "Held result pending")
            Button("Open context") { Task { await controller.store.openMessageContext(in: "chat", targetID: "100"); showContext = true } }
            Button("Release held result") { Task { await controller.gate.release(); controller.released = true } }
        }.frame(minWidth: 700, minHeight: 500)
        .task { await controller.start() }
        .sheet(isPresented: $showContext, onDismiss: { controller.store.closeMessageContext() }) {
            TeamsMessageContextView(store: controller.store, chatID: "chat", close: { showContext = false }, loadFilePreview: { try await controller.preview($0) })
        }
    }
}
#endif
