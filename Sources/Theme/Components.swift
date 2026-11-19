import SwiftUI
import UIKit

// MARK: - Buttons

enum FXButtonKind { case primary, secondary, quiet }

struct FXButtonStyle: ButtonStyle {
    var kind: FXButtonKind = .primary
    var fullWidth: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FX.Font.headline)
            .foregroundStyle(foreground)
            .padding(.horizontal, FX.Space.l)
            .padding(.vertical, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 48)
            .background(background(pressed: configuration.isPressed))
            .overlay(
                RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous)
                    .strokeBorder(kind == .secondary ? FX.Palette.paper.opacity(0.28) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return FX.Palette.onGlow
        case .secondary: return FX.Palette.paper
        case .quiet: return FX.Palette.glow
        }
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        switch kind {
        case .primary:
            LinearGradient(
                colors: [FX.Palette.glow, FX.Palette.glowDeep.opacity(pressed ? 1 : 0.92)],
                startPoint: .top, endPoint: .bottom
            )
        case .secondary:
            if pressed { FX.Palette.graphite } else { Color.clear }
        case .quiet:
            Color.clear
        }
    }
}

extension ButtonStyle where Self == FXButtonStyle {
    static var apPrimary: FXButtonStyle { FXButtonStyle(kind: .primary) }
    static var apPrimaryWide: FXButtonStyle { FXButtonStyle(kind: .primary, fullWidth: true) }
    static var apSecondary: FXButtonStyle { FXButtonStyle(kind: .secondary) }
    static var apSecondaryWide: FXButtonStyle { FXButtonStyle(kind: .secondary, fullWidth: true) }
    static var apQuiet: FXButtonStyle { FXButtonStyle(kind: .quiet) }
}

// MARK: - Structure

struct FXHairline: View {
    var body: some View {
        Rectangle().fill(FX.Palette.line).frame(height: 1 / UIScreen.main.scale)
    }
}

/// Sentence-case section title in the editorial serif.
struct FXSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(FX.Font.title(22))
            .foregroundStyle(FX.Palette.paper)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Small pill used for options (ratio, format, preset).
struct FXChip: View {
    let title: String
    var systemImage: String? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(FX.Font.label).lineLimit(1)
            }
            .foregroundStyle(selected ? FX.Palette.onGlow : FX.Palette.paper)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(selected ? FX.Palette.glow : FX.Palette.graphite, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : FX.Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A group of chips that scrolls sideways.
struct FXChipRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FX.Space.s) { content() }
                .padding(.horizontal, FX.Space.m)
        }
    }
}

// MARK: - Fluxa mark

/// The Fluxa mark: two arrows chasing each other around a play triangle, drawn in code so it stays sharp at any size.
struct FluxaMark: View {
    var lineWidth: CGFloat = 3
    var gradient = LinearGradient(colors: [FX.Palette.glow, FX.Palette.glowDeep], startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let r = side / 2 - lineWidth * 1.6
            Canvas { context, _ in
                func arc(from: Double, to: Double) -> Path {
                    var p = Path()
                    p.addArc(center: c, radius: r, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                    return p
                }
                let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                context.stroke(arc(from: 200, to: 340), with: .style(gradient), style: style)
                context.stroke(arc(from: 20, to: 160), with: .style(gradient), style: style)
                // Arrow heads at the end of each arc.
                for angle in [340.0, 160.0] {
                    let a = angle * .pi / 180
                    let tip = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
                    let tangent = a + .pi / 2
                    let size = lineWidth * 3.2
                    var head = Path()
                    head.move(to: CGPoint(x: tip.x + CGFloat(cos(tangent)) * size, y: tip.y + CGFloat(sin(tangent)) * size))
                    head.addLine(to: CGPoint(x: tip.x + CGFloat(cos(a)) * size * 0.9, y: tip.y + CGFloat(sin(a)) * size * 0.9))
                    head.addLine(to: CGPoint(x: tip.x - CGFloat(cos(a)) * size * 0.9, y: tip.y - CGFloat(sin(a)) * size * 0.9))
                    head.closeSubpath()
                    context.fill(head, with: .style(gradient))
                }
                // Play triangle.
                let t = r * 0.46
                var play = Path()
                play.move(to: CGPoint(x: c.x - t * 0.55, y: c.y - t))
                play.addLine(to: CGPoint(x: c.x + t * 0.95, y: c.y))
                play.addLine(to: CGPoint(x: c.x - t * 0.55, y: c.y + t))
                play.closeSubpath()
                context.fill(play, with: .style(gradient))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Haptics

enum FXHaptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Flow layout

/// Wraps its children onto as many lines as needed, like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
