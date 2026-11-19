import SwiftUI

/// What Fluxa can open, what it can create, and what it can't do. Written to be honest and scannable.
struct FormatsGuideView: View {
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FX.Space.xl) {
                FXHeader(title: "Formats guide", subtitle: "Everything Fluxa opens and creates, and which one to pick.")

                section("Opens these files") {
                    ForEach(InputFormats.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(group.title).font(FX.Font.headline).foregroundStyle(FX.Palette.paper)
                                Spacer()
                                Text(group.engine).font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                            }
                            FlowLayout(spacing: 6) {
                                ForEach(group.extensions, id: \.self) { ext in
                                    Text(ext.uppercased())
                                        .font(FX.Font.caption.weight(.medium))
                                        .foregroundStyle(FX.Palette.paper)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(FX.Palette.graphite, in: Capsule())
                                }
                            }
                        }
                        .padding(FX.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(FX.Palette.carbon, in: RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous).strokeBorder(FX.Palette.line, lineWidth: 1))
                        .accessibilityElement(children: .combine)
                    }
                }

                ForEach(FormatCategory.allCases, id: \.self) { category in
                    section("Creates \(category.title.lowercased()) files") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: FX.Space.s)], spacing: FX.Space.s) {
                            ForEach(OutputFormat.formats(in: category)) { format in
                                formatCard(format)
                            }
                        }
                    }
                }

                section("Which should I pick?") {
                    VStack(alignment: .leading, spacing: FX.Space.m) {
                        tip("Not sure", "MP4 with H.264. It plays on every phone, TV, browser and editor.")
                        tip("Smallest size", "MP4 with HEVC, or WebM with VP9. Both need a fairly recent device to play.")
                        tip("Fastest", "If a file already holds H.264 and AAC, Fluxa only re-wraps it. That takes seconds and loses no quality.")
                        tip("Editing", "MOV with ProRes. Files are large, but editors love them.")
                        tip("Old gadgets", "AVI, WMV, MPG or 3GP, with a lower size such as 480p.")
                        tip("Sound only", "MP3 plays everywhere. M4A is smaller at the same quality. FLAC and WAV keep everything.")
                    }
                }

                section("What Fluxa can't do") {
                    VStack(alignment: .leading, spacing: FX.Space.m) {
                        tip("Protected files", "Movies and shows with copy protection (DRM), such as Apple TV or Netflix downloads, can't be converted by any app. Files you recorded or own work fine.")
                        tip("Locked files", "Files that need a password can't be opened.")
                        tip("Subtitles", "Subtitle tracks are not copied in this version. Only the first audio track is kept.")
                        tip("Very old or rare codecs", "A few unusual codecs may not open. Fluxa tells you clearly when that happens.")
                        tip("HEVC and ProRes speed", "Hardware encoding depends on your device. Older iPhones are slower and may get warm on long videos.")
                    }
                }
            }
            .padding(.horizontal, FX.Space.m)
            .padding(.vertical, FX.Space.m)
            .readableWidth(hSize == .regular ? 900 : 700)
        }
        .apScreen()
        .navigationTitle("Formats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FX.Space.m) {
            FXSectionTitle(text: title)
            content()
        }
    }

    private func formatCard(_ format: OutputFormat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(format.displayName).font(FX.Font.tile).foregroundStyle(FX.Palette.paper)
                Text(".\(format.fileExtension)").font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                Spacer()
            }
            Text(format.summary).font(FX.Font.callout).foregroundStyle(FX.Palette.paper.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            let video = format.videoCodecs.map { $0.displayName }.joined(separator: ", ")
            let audio = format.audioCodecs.map { $0.displayName }.joined(separator: ", ")
            if !video.isEmpty { Text("Video: \(video)").font(FX.Font.caption).foregroundStyle(FX.Palette.mist).fixedSize(horizontal: false, vertical: true) }
            if !audio.isEmpty { Text("Audio: \(audio)").font(FX.Font.caption).foregroundStyle(FX.Palette.mist).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(FX.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FX.Palette.carbon, in: RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous).strokeBorder(FX.Palette.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func tip(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(FX.Font.headline).foregroundStyle(FX.Palette.paper)
            Text(text).font(FX.Font.callout).foregroundStyle(FX.Palette.mist).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
