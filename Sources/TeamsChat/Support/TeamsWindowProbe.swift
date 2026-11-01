import AppKit
import SwiftUI

struct TeamsWindowProbe: NSViewRepresentable {
    let attached: (NSWindow) -> Void
    func makeNSView(context: Context) -> Probe {
        let view = Probe(); view.attached = attached; return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.attached = attached
        view.reportWindow()
    }
    final class Probe: NSView {
        var attached: ((NSWindow) -> Void)?
        private weak var reportedWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { reportedWindow = nil }
            reportWindow()
        }
        func reportWindow() {
            guard let window, reportedWindow !== window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.reportedWindow = window
                self.attached?(window)
            }
        }
    }
}
