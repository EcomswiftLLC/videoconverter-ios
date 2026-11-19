import SwiftUI
import UIKit
import CoreText

/// Fluxa design tokens. The app is dark only: deep ink surfaces, one aurora accent (mint into violet), serif headlines.
enum FX {
    enum Palette {
        /// App background. Deep ink, a hair of blue.
        static let lens     = Color(hex: 0x080B12)
        /// First surface above the background.
        static let carbon   = Color(hex: 0x0F1422)
        /// Raised surface (panels, rows when pressed).
        static let graphite = Color(hex: 0x181E30)
        /// Hairline rules and outlines.
        static let line     = Color.white.opacity(0.10)
        /// Primary text.
        static let paper    = Color(hex: 0xECEFF6)
        /// Secondary text. Over 7:1 on `lens`.
        static let mist     = Color(hex: 0x9AA3B5)
        /// The accent: aurora mint, fading to violet.
        static let glow     = Color(hex: 0x7AE7D3)
        static let glowDeep = Color(hex: 0x9C8CFF)
        /// Text and icons on top of the accent.
        static let onGlow   = Color(hex: 0x04110F)
        static let danger   = Color(hex: 0xF2998F)
        static let success  = Color(hex: 0x8FD6A6)
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let chip: CGFloat = 10
        static let control: CGFloat = 14
        static let panel: CGFloat = 22
    }

    /// Typography. Headlines are set in Instrument Serif (an editorial display serif), everything else in Manrope
    /// (a crisp geometric sans with tabular figures). Both are SIL Open Font License fonts bundled in the app
    /// (see Settings > Open-source licences). All sizes follow the person's text size setting.
    enum Font {
        static let serifName = "InstrumentSerif-Regular"
        static let serifItalicName = "InstrumentSerif-Italic"
        static let regularName = "Manrope-Regular"
        static let mediumName = "Manrope-Medium"
        static let semiboldName = "Manrope-SemiBold"
        static let boldName = "Manrope-Bold"
        /// Every bundled font file, registered at launch in case the Info.plist list is ever out of date.
        static let bundled = ["InstrumentSerif-Regular", "InstrumentSerif-Italic", "Manrope-Regular", "Manrope-Medium", "Manrope-SemiBold", "Manrope-Bold"]

        /// Instrument Serif is a narrow display face, so it is drawn a little larger than a text serif would be.
        private static let serifBoost: CGFloat = 1.1

        /// Headline sizes follow the text size setting, up to 1.6 times, so a headline never outgrows the screen.
        private static func scaled(_ size: CGFloat, _ style: UIFont.TextStyle) -> CGFloat {
            min(UIFontMetrics(forTextStyle: style).scaledValue(for: size), size * 1.6)
        }
        static func display(_ size: CGFloat = 38) -> SwiftUI.Font {
            .custom(serifName, fixedSize: scaled(size * serifBoost, .largeTitle))
        }
        static func title(_ size: CGFloat = 24) -> SwiftUI.Font {
            .custom(serifName, fixedSize: scaled(size * serifBoost, .title2))
        }
        static let headline = SwiftUI.Font.custom(semiboldName, size: 17, relativeTo: .headline)
        static let body = SwiftUI.Font.custom(regularName, size: 17, relativeTo: .body)
        static let callout = SwiftUI.Font.custom(regularName, size: 16, relativeTo: .callout)
        static let label = SwiftUI.Font.custom(mediumName, size: 13, relativeTo: .footnote)
        static let caption = SwiftUI.Font.custom(regularName, size: 12, relativeTo: .caption)
        static let number = SwiftUI.Font.custom(mediumName, size: 16, relativeTo: .callout).monospacedDigit()
        /// Format names on tiles and in the guide (MP4, MKV, FLAC).
        static let tile = SwiftUI.Font.custom(boldName, size: 19, relativeTo: .title3)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension View {
    /// Full-screen background in the app's base colour.
    func apScreen() -> some View {
        background(FX.Palette.lens.ignoresSafeArea())
    }

    /// Editorial headline treatment.
    func apDisplay(_ size: CGFloat = 38) -> some View {
        font(FX.Font.display(size)).tracking(-0.6).foregroundStyle(FX.Palette.paper)
    }
}

/// Appearance for system bars, set once at launch.
enum FXAppearance {
    /// Makes the bundled fonts available to SwiftUI and UIKit (a no-op for any the Info.plist already registered).
    static func registerFonts() {
        for name in FX.Font.bundled {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func configure() {
        registerFonts()
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        let titleFont = UIFontMetrics(forTextStyle: .headline).scaledFont(for: UIFont(name: FX.Font.semiboldName, size: 17) ?? .systemFont(ofSize: 17, weight: .semibold))
        nav.titleTextAttributes = [.foregroundColor: UIColor(hex: 0xECEFF6), .font: titleFont]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(hex: 0xECEFF6)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(hex: 0x7AE7D3)
    }
}
