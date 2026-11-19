import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum Route: Hashable {
    case setup
    case convert
    case guide
}

struct HomeView: View {
    @StateObject private var queue = ConversionQueue()
    @State private var path: [Route] = []
    @State private var filesShown = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var settingsShown = false
    @State private var dropTargeted = false
    @State private var errorMessage: String?
    @StateObject private var bannerSlot = BannerAdSlot()
    @Environment(\.horizontalSizeClass) private var hSize

    /// What a "popular conversion" tile asked for, applied once files are picked.
    @State private var pendingFormat: OutputFormat?

    private let popular: [(title: String, from: String, to: OutputFormat, symbol: String)] = [
        ("MKV to MP4", "Fast, no quality loss", .mp4, "arrow.triangle.2.circlepath"),
        ("Video to MP3", "Extract the audio", .mp3, "waveform"),
        ("Video to GIF", "Looping, shareable", .gif, "photo.on.rectangle.angled"),
        ("MOV to MP4", "Works everywhere", .mp4, "play.rectangle"),
        ("WebM to MP4", "Plays on iPhone and iPad", .mp4, "globe"),
        ("Any to AVI", "For Windows PCs", .avi, "pc")
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: FX.Space.xl) {
                    header
                    hero
                    popularSection
                    samplesSection
                    formatStrip
                    CKInlineBanner(slot: bannerSlot)
                }
                .padding(.horizontal, FX.Space.m)
                .padding(.top, FX.Space.s)
                .padding(.bottom, FX.Space.xl)
                .readableWidth(hSize == .regular ? 820 : 680)
            }
            .apScreen()
            .navigationBarHidden(true)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .setup: SetupView(onOpenGuide: { path.append(.guide) })
                case .convert: ConvertView(onDone: { queue.removeAll(); path.removeAll() })
                case .guide: FormatsGuideView()
                }
            }
        }
        .environmentObject(queue)
        .fileImporter(isPresented: $filesShown, allowedContentTypes: InputFormats.contentTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .photosPicker(isPresented: $photoPickerShown, selection: $photoItems, maxSelectionCount: nil, matching: .videos)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let chosen = items
            photoItems = []
            Task {
                await Importing.load(chosen, into: queue)
                openSetupIfNeeded()
            }
        }
        .onDrop(of: [UTType.item], isTargeted: $dropTargeted) { providers in
            let ok = Importing.handleDrop(providers: providers, into: queue)
            if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openSetupIfNeeded() } }
            return ok
        }
        .sheet(isPresented: $settingsShown) { SettingsView() }
        .alert("Can't add that", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .onOpenURL { url in
            if url.isFileURL, let copy = try? Importing.copyIntoImports(url) {
                queue.addLocal(url: copy, displayName: copy.lastPathComponent)
                openSetupIfNeeded()
            }
        }
    }

    @State private var photoPickerShown = false

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: FX.Space.s) {
            FluxaMark(lineWidth: 2.4).frame(width: 34, height: 34)
            Text("Fluxa").font(FX.Font.title(26)).foregroundStyle(FX.Palette.paper)
            Spacer()
            FXIconButton(symbol: "gearshape", label: "Settings") { settingsShown = true }
        }
        .padding(.top, FX.Space.xs)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: FX.Space.l) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Convert any video or audio file.").apDisplay(hSize == .regular ? 44 : 36)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("MP4, MKV, AVI, MOV, WebM, GIF, MP3 and more. Free, fast, and it all happens on your device.")
                    .font(FX.Font.body).foregroundStyle(FX.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: FX.Space.s) {
                Button { filesShown = true } label: {
                    Label("Choose files", systemImage: "folder")
                }
                .buttonStyle(.apPrimaryWide)
                .accessibilityIdentifier("chooseFiles")
                Button { photoPickerShown = true } label: {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.apSecondaryWide)
                .accessibilityIdentifier("choosePhotos")
                if hSize == .regular {
                    Text("Or drop files here from Files, Photos or Safari")
                        .font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(FX.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: FX.Radius.panel + 6, style: .continuous)
            ZStack {
                shape.fill(FX.Palette.carbon)
                shape.fill(RadialGradient(colors: [FX.Palette.glow.opacity(0.14), .clear], center: .topTrailing, startRadius: 4, endRadius: 360))
                shape.fill(RadialGradient(colors: [FX.Palette.glowDeep.opacity(0.12), .clear], center: .bottomLeading, startRadius: 4, endRadius: 320))
                shape.strokeBorder(dropTargeted ? FX.Palette.glow : FX.Palette.line, lineWidth: dropTargeted ? 2 : 1)
            }
        }
    }

    private var popularSection: some View {
        VStack(alignment: .leading, spacing: FX.Space.m) {
            FXSectionTitle(text: "Popular conversions")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: FX.Space.s)], spacing: FX.Space.s) {
                ForEach(popular, id: \.title) { item in
                    Button {
                        pendingFormat = item.to
                        queue.spec.format = item.to
                        filesShown = true
                    } label: {
                        HStack(spacing: FX.Space.m) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(FX.Palette.glow)
                                .frame(width: 36, height: 36)
                                .background(FX.Palette.graphite, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(FX.Font.headline).foregroundStyle(FX.Palette.paper)
                                Text(item.from).font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(FX.Space.m)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .background(FX.Palette.carbon, in: RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous).strokeBorder(FX.Palette.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(item.title). \(item.from)"))
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    private var samplesSection: some View {
        VStack(alignment: .leading, spacing: FX.Space.s) {
            FXSectionTitle(text: "No file at hand?")
            Text("Try Fluxa with a sample clip.")
                .font(FX.Font.callout).foregroundStyle(FX.Palette.mist)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FX.Space.s) {
                    ForEach(SampleClip.all) { clip in
                        Button {
                            guard let url = clip.importCopy() else { errorMessage = "The sample clip could not be opened."; return }
                            queue.addLocal(url: url, displayName: url.lastPathComponent)
                            openSetupIfNeeded()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(clip.title).font(FX.Font.headline).foregroundStyle(FX.Palette.paper)
                                Text(clip.caption).font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                            }
                            .padding(.horizontal, FX.Space.m)
                            .frame(minWidth: 150, minHeight: 56, alignment: .leading)
                            .background(FX.Palette.carbon, in: RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous).strokeBorder(FX.Palette.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sample-\(clip.id)")
                    }
                }
            }
        }
    }

    private var formatStrip: some View {
        VStack(alignment: .leading, spacing: FX.Space.s) {
            HStack {
                FXSectionTitle(text: "Every format")
                Spacer()
                Button("See all") { path.append(.guide) }
                    .font(FX.Font.label).foregroundStyle(FX.Palette.glow)
                    .frame(minHeight: 44)
            }
            FlowLayout(spacing: 8) {
                ForEach(["MP4", "MOV", "MKV", "AVI", "WebM", "FLV", "WMV", "3GP", "MPG", "TS", "OGV", "GIF", "MP3", "M4A", "WAV", "FLAC", "OGG", "Opus"], id: \.self) { tag in
                    Text(tag)
                        .font(FX.Font.label)
                        .foregroundStyle(FX.Palette.paper)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(FX.Palette.graphite, in: Capsule())
                        .overlay(Capsule().strokeBorder(FX.Palette.line, lineWidth: 1))
                }
            }
            Text("Files protected by DRM, such as Apple TV or Netflix downloads, can't be converted.")
                .font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func addFiles(_ urls: [URL]) {
        queue.add(urls: urls, scoped: true)
        openSetupIfNeeded()
    }

    private func openSetupIfNeeded() {
        if let format = pendingFormat { queue.spec.format = format; pendingFormat = nil }
        queue.refreshPlans()
        if !queue.items.isEmpty && path.isEmpty { path.append(.setup) }
    }
}
