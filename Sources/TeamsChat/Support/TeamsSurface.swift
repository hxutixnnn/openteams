import SwiftUI

enum TeamsSurface {
    static let nestedRadius: CGFloat = 8
    static let cardRadius: CGFloat = 8
    static let controlRadius: CGFloat = 8
    static let inset: CGFloat = 10
    static let borderWidth: CGFloat = 1

    static var window: Color { Color(nsColor: .windowBackgroundColor) }
    static var border: Color { Color(nsColor: .separatorColor) }
    static var panel: Color { Color(nsColor: .textBackgroundColor) }
    static var nested: Color { Color(nsColor: .controlBackgroundColor) }
    static var input: Color { Color(nsColor: .textBackgroundColor) }
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
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .background(TeamsSurface.panel)
                    .padding(.trailing, showInspector && besideTimeline ? inspectorWidth : 0)
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
                    .glassEffect(.regular, in: Rectangle())
                    .overlay(alignment: .leading) { Divider().allowsHitTesting(false) }
                }
            }
        }
    }
}
