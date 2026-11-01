import SwiftUI

enum TeamsSurface {
    static let panelRadius: CGFloat = 18
    static let nestedRadius: CGFloat = 14
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let inset: CGFloat = 10
    static let borderWidth: CGFloat = 1

    static var window: Color { neutral(light: 0.94, dark: 0.12) }
    static var border: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor.labelColor.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.12 : 0.08)
        })
    }
    static var panel: Color { neutral(light: 0.995, dark: 0.16) }
    static var nested: Color { Color.primary.opacity(0.035) }
    static var input: Color { Color(nsColor: .textBackgroundColor) }

    private static func neutral(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
}

struct TeamsInsetPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(TeamsSurface.panel)
            .clipShape(RoundedRectangle(cornerRadius: TeamsSurface.panelRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TeamsSurface.panelRadius, style: .continuous)
                .strokeBorder(TeamsSurface.border, lineWidth: TeamsSurface.borderWidth).allowsHitTesting(false))
            .padding(TeamsSurface.inset)
    }
}

struct TeamsControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(TeamsSurface.input, in: RoundedRectangle(cornerRadius: TeamsSurface.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TeamsSurface.controlRadius, style: .continuous)
                .strokeBorder(TeamsSurface.border, lineWidth: TeamsSurface.borderWidth).allowsHitTesting(false))
    }
}

struct TeamsSectionPanel: ViewModifier {
    var radius: CGFloat = TeamsSurface.nestedRadius

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(TeamsSurface.border, lineWidth: TeamsSurface.borderWidth).allowsHitTesting(false))
    }
}

struct TeamsConversationLayout<Timeline: View, Inspector: View>: View {
    @Binding var showInspector: Bool
    @ViewBuilder let timeline: () -> Timeline
    @ViewBuilder let inspector: () -> Inspector

    var body: some View {
        GeometryReader { geometry in
            let besideTimeline = geometry.size.width >= 720
            let inspectorWidth = min(300, max(0, geometry.size.width - 2 * TeamsSurface.inset))
            ZStack(alignment: .trailing) {
                timeline()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, showInspector && besideTimeline ? inspectorWidth + TeamsSurface.inset : 0)
                if showInspector {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Conversation details").font(.callout.weight(.semibold))
                            Spacer()
                            Button { showInspector = false } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .help("Close conversation details")
                                .accessibilityLabel("Close conversation details")
                        }
                        .padding(12)
                        inspector()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: inspectorWidth)
                    .background(TeamsSurface.panel)
                    .clipShape(RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous)
                        .strokeBorder(TeamsSurface.border, lineWidth: TeamsSurface.borderWidth).allowsHitTesting(false))
                    .padding(TeamsSurface.inset)
                }
            }
        }
        .modifier(TeamsInsetPanel())
    }
}

struct TeamsPillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.caption.weight(.medium))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(configuration.isOn ? Color.primary.opacity(0.12) : TeamsSurface.nested, in: Capsule())
                .overlay(Capsule().strokeBorder(configuration.isOn ? Color.primary.opacity(0.22) : TeamsSurface.border, lineWidth: TeamsSurface.borderWidth))
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}
