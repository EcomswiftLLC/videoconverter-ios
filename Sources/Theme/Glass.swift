import SwiftUI

/// The glass panel: a blurred, lightly tinted surface with a hairline edge. Used for the editor panels,
/// the export sheet and cards that sit over a photo. Never used for plain list rows.
struct FXGlass: ViewModifier {
    var radius: CGFloat = FX.Radius.panel
    var tint: Double = 0.72

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(FX.Palette.carbon.opacity(tint)))
                .overlay(shape.strokeBorder(FX.Palette.line, lineWidth: 1))
        }
    }
}

extension View {
    func fxGlass(radius: CGFloat = FX.Radius.panel, tint: Double = 0.72) -> some View {
        modifier(FXGlass(radius: radius, tint: tint))
    }

    /// On iPad, keeps reading content a comfortable width and centred. On iPhone it changes nothing.
    func readableWidth(_ width: CGFloat = 680) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}

/// Large headline and one supporting line, used at the top of full screens and sheets.
struct FXHeader: View {
    let title: String
    var subtitle: String? = nil
    var size: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).apDisplay(size).accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(FX.Font.callout).foregroundStyle(FX.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tappable row in a settings-style list: symbol, title, optional value and a chevron.
struct FXRow: View {
    let title: String
    let symbol: String
    var value: String? = nil
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: FX.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(FX.Palette.glow)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title).font(FX.Font.body).foregroundStyle(FX.Palette.paper)
            Spacer(minLength: 8)
            if let value {
                Text(value).font(FX.Font.callout).foregroundStyle(FX.Palette.mist)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FX.Palette.mist)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 14)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

/// Round icon button with a 44 pt target, used in bars.
struct FXIconButton: View {
    let symbol: String
    let label: String
    var disabled: Bool = false
    var tint: Color = FX.Palette.paper
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(Text(label))
    }
}
