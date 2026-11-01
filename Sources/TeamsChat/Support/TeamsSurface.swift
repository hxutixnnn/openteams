import SwiftUI

enum TeamsSurface {
    static let panelRadius: CGFloat = 16
    static let nestedRadius: CGFloat = 8
    static let inset: CGFloat = 12

    static var border: Color { Color.primary.opacity(0.10) }
    static var panel: Color { Color(nsColor: .windowBackgroundColor) }
    static var nested: Color { Color.primary.opacity(0.035) }
    static var input: Color { Color(nsColor: .textBackgroundColor) }
}

struct TeamsInsetPanel: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    func body(content: Content) -> some View {
        content
            .background(TeamsSurface.panel, in: RoundedRectangle(cornerRadius: TeamsSurface.panelRadius))
            .clipShape(RoundedRectangle(cornerRadius: TeamsSurface.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: TeamsSurface.panelRadius).strokeBorder(TeamsSurface.border, lineWidth: 1 / max(displayScale, 1)))
            .padding(TeamsSurface.inset)
    }
}

struct TeamsPillToggleStyle: ToggleStyle {
    @Environment(\.displayScale) private var displayScale
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.caption.weight(.medium))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(configuration.isOn ? Color.primary.opacity(0.12) : Color.primary.opacity(0.035), in: Capsule())
                .overlay(Capsule().strokeBorder(configuration.isOn ? Color.primary.opacity(0.22) : TeamsSurface.border, lineWidth: 1 / max(displayScale, 1)))
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
