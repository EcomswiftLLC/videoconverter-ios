#if DEBUG
import SwiftUI

/// Opens a screen directly for CI screenshots: `-fxScreen <name>`, or `-fxScreen shot-<name>` for the store captures.
/// Debug builds only; none of this ships.
enum DebugScreens {
    static var requested: String? {
        guard let value = UserDefaults.standard.string(forKey: "fxScreen"), !value.isEmpty else { return nil }
        return value.hasPrefix("shot-") ? String(value.dropFirst(5)) : value
    }

    @ViewBuilder
    static func view(for name: String) -> some View {
        switch name {
        case "onboarding":
            OnboardingView().environmentObject(AppState())
        case "settings":
            SettingsView()
        case "formats-guide", "guide":
            NavigationStack { FormatsGuideView() }
        default:
            DebugHost(name: name)
        }
    }
}

/// Builds a real queue with the bundled sample clips, then shows the real screen on top of it.
private struct DebugHost: View {
    let name: String
    @StateObject private var queue = ConversionQueue()
    @State private var ready = false

    var body: some View {
        Group {
            if name == "home" || name == "home-filled" {
                HomeView()
            } else if ready {
                NavigationStack { screen }
                    .environmentObject(queue)
            } else {
                ZStack {
                    FX.Palette.lens.ignoresSafeArea()
                    ProgressView().tint(FX.Palette.glow)
                }
            }
        }
        .task { if name != "home" && name != "home-filled" { await prepare() } }
    }

    @ViewBuilder
    private var screen: some View {
        switch name {
        case "queue", "result":
            ConvertView(onDone: {})
        case "advanced":
            SetupView(startAdvancedOpen: true, debugScrollTo: "advanced")
        case "presets":
            SetupView(debugScrollTo: "presets")
        case "formats-grid":
            SetupView(debugScrollTo: "formats")
        default:
            SetupView()
        }
    }

    private func prepare() async {
        let full = queue.ffmpegAvailable
        let clips = full ? SampleClip.all : [SampleClip.all[0]]
        for clip in clips {
            if let url = clip.importCopy() { queue.addLocal(url: url, displayName: url.lastPathComponent) }
        }
        // Wait for the files to be read.
        var waited = 0.0
        while queue.anyProbing && waited < 20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 0.25
        }

        var spec = OutputSpec()
        switch name {
        case "audio-extract": spec = OutputSpec(format: full ? .mp3 : .m4a, audioBitrateKbps: 192)
        case "gif-maker": spec = OutputSpec(format: .gif)
        case "presets": spec = ConversionPreset.all[0].spec
        case "advanced": spec = OutputSpec(format: .mp4, videoCodec: .hevc, audioCodec: .aac, resolution: .hd720, quality: .high)
        case "queue", "result": spec = OutputSpec(format: .mp4, videoCodec: full ? .h264 : .hevc, audioCodec: .aac, quality: .high)
        default: spec = OutputSpec(format: .mp4, videoCodec: .h264, audioCodec: .aac, quality: .high)
        }
        queue.spec = spec
        queue.refreshPlans()

        if name == "queue" {
            let items = queue.items
            for (index, item) in items.enumerated() {
                switch index {
                case 0: item.state = .running; item.progress = 0.62; item.speed = 3.4
                case 1: item.state = .waiting
                default: item.state = .waiting
                }
            }
            queue.debugSetRunning(true)
        }
        if name == "result" {
            queue.start()
            // Show the finished result, not the progress: wait for the real conversion to end.
            var running = 0.0
            while queue.isRunning && running < 150 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                running += 0.25
            }
        }
        ready = true
    }
}
#endif
