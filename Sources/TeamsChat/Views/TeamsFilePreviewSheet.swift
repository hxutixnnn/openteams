import AppKit
import SwiftUI
import PDFKit
import TeamsCore

struct TeamsFilePreviewSheet: View {
    let file: TeamsFileLink
    let attachment: TeamsSharePointAttachment
    let load: (TeamsSharePointAttachment) async throws -> Data
    @Environment(\.dismiss) private var dismiss
    @ViewState<NSImage?> private var picture = nil
    @ViewState<PDFDocument?> private var document = nil
    @ViewState<Bool> private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(file.title).font(.headline).lineLimit(1)
                Spacer()
                Link("Open attachment", destination: file.url)
                Button("Close") { dismiss() }
            }
            if let document {
                TeamsPDFPreview(document: document)
                    .accessibilityLabel("Preview of \(file.title)")
            } else if let picture {
                Image(nsImage: picture).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Preview of \(file.title)")
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "doc").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Preview unavailable").font(.headline)
                    Text("Open the attachment to view it.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .modifier(TeamsInsetPanel())
        .background(TeamsSurface.window)
        .buttonBorderShape(.roundedRectangle(radius: TeamsSurface.controlRadius)).frame(minWidth: 520, minHeight: 400)
        .task {
            do {
                let data = try await load(attachment)
                try Task.checkCancellation()
                if attachment.supportsPDFPreview {
                    guard let pdf = PDFDocument(data: data) else { failed = true; return }
                    document = pdf
                } else {
                    guard let image = NSImage(data: data) else { failed = true; return }
                    picture = image
                }
            } catch { if !Task.isCancelled { failed = true } }
        }
        .onDisappear { picture = nil; document = nil }
    }
}

private struct TeamsPDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: ()) { view.document = nil }
}
