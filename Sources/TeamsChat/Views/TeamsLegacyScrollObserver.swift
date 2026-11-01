import AppKit
import SwiftUI

enum TeamsLegacyScrollGeometry {
    static func isAtBottom(document: CGRect, visible: CGRect, flipped: Bool) -> Bool {
        let distance = flipped ? document.maxY - visible.maxY : visible.minY - document.minY
        return max(0, distance) <= 40
    }
}

struct TeamsLegacyGrowthDecision {
    enum Action: Equatable { case update, follow, deferFollow }
    private(set) var deferred = false

    mutating func observe(wasBottom: Bool, isBottom: Bool, grew: Bool, moved: Bool, inputActive: Bool) -> Action {
        if moved { deferred = false }
        if grew && wasBottom && !isBottom {
            if inputActive && !moved { deferred = true; return .deferFollow }
            if !inputActive { return .follow }
        }
        if deferred && !moved && !isBottom { return .deferFollow }
        if isBottom { deferred = false }
        return .update
    }

    mutating func finishInput() -> Bool {
        let follow = deferred
        deferred = false
        return follow
    }
}

struct TeamsLegacyScrollObserver: NSViewRepresentable {
    let changed: (Bool) -> Void
    let grewAtBottom: () -> Void
    let userScrolled: () -> Void
    let layoutReady: (Bool, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        context.coordinator.changed = changed
        context.coordinator.grewAtBottom = grewAtBottom
        context.coordinator.userScrolled = userScrolled
        context.coordinator.layoutReady = layoutReady
        view.attachLater()
    }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) { coordinator.detach(); view.coordinator = nil }

    @MainActor final class Probe: NSView {
        weak var coordinator: Coordinator?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attachLater() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachLater() }
        func attachLater() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { self?.coordinator?.detach(); return }
                self.coordinator?.attach(to: self.enclosingScrollView)
            }
        }
    }

    @MainActor final class Coordinator {
        var changed: (Bool) -> Void = { _ in }
        var grewAtBottom: () -> Void = {}
        var userScrolled: () -> Void = {}
        var layoutReady: (Bool, Bool) -> Void = { _, _ in }
        private weak var scroll: NSScrollView?
        private weak var document: NSView?
        private var observers: [NSObjectProtocol] = []
        private var inputMonitor: Any?
        private var revision = UUID()
        private var scheduled = false
        private var userScrolling = false
        private var userIntentPending = false
        private var inputRevision = UUID()
        private var scrollerDragging = false
        private var last: Metrics?
        private var growthDecision = TeamsLegacyGrowthDecision()

        private struct Metrics: Equatable {
            let content: CGFloat
            let viewport: CGFloat
            let atBottom: Bool
            let offset: CGFloat
        }

        func attach(to candidate: NSScrollView?) {
            guard let candidate, let doc = candidate.documentView else { detach(); return }
            if scroll === candidate && document === doc { schedule(); return }
            detach()
            scroll = candidate; document = doc
            let clip = candidate.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            doc.postsFrameChangedNotifications = true
            candidate.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            func observe(_ name: Notification.Name, _ object: AnyObject, _ action: @escaping @MainActor (Coordinator) -> Void) {
                let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let self { action(self) } }
                }
                observers.append(token)
            }
            observe(NSView.boundsDidChangeNotification, clip) { $0.schedule() }
            observe(NSView.frameDidChangeNotification, clip) { $0.schedule() }
            observe(NSView.frameDidChangeNotification, doc) { $0.schedule() }
            observe(NSView.frameDidChangeNotification, candidate) { $0.schedule() }
            observe(NSScrollView.willStartLiveScrollNotification, candidate) { $0.userScrolling = true; $0.noteUserInput() }
            observe(NSScrollView.didLiveScrollNotification, candidate) { $0.noteUserInput(); $0.schedule() }
            observe(NSScrollView.didEndLiveScrollNotification, candidate) { $0.userScrolling = false; $0.schedule(); $0.scheduleIntentExpiry() }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--timeline-observer-diagnostics") {
                let token = center.addObserver(forName: Notification.Name("TeamsFixtureFocusTimeline"), object: nil, queue: .main) { [weak candidate] _ in
                    MainActor.assumeIsolated { if let candidate { candidate.window?.makeFirstResponder(candidate.documentView) } }
                }
                observers.append(token)
            }
            #endif
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self, weak candidate] event in
                MainActor.assumeIsolated {
                    guard let self, let candidate, event.window === candidate.window else { return }
                    let relevant: Bool
                    if event.type == .keyDown {
                        let keys: Set<UInt16> = [49, 115, 116, 119, 121, 125, 126]
                        let focus = candidate.window?.firstResponder as? NSView
                        let nearest = (focus as? NSScrollView) ?? focus?.enclosingScrollView
                        relevant = keys.contains(event.keyCode) && nearest === candidate && !(focus is NSTextView)
                    } else if event.type == .leftMouseDragged || event.type == .leftMouseUp {
                        relevant = self.scrollerDragging
                        if event.type == .leftMouseUp { self.scrollerDragging = false; self.userScrolling = false }
                    } else {
                        let root = candidate.window?.contentView
                        let hit = root?.hitTest(root!.convert(event.locationInWindow, from: nil))
                        let nearest = (hit as? NSScrollView) ?? hit?.enclosingScrollView
                        if event.type == .scrollWheel { relevant = nearest === candidate }
                        else {
                            var view = hit
                            var isScroller = false
                            while let current = view, current !== candidate {
                                if current is NSScroller { isScroller = true; break }
                                view = current.superview
                            }
                            relevant = nearest === candidate && isScroller
                            if relevant { self.scrollerDragging = true; self.userScrolling = true }
                        }
                    }
                    if relevant {
                        self.noteUserInput()
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--timeline-release-refresh-on-scroll") {
                            NotificationCenter.default.post(name: Notification.Name("TeamsFixtureReleaseRefreshOnScroll"), object: nil)
                        }
                        #endif
                    }
                }
                return event
            }
            schedule()
        }
        func detach() {
            revision = UUID(); inputRevision = UUID(); scheduled = false; userScrolling = false; userIntentPending = false; scrollerDragging = false; last = nil; growthDecision = .init()
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll(); scroll = nil; document = nil
        }
        private func noteUserInput() {
            userIntentPending = true; userScrolled(); scheduleIntentExpiry()
        }
        private func scheduleIntentExpiry() {
            inputRevision = UUID()
            let expected = revision, input = inputRevision
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.revision == expected, self.inputRevision == input,
                      !self.userScrolling, !self.scrollerDragging else { return }
                self.userIntentPending = false
                if self.growthDecision.finishInput() { self.grewAtBottom() }
            }
        }
        private func schedule() {
            guard !scheduled else { return }
            scheduled = true
            let expected = revision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == expected else { return }
                self.scheduled = false; self.measure()
            }
        }
        private func measure() {
            guard let scroll, let document, scroll.documentView === document else { attach(to: scroll); return }
            let bounds = document.bounds, visible = scroll.documentVisibleRect
            let height = max(bounds.height, 0), viewport = max(visible.height, 0)
            let metrics = Metrics(content: height, viewport: viewport,
                                  atBottom: TeamsLegacyScrollGeometry.isAtBottom(document: bounds, visible: visible, flipped: document.isFlipped), offset: visible.minY)
            guard metrics != last else { return }
            let old = last; last = metrics
            if height > 0 { layoutReady(metrics.atBottom, height > viewport + 1) }
            let deliberate = userScrolling || userIntentPending
            let moved = old.map { $0.offset != metrics.offset } ?? false
            if moved { userIntentPending = false }
            let action = growthDecision.observe(wasBottom: old?.atBottom ?? false, isBottom: metrics.atBottom,
                                                grew: old.map { height > $0.content + 1 } ?? false,
                                                moved: moved, inputActive: deliberate)
            switch action {
            case .follow: grewAtBottom()
            case .deferFollow: break
            case .update: changed(metrics.atBottom)
            }
        }
    }
}
