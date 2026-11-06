import AppKit
import SwiftUI

private enum TeamsSidebarMode: String, CaseIterable, Identifiable {
    case docked, hidden, overlay
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct TeamsSidebarLayout<Sidebar: View, Detail: View>: View {
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail
    @SceneStorage("teamsSidebarMode") private var storedMode = TeamsSidebarMode.docked.rawValue
    @ViewState<Bool> private var hoverOverlay = false
    @ViewState<Bool> private var pointerInSidebar = false
    @ViewState<Bool> private var pointerAtEdge = false
    @ViewState<Task<Void, Never>?> private var hoverTask = nil
    @ViewState<NSView?> private var sidebarProbe = nil

    private var mode: TeamsSidebarMode { TeamsSidebarMode(rawValue: storedMode) ?? .docked }

    var body: some View {
        GeometryReader { geometry in
            let docked = mode == .docked && geometry.size.width >= 980
            let overlay = !docked && (mode == .overlay || hoverOverlay)
            let visible = docked || overlay
            let sidebarWidth = min(260, max(0, geometry.size.width - 60))
            ZStack(alignment: .leading) {
                detail()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, docked ? sidebarWidth : 0)
                if overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { dismissOverlay() }
                        .accessibilityHidden(true)
                }
                sidebar()
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(TeamsSidebarFocusProbe { sidebarProbe = $0 })
                    .background(TeamsSurface.window)
                    .clipShape(RoundedRectangle(cornerRadius: overlay ? TeamsSurface.panelRadius : 0))
                    .overlay {
                        if overlay {
                            RoundedRectangle(cornerRadius: TeamsSurface.panelRadius)
                                .strokeBorder(TeamsSurface.border, lineWidth: TeamsSurface.borderWidth)
                                .allowsHitTesting(false)
                        }
                    }
                    .shadow(color: .black.opacity(overlay ? 0.18 : 0), radius: 12, x: 4, y: 0)
                    .padding(.vertical, overlay ? TeamsSurface.inset : 0)
                    .offset(x: visible ? 0 : -sidebarWidth - 20)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .accessibilityHidden(!visible)
                    .onHover { inside in
                        pointerInSidebar = inside
                        if inside { hoverTask?.cancel() }
                        else { scheduleDismissal() }
                    }
                if !visible {
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            pointerAtEdge = inside
                            hoverTask?.cancel()
                            if inside {
                                hoverTask = Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(180))
                                    guard !Task.isCancelled, pointerAtEdge else { return }
                                    hoverOverlay = true
                                    scheduleDismissal()
                                }
                            }
                        }
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .onChange(of: docked) { _, _ in resetHover() }
        }
        .background(TeamsSurface.window)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    select(mode == .hidden ? .docked : .hidden)
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help("Toggle Sidebar (⌃⌘S)")
                Menu {
                    Picker("Sidebar Layout", selection: Binding(get: { mode }, set: select)) {
                        ForEach(TeamsSidebarMode.allCases) { value in Text(value.title).tag(value) }
                    }
                    Button("Show Sidebar Overlay") { select(.overlay) }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                } label: {
                    Label("Sidebar Layout", systemImage: "chevron.down")
                }
                .help("Sidebar Layout")
            }
        }
        .onExitCommand {
            if mode == .overlay || hoverOverlay { dismissOverlay() }
        }
        .onDisappear { hoverTask?.cancel() }
    }

    private func select(_ value: TeamsSidebarMode) {
        resetHover()
        storedMode = value.rawValue
    }

    private func dismissOverlay() {
        if sidebarHasKeyboardFocus, let window = sidebarProbe?.window { window.makeFirstResponder(nil) }
        if mode == .overlay { storedMode = TeamsSidebarMode.hidden.rawValue }
        resetHover()
    }

    private func resetHover() {
        hoverTask?.cancel()
        hoverOverlay = false
        pointerAtEdge = false
        pointerInSidebar = false
    }

    private var sidebarHasKeyboardFocus: Bool {
        guard let probe = sidebarProbe, let responder = probe.window?.firstResponder as? NSView else { return false }
        let rect = probe.convert(responder.bounds, from: responder)
        return probe.bounds.contains(NSPoint(x: rect.midX, y: rect.midY))
    }

    private func scheduleDismissal() {
        guard hoverOverlay else { return }
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, !pointerInSidebar else { return }
                if sidebarHasKeyboardFocus { continue }
                hoverOverlay = false
                return
            }
        }
    }
}

private struct TeamsSidebarFocusProbe: NSViewRepresentable {
    let resolve: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { resolve(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
