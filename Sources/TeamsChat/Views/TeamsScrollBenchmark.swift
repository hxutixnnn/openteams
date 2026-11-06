#if DEBUG
import AppKit
import QuartzCore
import SwiftUI

@MainActor enum TeamsBenchmarkCounters {
    static var detailBody = 0
    static var rowBody = 0
    static var rowText = 0
}

@MainActor @Observable final class TeamsScrollBenchmarkDriver {
    struct Report: Codable {
        let label: String
        let refreshRate: Int
        let warmupSeconds: Double
        let measuredSeconds: Double
        let frames: Int
        let framesPerSecond: Double
        let intervalP50ms: Double
        let intervalP95ms: Double
        let intervalP99ms: Double
        let intervalMaxMs: Double
        let longFrames: Int
        let longFrameShare: Double
        let messagesPerSecond: Double
        let steps: Int
        let windowVisible: Bool
        let mode: String
        let scrolledDistance: Double
        let detailBodiesPerSecond: Double
        let rowBodiesPerSecond: Double
        let rowTextsPerSecond: Double
    }

    static let requested = ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--scroll-benchmark") })
    static let label: String = {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--scroll-benchmark-label=") }) else {
            return "unlabelled"
        }
        return String(argument.dropFirst("--scroll-benchmark-label=".count))
    }()

    var targetID: String?
    private let warmup = 2.0
    private let duration = 8.0
    private let messagesPerSecond = 26.0
    private weak var window: NSWindow?
    private var timer: Timer?
    private var output: URL?
    private var ids: [String] = []
    private var intervals: [Double] = []
    private var startTime: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var recording = false
    private var steps = 0
    private var refreshRate = 60
    private var started = false
    private var travelled: CGFloat = 0
    private weak var scroll: NSScrollView?
    private var lastWheelTick: CFTimeInterval = 0
    private let mode = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--scroll-benchmark-mode=") })
        .map { String($0.dropFirst("--scroll-benchmark-mode=".count)) } ?? "jump"

    func start(ids: [String], output: URL) {
        guard !started, ids.count > 4 else { return }
        started = true
        self.ids = ids
        self.output = output
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            finish(error: "no visible window")
            return
        }
        self.window = window
        refreshRate = window.screen?.maximumFramesPerSecond ?? 60
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        targetID = ids[ids.count / 2]
        if mode == "wheel" { scroll = Self.timelineScroll(in: window) }
        startTime = CACurrentMediaTime()
        if mode == "bounds" { scroll = Self.timelineScroll(in: window) }
        let interval = 1.0 / Double(refreshRate)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if recording { intervals.append(now - lastTick) }
        lastTick = now
        let elapsed = now - startTime
        if !recording && elapsed >= warmup {
            recording = true; intervals.removeAll(keepingCapacity: true)
            TeamsBenchmarkCounters.detailBody = 0; TeamsBenchmarkCounters.rowBody = 0; TeamsBenchmarkCounters.rowText = 0
            return
        }
        if elapsed >= warmup + duration { finish(error: nil); return }
        guard recording else { return }
        if mode == "wheel" {
            let step = now - max(lastWheelTick, now - 0.05)
            lastWheelTick = now
            driveWheel(by: CGFloat(-1400 * step))
            return
        }
        if mode == "bounds" {
            let step = now - max(lastWheelTick, now - 0.05)
            lastWheelTick = now
            driveBounds(by: CGFloat(-1400 * step))
            return
        }
        let wanted = min(Int((elapsed - warmup) * messagesPerSecond), ids.count - 1)
        let wantedID = ids[wanted]
        if wantedID != targetID { targetID = wantedID; steps += 1 }
    }

    private var traceCount = 0
    private var diagnostics: [String] = []
    private func driveBounds(by delta: CGFloat) {
        guard let scroll, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let before = clip.bounds.origin.y
        let maximum = max(document.bounds.height - clip.bounds.height, 0)
        let proposed = min(max(before + delta, 0), maximum)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: proposed))
        scroll.reflectScrolledClipView(clip)
        let after = clip.bounds.origin.y
        travelled += abs(scroll.documentVisibleRect.minY - before)
        if traceCount < 12 {
            traceCount += 1
            diagnostics.append("tick \(traceCount): before=\(before) proposed=\(proposed) after=\(after) visible=\(scroll.documentVisibleRect.minY)")
        }
    }

    private func driveWheel(by delta: CGFloat) {
        guard let scroll, let window else { return }
        let before = scroll.documentVisibleRect.minY
        let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(delta.rounded()), wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.location = CGPoint(x: center.x, y: center.y)
        guard let wheel = NSEvent(cgEvent: event) else { return }
        window.sendEvent(wheel)
        travelled += abs(scroll.documentVisibleRect.minY - before)
    }

    private static func timelineScroll(in window: NSWindow) -> NSScrollView? {
        var candidates: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView, document.bounds.height > 2000 {
                candidates.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        return candidates.max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
    }

    private func finish(error: String?) {
        timer?.invalidate()
        timer = nil
        guard let output else { return }
        let sorted = intervals.sorted()
        let expected = 1.0 / Double(refreshRate)
        let long = intervals.filter { $0 > expected * 1.5 }
        let measured = intervals.reduce(0, +)
        let report = Report(
            label: TeamsScrollBenchmarkDriver.label,
            refreshRate: refreshRate,
            warmupSeconds: warmup,
            measuredSeconds: measured,
            frames: intervals.count,
            framesPerSecond: measured > 0 ? Double(intervals.count) / measured : 0,
            intervalP50ms: percentile(sorted, 0.50) * 1000,
            intervalP95ms: percentile(sorted, 0.95) * 1000,
            intervalP99ms: percentile(sorted, 0.99) * 1000,
            intervalMaxMs: (sorted.last ?? 0) * 1000,
            longFrames: long.count,
            longFrameShare: intervals.isEmpty ? 0 : Double(long.count) / Double(intervals.count),
            messagesPerSecond: messagesPerSecond,
            steps: steps,
            windowVisible: window?.occlusionState.contains(.visible) ?? false,
            mode: mode,
            scrolledDistance: Double(travelled),
            detailBodiesPerSecond: measured > 0 ? Double(TeamsBenchmarkCounters.detailBody) / measured : 0,
            rowBodiesPerSecond: measured > 0 ? Double(TeamsBenchmarkCounters.rowBody) / measured : 0,
            rowTextsPerSecond: measured > 0 ? Double(TeamsBenchmarkCounters.rowText) / measured : 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var payload = (try? encoder.encode(report)) ?? Data()
        if let error, let message = try? JSONSerialization.data(withJSONObject: ["error": error], options: .prettyPrinted) {
            payload = message
        }
        try? payload.write(to: output, options: .atomic)
        FileHandle.standardOutput.write(payload + Data("\n".utf8))
        NSApp.terminate(nil)
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(position, 0), sorted.count - 1)]
    }
}

struct TeamsScrollBenchmarkTarget: ViewModifier {
    let ids: [String]
    @State private var driver = TeamsScrollBenchmarkDriver()

    func body(content: Content) -> some View {
        content
            .scrollPosition(id: Binding(get: { driver.targetID }, set: { driver.targetID = $0 }), anchor: .center)
            .task(id: ids.count) {
                guard TeamsScrollBenchmarkDriver.requested, !ids.isEmpty,
                      let root = TeamsPerformanceFixtureConfiguration.root else { return }
                try? await Task.sleep(for: .seconds(3))
                driver.start(ids: ids, output: root.appendingPathComponent("scroll-benchmark.json"))
            }
    }
}
#endif
