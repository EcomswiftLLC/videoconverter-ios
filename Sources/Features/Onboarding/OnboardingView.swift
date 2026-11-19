import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FX.Space.xl) {
                Spacer(minLength: FX.Space.l)
                FluxaMark(lineWidth: 3.4).frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: FX.Space.s) {
                    Text("Fluxa").font(FX.Font.title(20)).foregroundStyle(FX.Palette.glow)
                    Text("Every video and audio format, one tap.").apDisplay(hSize == .regular ? 52 : 40)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(alignment: .leading, spacing: FX.Space.l) {
                    point("film.stack", "Open nearly anything", "MKV, AVI, WebM, MOV, FLV, WMV, MPG and more, plus MP3, FLAC, WAV and other audio.")
                    point("bolt.fill", "Fast and lossless when it can be", "Files that already fit are re-wrapped in seconds, with no quality loss.")
                    point("lock.shield", "Private by design", "Everything is converted on your device. Nothing is uploaded.")
                    point("heart", "Free, supported by ads", "You watch one short ad when you save or share a result. If no ad is ready, it's free.")
                }
                Button("Get started") {
                    withAnimation { appState.hasOnboarded = true }
                }
                .buttonStyle(.apPrimaryWide)
                .accessibilityIdentifier("getStarted")
                .padding(.top, FX.Space.s)
            }
            .padding(.horizontal, FX.Space.l)
            .padding(.bottom, FX.Space.xl)
            .frame(minHeight: 600, alignment: .topLeading)
            .readableWidth(560)
        }
        .apScreen()
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: FX.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(FX.Palette.glow)
                .frame(width: 36, height: 36)
                .background(FX.Palette.graphite, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(FX.Font.headline).foregroundStyle(FX.Palette.paper)
                Text(text).font(FX.Font.callout).foregroundStyle(FX.Palette.mist).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
