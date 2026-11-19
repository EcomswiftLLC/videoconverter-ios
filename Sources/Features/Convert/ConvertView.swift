import SwiftUI
import AVKit

private struct PreviewTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// Progress while converting, then the finished files with Save and Share. Saving and sharing are paid for by one rewarded ad
/// (free when no ad is ready); one ad covers every file of the batch.
struct ConvertView: View {
    @EnvironmentObject private var queue: ConversionQueue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void

    @State private var toast: String?
    @State private var preview: PreviewTarget?
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FX.Space.l) {
                FXHeader(title: headerTitle, subtitle: headerSubtitle)
                ForEach(queue.items) { item in
                    ResultCard(item: item,
                               onCancel: { queue.cancel(item) },
                               onPreview: { url in preview = PreviewTarget(url: url) },
                               gated: gated, toast: show)
                }
                if queue.hasFinished && queue.doneItems.count > 0 { batchActions }
                if queue.isRunning {
                    Text("Keep Fluxa open while it converts. Long videos can take a few minutes.")
                        .font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if queue.hasFinished { footerButtons }
            }
            .padding(.horizontal, FX.Space.m)
            .padding(.vertical, FX.Space.m)
            .readableWidth(760)
        }
        .apScreen()
        .navigationBarBackButtonHidden(queue.isRunning)
        .navigationTitle(queue.hasFinished ? "Done" : "Converting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if queue.isRunning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel all") { queue.cancelAll() }
                        .foregroundStyle(FX.Palette.danger)
                        .accessibilityIdentifier("cancelAll")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(FX.Font.label).foregroundStyle(FX.Palette.paper)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(FX.Palette.graphite, in: Capsule())
                    .overlay(Capsule().strokeBorder(FX.Palette.line, lineWidth: 1))
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .fullScreenCover(item: $preview) { target in
            PreviewPlayer(url: target.url) { preview = nil }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && queue.isRunning { beginBackgroundTask() }
            if phase == .active { endBackgroundTask() }
        }
        .onChange(of: queue.isRunning) { _, running in
            if !running && queue.hasFinished { FXHaptics.success() }
        }
    }

    // MARK: Header

    private var headerTitle: String {
        if queue.isRunning { return "Converting…" }
        if queue.hasFinished {
            let done = queue.doneItems.count
            if done == 0 { return "Nothing was converted" }
            return done == 1 ? "Your file is ready" : "\(done) files are ready"
        }
        return "Getting ready…"
    }

    private var headerSubtitle: String? {
        if queue.hasFinished && queue.doneItems.count > 0 {
            let saved = savedBytes
            if saved > 0 { return "You saved \(Fmt.bytes(saved)) compared with the originals." }
            return "Save or share your converted files below."
        }
        return nil
    }

    private var savedBytes: Int64 {
        queue.doneItems.reduce(0) { total, item in
            guard let probe = item.probe else { return total }
            return total + max(0, probe.fileSize - item.resultBytes)
        }
    }

    // MARK: Batch actions

    private var batchActions: some View {
        let urls = queue.doneItems.compactMap { $0.resultURL }
        let photoItems = queue.doneItems.compactMap { item -> (URL, OutputFormat)? in
            guard let url = item.resultURL else { return nil }
            return (url, queue.spec.format)
        }
        return VStack(alignment: .leading, spacing: FX.Space.s) {
            if queue.doneItems.count > 1 {
                FXSectionTitle(text: "All files")
            }
            VStack(spacing: FX.Space.s) {
                Button {
                    gated {
                        Exporting.share(urls: urls) { _ in RewardedGate.shared.exportEnded() }
                    }
                } label: {
                    Label(queue.doneItems.count > 1 ? "Share all" : "Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.apPrimaryWide)
                .accessibilityIdentifier("shareAll")

                HStack(spacing: FX.Space.s) {
                    Button {
                        gated {
                            Exporting.saveToFiles(urls: urls) { saved in
                                RewardedGate.shared.exportEnded()
                                if saved { show("Saved to Files") }
                            }
                        }
                    } label: {
                        Label("Save to Files", systemImage: "folder")
                    }
                    .buttonStyle(.apSecondaryWide)
                    .accessibilityIdentifier("saveFiles")

                    if Exporting.canSaveToPhotos(queue.spec.format) {
                        Button {
                            gated {
                                Task {
                                    let result = await Exporting.saveToPhotos(items: photoItems)
                                    RewardedGate.shared.exportEnded()
                                    switch result {
                                    case .success(let n): show(n == 1 ? "Saved to Photos" : "Saved \(n) files to Photos")
                                    case .failure(let error): show(error.localizedDescription)
                                    }
                                }
                            }
                        } label: {
                            Label("Save to Photos", systemImage: "photo")
                        }
                        .buttonStyle(.apSecondaryWide)
                        .accessibilityIdentifier("savePhotos")
                    }
                }
                Text("Saving or sharing is paid for by one short ad. If no ad is ready, it's free.")
                    .font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footerButtons: some View {
        VStack(spacing: FX.Space.s) {
            Button {
                dismiss()
            } label: {
                Label("Convert to another format", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.apSecondaryWide)
            .accessibilityIdentifier("another")
            Button("Done") {
                queue.removeAll()
                onDone()
            }
            .buttonStyle(.apQuiet)
            .accessibilityIdentifier("done")
        }
        .padding(.top, FX.Space.s)
    }

    // MARK: Helpers

    private func gated(_ action: @escaping () -> Void) {
        RewardedGate.shared.requestExport(action)
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { if toast == text { toast = nil } }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FluxaConvert") {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - One file's card

private struct ResultCard: View {
    @ObservedObject var item: ConversionItem
    var onCancel: () -> Void
    var onPreview: (URL) -> Void
    var gated: (@escaping () -> Void) -> Void
    var toast: (String) -> Void
    @EnvironmentObject private var queue: ConversionQueue

    var body: some View {
        VStack(alignment: .leading, spacing: FX.Space.m) {
            HStack(alignment: .top, spacing: FX.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FX.Palette.graphite)
                    if let image = item.thumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: queue.spec.format.category == .audio ? "waveform" : "film")
                            .font(.system(size: 20)).foregroundStyle(FX.Palette.mist)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(FX.Font.headline).foregroundStyle(FX.Palette.paper)
                        .lineLimit(1).truncationMode(.middle)
                    detail
                }
                Spacer(minLength: 0)
            }
            body2
        }
        .padding(FX.Space.m)
        .background(FX.Palette.carbon, in: RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FX.Radius.control, style: .continuous).strokeBorder(FX.Palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if let url = item.resultURL { return url.lastPathComponent }
        return item.displayName
    }

    @ViewBuilder
    private var detail: some View {
        switch item.state {
        case .waiting:
            Text("Waiting").font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
        case .running:
            Text(runningText).font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
        case .done:
            VStack(alignment: .leading, spacing: 2) {
                Text(summaryText).font(FX.Font.caption).foregroundStyle(FX.Palette.paper)
                Text(sizeText).font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                if let plan = item.plan {
                    Label(plan.badge, systemImage: plan.kind == .remux ? "bolt.fill" : "checkmark.seal")
                        .font(FX.Font.label).foregroundStyle(FX.Palette.glow)
                        .labelStyle(.titleAndIcon)
                }
            }
        case .failed(let error):
            Text(error.title).font(FX.Font.label).foregroundStyle(FX.Palette.danger)
        case .cancelled:
            Text("Cancelled").font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var body2: some View {
        switch item.state {
        case .waiting, .running:
            VStack(alignment: .leading, spacing: FX.Space.s) {
                ProgressView(value: item.progress)
                    .tint(FX.Palette.glow)
                    .accessibilityLabel(Text("Progress"))
                    .accessibilityValue(Text("\(Int(item.progress * 100)) percent"))
                Button("Cancel", action: onCancel)
                    .font(FX.Font.label).foregroundStyle(FX.Palette.danger)
                    .frame(minHeight: 44)
            }
        case .failed(let error):
            Text(error.message).font(FX.Font.caption).foregroundStyle(FX.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
        case .done:
            if let url = item.resultURL, Exporting.canPreview(queue.spec.format) {
                Button { onPreview(url) } label: { Label("Preview", systemImage: "play.circle") }
                    .font(FX.Font.label).foregroundStyle(FX.Palette.glow).frame(minHeight: 44)
            }
        default:
            EmptyView()
        }
    }

    private var runningText: String {
        let percent = Int((item.progress * 100).rounded())
        if let speed = item.speed, speed > 0.05, let probe = item.probe {
            let total = max(BitrateEstimator.effectiveDuration(probe: probe, spec: queue.spec), 1)
            let remaining = max(0, (1 - item.progress) * total / speed)
            return "\(percent)% · about \(Fmt.duration(remaining)) left"
        }
        return "\(percent)%"
    }

    /// What the person gets, shown before any save or share (and so before the rewarded ad): format, length and size.
    private var summaryText: String {
        var parts = [queue.spec.format.displayName]
        if let probe = item.probe {
            let seconds = BitrateEstimator.effectiveDuration(probe: probe, spec: queue.spec)
            if seconds > 0 { parts.append(Fmt.duration(seconds)) }
        }
        parts.append(Fmt.bytes(item.resultBytes))
        return parts.joined(separator: " · ")
    }

    private var sizeText: String {
        guard let probe = item.probe, probe.fileSize > 0 else { return Fmt.bytes(item.resultBytes) }
        let delta = Int((1 - Double(item.resultBytes) / Double(probe.fileSize)) * 100)
        let change = delta > 0 ? "\(delta)% smaller" : (delta < 0 ? "\(-delta)% larger" : "same size")
        return "\(Fmt.bytes(probe.fileSize)) to \(Fmt.bytes(item.resultBytes)) (\(change))"
    }
}

// MARK: - Preview player

private struct PreviewPlayer: View {
    let url: URL
    var onClose: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FX.Palette.paper)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
            .accessibilityLabel(Text("Close preview"))
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}
