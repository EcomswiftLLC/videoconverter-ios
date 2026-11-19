import SwiftUI
import StoreKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @ObservedObject private var ads = AdsManager.shared
    @State private var cleared = false

    private let base = "https://ecomswiftllc.github.io/fluxa"
    private var privacyURL: URL { URL(string: "\(base)/privacy/")! }
    private var termsURL: URL { URL(string: "\(base)/terms/")! }
    private var supportURL: URL { URL(string: "\(base)/support/")! }
    private var formatsURL: URL { URL(string: "\(base)/formats/")! }
    private var licensesURL: URL { URL(string: "\(base)/licenses/")! }
    private let mailURL = URL(string: "mailto:support@ecomswiftllc.com")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FX.Space.l) {
                    FXHeader(title: "Settings", subtitle: "Fluxa is free. Your files are converted on this device and never uploaded.")

                    section("Privacy") {
                        if ads.privacyOptionsRequired {
                            row("Ad privacy choices", symbol: "hand.raised") { ads.presentPrivacyOptions() }
                            FXHairline()
                        }
                        link("Privacy policy", symbol: "lock", url: privacyURL)
                        FXHairline()
                        link("Terms of use", symbol: "doc.text", url: termsURL)
                    }

                    section("Storage") {
                        row(cleared ? "Temporary files cleared" : "Clear temporary files", symbol: "trash") {
                            Workspace.clearAll()
                            cleared = true
                        }
                    }

                    section("Help") {
                        link("Support", symbol: "questionmark.circle", url: supportURL)
                        FXHairline()
                        link("Supported formats", symbol: "list.bullet.rectangle", url: formatsURL)
                        FXHairline()
                        link("Email us", symbol: "envelope", url: mailURL)
                        FXHairline()
                        row("Rate Fluxa", symbol: "star") { requestReview() }
                    }

                    section("Open-source licences") {
                        NavigationLink {
                            LicensesView()
                        } label: {
                            FXRow(title: "FFmpeg and other libraries", symbol: "shippingbox")
                        }
                        .buttonStyle(.plain)
                        FXHairline()
                        link("Licence notice and source", symbol: "link", url: licensesURL)
                    }

                    section("About") {
                        FXRow(title: "Version", symbol: "info.circle", value: version, showsChevron: false)
                            .accessibilityElement(children: .combine)
                        FXHairline()
                        Text("Files can't be converted if they are protected by DRM. Ads are shown on the Home screen and before you save or share a converted file.")
                            .font(FX.Font.caption)
                            .foregroundStyle(FX.Palette.mist)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, FX.Space.s)
                    }
                }
                .padding(.horizontal, FX.Space.m)
                .padding(.bottom, FX.Space.xl)
                .readableWidth()
            }
            .apScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(FX.Palette.glow)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FX.Space.s) {
            FXSectionTitle(text: title)
            VStack(spacing: 0) {
                FXHairline()
                content()
                FXHairline()
            }
        }
    }

    private func row(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { FXRow(title: title, symbol: symbol) }
            .buttonStyle(.plain)
    }

    private func link(_ title: String, symbol: String, url: URL) -> some View {
        Link(destination: url) { FXRow(title: title, symbol: symbol) }
    }
}

/// The licence notice shown in the app: FFmpeg under the LGPL, the libraries built into it, and where to get the source.
struct LicensesView: View {
    private let libraries: [(String, String)] = [
        ("FFmpeg", "LGPL v2.1 or later. https://ffmpeg.org"),
        ("libvpx (VP8, VP9)", "BSD 3-clause. https://www.webmproject.org"),
        ("libopus", "BSD 3-clause. https://opus-codec.org"),
        ("libvorbis, libogg, libtheora", "BSD 3-clause. https://xiph.org"),
        ("LAME (MP3)", "LGPL v2. https://lame.sourceforge.io"),
        ("libwebp", "BSD 3-clause. https://chromium.googlesource.com/webm/libwebp"),
        ("dav1d (AV1 decoding)", "BSD 2-clause. https://code.videolan.org/videolan/dav1d"),
        ("Manrope and Instrument Serif (typefaces)", "SIL Open Font License 1.1. The Manrope Project Authors, https://github.com/googlefonts/manrope. The Instrument Serif Project Authors, https://github.com/Instrument/instrument-serif"),
        ("Google Mobile Ads and User Messaging Platform SDKs", "Google terms. https://developers.google.com/admob")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FX.Space.l) {
                FXHeader(title: "Open-source licences", subtitle: nil)
                Text("Fluxa uses the FFmpeg libraries to read and write formats that Apple's frameworks don't cover. FFmpeg is licensed under the GNU Lesser General Public License (LGPL) version 2.1 or later. Fluxa links the libraries dynamically, so you may replace them with your own build of the same version.")
                    .font(FX.Font.body).foregroundStyle(FX.Palette.paper)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Fluxa's FFmpeg build contains no GPL code and no x264, x265 or fdk-aac. The exact source and build scripts are public at github.com/EcomswiftLLC/ffmpeg-ios-lgpl, and the upstream source is at ffmpeg.org. For a copy of the source on request, write to support@ecomswiftllc.com; this offer is valid for three years from the date of this version.")
                    .font(FX.Font.callout).foregroundStyle(FX.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    FXHairline()
                    ForEach(libraries, id: \.0) { lib in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lib.0).font(FX.Font.headline).foregroundStyle(FX.Palette.paper)
                            Text(lib.1).font(FX.Font.caption).foregroundStyle(FX.Palette.mist).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        FXHairline()
                    }
                }
                Text("FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. Fluxa is not endorsed by the FFmpeg project.")
                    .font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, FX.Space.m)
            .padding(.bottom, FX.Space.xl)
            .readableWidth()
        }
        .apScreen()
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }
}
