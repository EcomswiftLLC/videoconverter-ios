import SwiftUI

// MARK: - Small controls

/// A row of chips for one option, with a label above.
struct OptionChips<T: Hashable>: View {
    let title: String
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        VStack(alignment: .leading, spacing: FX.Space.s) {
            Text(title).font(FX.Font.label).foregroundStyle(FX.Palette.mist)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FX.Space.s) {
                    ForEach(options.indices, id: \.self) { index in
                        FXChip(title: options[index].1, selected: selection == options[index].0) {
                            selection = options[index].0
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}

struct FormatTile: View {
    let format: OutputFormat
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(format.displayName)
                    .font(FX.Font.tile)
                    .foregroundStyle(selected ? FX.Palette.onGlow : FX.Palette.paper)
                Text(format.summary)
                    .font(FX.Font.caption)
                    .foregroundStyle(selected ? FX.Palette.onGlow.opacity(0.78) : FX.Palette.mist)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous)
                if selected {
                    shape.fill(LinearGradient(colors: [FX.Palette.glow, FX.Palette.glowDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    shape.fill(FX.Palette.carbon)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous).strokeBorder(selected ? Color.clear : FX.Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(format.displayName). \(format.summary)"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("format-\(format.rawValue)")
    }
}

struct FileRowView: View {
    @ObservedObject var item: ConversionItem
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: FX.Space.m) {
            thumb
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(FX.Font.headline).foregroundStyle(FX.Palette.paper)
                    .lineLimit(1).truncationMode(.middle)
                Text(meta)
                    .font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
                statusLine
            }
            Spacer(minLength: 0)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FX.Palette.mist)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove \(item.displayName)"))
            }
        }
        .padding(FX.Space.m)
        .background(FX.Palette.carbon, in: RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous).strokeBorder(FX.Palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var thumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FX.Palette.graphite)
            if let image = item.thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.probe?.isAudioOnly == true ? "waveform" : "film")
                    .font(.system(size: 20)).foregroundStyle(FX.Palette.mist)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private var meta: String {
        guard let probe = item.probe else {
            if case .failed = item.state { return "" }
            return "Reading file…"
        }
        var parts: [String] = []
        let ext = (item.displayName as NSString).pathExtension.uppercased()
        if !ext.isEmpty { parts.append(ext) }
        if let v = probe.video {
            let size = v.displaySize
            if size.width > 0 { parts.append("\(size.width)×\(size.height)") }
            if let codec = v.codec { parts.append(codec.displayName) } else { parts.append(v.codecName.uppercased()) }
        } else if let a = probe.primaryAudio {
            parts.append((a.codec?.displayName ?? a.codecName.uppercased()))
        }
        if probe.duration > 0 { parts.append(Fmt.duration(probe.duration)) }
        if probe.fileSize > 0 { parts.append(Fmt.bytes(probe.fileSize)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusLine: some View {
        if case .failed(let error) = item.state {
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(FX.Font.label).foregroundStyle(FX.Palette.danger)
                Text(error.message).font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let error = item.planError {
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(FX.Font.label).foregroundStyle(FX.Palette.danger)
                Text(error.message).font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let plan = item.plan {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: plan.kind == .remux ? "bolt.fill" : "gearshape.2")
                        .font(.system(size: 11, weight: .semibold))
                    Text(plan.badge).font(FX.Font.label)
                }
                .foregroundStyle(FX.Palette.glow)
                if item.probe?.nativeReadable == false && item.probe?.isAudioOnly == false {
                    Text("This file won't play in Photos or Files on \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone").")
                        .font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                }
                ForEach(plan.notes, id: \.self) { note in
                    Text(note).font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if item.state == .probing {
            ProgressView().controlSize(.small).tint(FX.Palette.mist)
        }
    }
}

// MARK: - Setup screen

struct SetupView: View {
    @EnvironmentObject private var queue: ConversionQueue
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.dismiss) private var dismiss
    var onOpenGuide: () -> Void = {}
    /// Debug screenshots only: starts with the advanced options open.
    var startAdvancedOpen = false
    /// Debug screenshots only: scrolls this section to the top once the screen is up.
    var debugScrollTo: String? = nil

    @State private var category: FormatCategory = .video
    @State private var advancedOpen = false
    @State private var startedOnce = false
    @State private var converting = false
    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 900
            ScrollViewReader { proxy in
            Group {
                if wide {
                    HStack(alignment: .top, spacing: FX.Space.l) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: FX.Space.l) {
                                filesSection
                                summaryCard
                                convertButton
                            }
                            .padding(FX.Space.m)
                        }
                        .frame(width: 380)
                        ScrollView {
                            optionsColumn.padding(FX.Space.m)
                        }
                    }
                    .padding(.horizontal, FX.Space.m)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: FX.Space.xl) {
                            filesSection
                            optionsColumn
                        }
                        .padding(.horizontal, FX.Space.m)
                        .padding(.vertical, FX.Space.m)
                        .readableWidth(720)
                    }
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: FX.Space.s) {
                            summaryLine
                            convertButton
                        }
                        .padding(.horizontal, FX.Space.m)
                        .padding(.top, FX.Space.s)
                        .padding(.bottom, FX.Space.s)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                        .overlay(alignment: .top) { FXHairline() }
                    }
                }
            }
            .onAppear {
                if let target = debugScrollTo {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                    }
                }
            }
            }
        }
        .apScreen()
        .navigationTitle("Convert")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $converting) {
            ConvertView(onDone: { converting = false; dismiss() })
        }
        .onChange(of: queue.spec) { _, _ in queue.refreshPlans() }
        .onChange(of: queue.items.count) { _, count in
            if count == 0 && !converting { dismiss() }
        }
        .onAppear {
            category = queue.spec.format.category
            if startAdvancedOpen { advancedOpen = true }
        }
        .onChange(of: converting) { _, isOn in
            // Coming back from the result screen: show the setup again with fresh results.
            if !isOn { queue.resetResults() }
        }
    }

    // MARK: Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: FX.Space.s) {
            FXSectionTitle(text: queue.items.count == 1 ? "Your file" : "Your files (\(queue.items.count))")
            ForEach(queue.items) { item in
                FileRowView(item: item) { queue.remove(item) }
            }
            if queue.items.isEmpty {
                Text("No files yet. Go back and choose some.").font(FX.Font.callout).foregroundStyle(FX.Palette.mist)
            }
        }
    }

    // MARK: Options

    private var optionsColumn: some View {
        VStack(alignment: .leading, spacing: FX.Space.xl) {
            formatSection.id("formats")
            presetsSection.id("presets")
            qualitySection.id("quality")
            advancedSection.id("advanced")
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: FX.Space.m) {
            HStack {
                FXSectionTitle(text: "Convert to")
                Spacer()
                Button("Formats guide", action: onOpenGuide)
                    .font(FX.Font.label).foregroundStyle(FX.Palette.glow).frame(minHeight: 44)
            }
            HStack(spacing: FX.Space.s) {
                ForEach(FormatCategory.allCases, id: \.self) { cat in
                    FXChip(title: cat.title, selected: category == cat) {
                        category = cat
                        if queue.spec.format.category != cat, let first = OutputFormat.formats(in: cat).first {
                            select(first)
                        }
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: FX.Space.s)], spacing: FX.Space.s) {
                ForEach(OutputFormat.formats(in: category)) { format in
                    FormatTile(format: format, selected: queue.spec.format == format) { select(format) }
                }
            }
        }
    }

    private func select(_ format: OutputFormat) {
        var spec = queue.spec
        spec.format = format
        spec.videoCodec = nil
        spec.audioCodec = nil
        spec.audioBitrateKbps = nil
        queue.spec = spec
        category = format.category
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: FX.Space.s) {
            FXSectionTitle(text: "Quick presets")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FX.Space.s) {
                    ForEach(ConversionPreset.all) { preset in
                        let active = presetActive(preset)
                        Button {
                            var spec = preset.spec
                            spec.trim = queue.spec.trim
                            queue.spec = spec
                            category = spec.format.category
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Image(systemName: preset.symbol)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(active ? FX.Palette.onGlow : FX.Palette.glow)
                                Text(preset.title).font(FX.Font.label).foregroundStyle(active ? FX.Palette.onGlow : FX.Palette.paper)
                                Text(preset.subtitle).font(FX.Font.caption)
                                    .foregroundStyle(active ? FX.Palette.onGlow.opacity(0.8) : FX.Palette.mist)
                                    .lineLimit(2, reservesSpace: true)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(12)
                            .frame(width: 168, alignment: .leading)
                            .background {
                                let shape = RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous)
                                if active {
                                    shape.fill(LinearGradient(colors: [FX.Palette.glow, FX.Palette.glowDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                                } else {
                                    shape.fill(FX.Palette.carbon)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous).strokeBorder(active ? Color.clear : FX.Palette.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(preset.title). \(preset.subtitle)"))
                        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
    }

    private func presetActive(_ preset: ConversionPreset) -> Bool {
        var spec = queue.spec
        spec.trim = nil
        var other = preset.spec
        other.trim = nil
        return spec == other
    }

    // MARK: Quality

    @ViewBuilder
    private var qualitySection: some View {
        let spec = queue.spec
        VStack(alignment: .leading, spacing: FX.Space.l) {
            FXSectionTitle(text: spec.format.category == .image ? "Animation" : "Quality")
            switch spec.format.category {
            case .video:
                OptionChips(title: "Size", options: Resolution.standardChoices.map { ($0, $0.title) }, selection: $queue.spec.resolution)
                OptionChips(title: "Quality", options: QualityLevel.allCases.map { ($0, $0.title) }, selection: $queue.spec.quality)
                codecMenus
            case .audio:
                codecMenus
                audioBitrateChips
                OptionChips(title: "Sample rate", options: [(nil as Int?, "Original"), (44100, "44.1 kHz"), (48000, "48 kHz")], selection: $queue.spec.audioSampleRate)
            case .image:
                imageOptions
            }
        }
    }

    @ViewBuilder
    private var codecMenus: some View {
        let spec = queue.spec
        VStack(alignment: .leading, spacing: FX.Space.s) {
            if spec.format.category == .video && spec.format.videoCodecs.count > 1 {
                menuRow(title: "Video codec", current: spec.resolvedVideoCodec?.displayName ?? "Auto") {
                    Button("Auto (recommended)") { queue.spec.videoCodec = nil }
                    ForEach(spec.format.videoCodecs, id: \.self) { codec in
                        Button(codec.displayName) { queue.spec.videoCodec = codec }
                    }
                }
            }
            if spec.format.audioCodecs.count > 1 {
                menuRow(title: "Audio codec", current: spec.resolvedAudioCodec?.displayName ?? "Auto") {
                    Button("Auto (recommended)") { queue.spec.audioCodec = nil }
                    ForEach(spec.format.audioCodecs, id: \.self) { codec in
                        Button(codec.displayName) { queue.spec.audioCodec = codec }
                    }
                }
            }
        }
    }

    private func menuRow<Content: View>(title: String, current: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(FX.Font.body).foregroundStyle(FX.Palette.paper)
            Spacer()
            Menu {
                content()
            } label: {
                HStack(spacing: 6) {
                    Text(current).font(FX.Font.callout)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(FX.Palette.glow)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("\(title), \(current)"))
        }
        .padding(.horizontal, FX.Space.m)
        .frame(minHeight: 52)
        .background(FX.Palette.carbon, in: RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous).strokeBorder(FX.Palette.line, lineWidth: 1))
    }

    @ViewBuilder
    private var audioBitrateChips: some View {
        if let codec = queue.spec.resolvedAudioCodec, !codec.bitrateChoices.isEmpty {
            OptionChips(
                title: "Audio quality",
                options: [(nil as Int?, "Auto")] + codec.bitrateChoices.map { ($0 as Int?, "\($0) kbps") },
                selection: $queue.spec.audioBitrateKbps
            )
        }
    }

    @ViewBuilder
    private var imageOptions: some View {
        OptionChips(title: "Width", options: [240, 320, 480, 640, 800].map { ($0, "\($0) px") }, selection: $queue.spec.gif.maxWidth)
        OptionChips(title: "Frames per second", options: [8, 12, 15, 24].map { (Double($0), "\($0) fps") }, selection: $queue.spec.gif.fps)
        if queue.spec.format == .gif {
            OptionChips(title: "Colours", options: [64, 128, 256].map { ($0, "\($0)") }, selection: $queue.spec.gif.maxColors)
            Toggle("Smooth gradients (dither)", isOn: $queue.spec.gif.dither).toggleStyle(FXToggleStyle())
        }
        Toggle("Loop forever", isOn: $queue.spec.gif.loops).toggleStyle(FXToggleStyle())
        if !queue.ffmpegAvailable && queue.spec.format == .gif {
            Text("Colour and smoothing choices apply when the extended engine is available.").font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: FX.Space.m) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { advancedOpen.toggle() }
            } label: {
                HStack {
                    FXSectionTitle(text: "Advanced")
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .rotationEffect(.degrees(advancedOpen ? 180 : 0))
                        .foregroundStyle(FX.Palette.mist)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Advanced options"))
            .accessibilityValue(Text(advancedOpen ? "Expanded" : "Collapsed"))
            .accessibilityIdentifier("advancedToggle")

            if advancedOpen {
                VStack(alignment: .leading, spacing: FX.Space.l) {
                    if queue.spec.format.category == .video {
                        OptionChips(title: "Frame rate", options: [(nil as Double?, "Original"), (60, "60"), (30, "30"), (24, "24"), (15, "15")], selection: $queue.spec.fps)
                        audioBitrateChips
                        HStack {
                            Text("Rotate").font(FX.Font.body).foregroundStyle(FX.Palette.paper)
                            Spacer()
                            Button {
                                queue.spec.rotation = queue.spec.rotation.next()
                            } label: {
                                Label(queue.spec.rotation.title, systemImage: "rotate.right")
                                    .font(FX.Font.callout).foregroundStyle(FX.Palette.glow).frame(minHeight: 44)
                            }
                            .accessibilityLabel(Text("Rotate, \(queue.spec.rotation.title). Tap to change."))
                        }
                        Toggle("Flip horizontally", isOn: $queue.spec.flipHorizontal).toggleStyle(FXToggleStyle())
                        Toggle("Remove sound", isOn: $queue.spec.mute).toggleStyle(FXToggleStyle())
                    }
                    Toggle("Remove location and camera details", isOn: $queue.spec.stripMetadata).toggleStyle(FXToggleStyle())
                    trimControls
                }
                .padding(.bottom, FX.Space.s)
            }
        }
    }

    @ViewBuilder
    private var trimControls: some View {
        if queue.items.count == 1, let probe = queue.items.first?.probe, probe.duration > 1 {
            let duration = probe.duration
            let lower = queue.spec.trim?.lowerBound ?? 0
            let upper = queue.spec.trim?.upperBound ?? duration
            VStack(alignment: .leading, spacing: FX.Space.s) {
                HStack {
                    Text("Trim").font(FX.Font.body).foregroundStyle(FX.Palette.paper)
                    Spacer()
                    Text("\(Fmt.duration(lower)) – \(Fmt.duration(upper))").font(FX.Font.number).foregroundStyle(FX.Palette.glow)
                    if queue.spec.trim != nil {
                        Button("Reset") { queue.spec.trim = nil }.font(FX.Font.label).foregroundStyle(FX.Palette.glow).frame(minHeight: 44)
                    }
                }
                trimSlider(title: "Start", value: lower, range: 0...max(duration - 0.5, 0.5)) { newValue in
                    queue.spec.trim = newValue...max(newValue + 0.5, min(upper, duration))
                }
                trimSlider(title: "End", value: upper, range: 0.5...duration) { newValue in
                    queue.spec.trim = min(lower, max(newValue - 0.5, 0))...newValue
                }
            }
        }
    }

    private func trimSlider(title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: FX.Space.m) {
            Text(title).font(FX.Font.caption).foregroundStyle(FX.Palette.mist).frame(width: 40, alignment: .leading)
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: set), in: range)
                .tint(FX.Palette.glow)
                .accessibilityLabel(Text("Trim \(title.lowercased())"))
                .accessibilityValue(Text(Fmt.duration(value)))
        }
    }

    // MARK: Summary and button

    private var summaryLine: some View {
        let count = queue.convertibleItems.count
        let bytes = queue.estimatedTotalBytes()
        return Group {
            if count > 0 && bytes > 0 {
                Text("Estimated result: about \(Fmt.bytes(bytes))")
            } else if queue.anyProbing {
                Text("Reading your files…")
            } else {
                Text(" ")
            }
        }
        .font(FX.Font.caption)
        .foregroundStyle(FX.Palette.mist)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Result").font(FX.Font.label).foregroundStyle(FX.Palette.mist)
            Text(queue.spec.format.displayName).font(FX.Font.title(30)).foregroundStyle(FX.Palette.paper)
            summaryLine
        }
        .padding(FX.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FX.Palette.carbon, in: RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous).strokeBorder(FX.Palette.line, lineWidth: 1))
    }

    private var convertButton: some View {
        let count = queue.convertibleItems.count
        return Button {
            queue.start()
            converting = true
        } label: {
            Text(count > 1 ? "Convert \(count) files to \(queue.spec.format.displayName)" : "Convert to \(queue.spec.format.displayName)")
        }
        .buttonStyle(.apPrimaryWide)
        .disabled(count == 0)
        .accessibilityIdentifier("convertButton")
    }
}

/// A switch row in the app's own style: label on the left, system switch on the right, at least 52 pt tall.
struct FXToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label.font(FX.Font.body).foregroundStyle(FX.Palette.paper)
            Spacer()
            Toggle("", isOn: configuration.$isOn).labelsHidden().tint(FX.Palette.glow)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(configuration.isOn ? "On" : "Off"))
    }
}
