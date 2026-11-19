import XCTest
import AVFoundation
@testable import Fluxa

/// Real conversions through the FFmpeg engine. They run only in builds that link the LGPL FFmpeg libraries
/// (CI pins them in tools/ffmpeg/VERSION); otherwise every test is skipped, never silently passed.
final class FFmpegIntegrationTests: XCTestCase {
    private var bridge: FFmpegBridge!
    private var engine: FFmpegEngine!

    override func setUpWithError() throws {
        guard let bridge = FFmpegBridgeProvider.makeBridge() else {
            throw XCTSkip("This build does not include the FFmpeg libraries.")
        }
        self.bridge = bridge
        self.engine = FFmpegEngine(bridge: bridge)
    }

    // MARK: Helpers

    private func convert(_ source: URL, _ spec: OutputSpec, file: StaticString = #filePath, line: UInt = #line) async throws -> (URL, MediaProbe) {
        let probe = try await engine.probe(url: source)
        let plan = try FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: true)
        let output = Workspace.newOutputURL(fileName: OutputNamer.fileName(source: "clip.mp4", format: spec.format))
        let job = TranscodeJob(id: UUID(), source: source, probe: probe, spec: spec, plan: plan, output: output)
        try await engine.run(job, progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "output exists for \(spec.format)", file: file, line: line)
        let result = try await engine.probe(url: output)
        return (output, result)
    }

    private func sourceClip() async throws -> URL {
        try await TestClips.makeMP4(seconds: 3, width: 640, height: 360)
    }

    // MARK: Library

    func testLibraryReportsTheExpectedEncoders() {
        let caps = bridge.capabilities
        for name in ["h264_videotoolbox", "libvpx-vp9", "libopus", "libvorbis", "libmp3lame", "aac", "flac", "mpeg4", "gif"] {
            XCTAssertTrue(caps.encoders.contains(name), "missing encoder \(name)")
        }
    }

    func testProbeMatchesTheNativeProbe() async throws {
        let clip = try await sourceClip()
        let probe = try await engine.probe(url: clip)
        XCTAssertEqual(probe.video?.codec, .h264)
        XCTAssertEqual(probe.video?.width, 640)
        XCTAssertEqual(probe.video?.height, 360)
        XCTAssertEqual(probe.primaryAudio?.codec, .aac)
        XCTAssertEqual(probe.duration, 3, accuracy: 0.4)
    }

    // MARK: Every target, from the generated clip

    func testEveryVideoFormatCanBeWrittenAndReadBack() async throws {
        let clip = try await sourceClip()
        for format in OutputFormat.formats(in: .video) {
            let (_, result) = try await convert(clip, OutputSpec(format: format))
            XCTAssertTrue(result.hasVideo, "\(format.displayName) has video")
            XCTAssertTrue(result.hasAudio, "\(format.displayName) has audio")
            XCTAssertEqual(result.duration, 3, accuracy: 0.8, "\(format.displayName) duration")
            XCTAssertEqual(result.video?.width, 640, "\(format.displayName) width")
        }
    }

    func testEveryAudioFormatCanBeExtracted() async throws {
        let clip = try await sourceClip()
        for format in OutputFormat.formats(in: .audio) {
            let (_, result) = try await convert(clip, OutputSpec(format: format))
            XCTAssertFalse(result.hasVideo, "\(format.displayName) has no picture")
            XCTAssertTrue(result.hasAudio, "\(format.displayName) has audio")
            XCTAssertEqual(result.duration, 3, accuracy: 0.8, "\(format.displayName) duration")
        }
    }

    func testAnimatedImages() async throws {
        let clip = try await sourceClip()
        for format in OutputFormat.formats(in: .image) {
            var spec = OutputSpec(format: format)
            spec.gif = GifOptions(fps: 8, maxWidth: 240, maxColors: 128, loops: true, dither: true)
            let (output, _) = try await convert(clip, spec)
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            XCTAssertGreaterThan(size, 1000, "\(format.displayName) has content")
        }
    }

    // MARK: Chains across containers (every format is also used as a source)

    func testEveryWrittenFormatCanBeReadAsASource() async throws {
        let clip = try await sourceClip()
        let hop: [OutputFormat] = [.mkv, .webm, .avi, .flv, .wmv, .mpg, .ts]
        for first in hop {
            let (middle, _) = try await convert(clip, OutputSpec(format: first))
            for second in [OutputFormat.mp4, .mkv, .mp3, .wav] where second != first {
                let (_, result) = try await convert(middle, OutputSpec(format: second))
                XCTAssertGreaterThan(result.duration, 1.5, "\(first.displayName) -> \(second.displayName)")
            }
        }
    }

    func testLosslessRemuxFromMP4ToMKVAndBack() async throws {
        let clip = try await sourceClip()
        let (mkv, mkvProbe) = try await convert(clip, OutputSpec(format: .mkv))
        XCTAssertEqual(mkvProbe.video?.codec, .h264, "a remux keeps the original video")
        let (_, back) = try await convert(mkv, OutputSpec(format: .mp4))
        XCTAssertEqual(back.video?.codec, .h264)
        XCTAssertEqual(back.primaryAudio?.codec, .aac)
    }

    func testTrimAndResize() async throws {
        let clip = try await sourceClip()
        var spec = OutputSpec(format: .webm)
        spec.trim = 1...2.5
        spec.resolution = .sd480
        let (_, result) = try await convert(clip, spec)
        XCTAssertEqual(result.duration, 1.5, accuracy: 0.6)
        XCTAssertLessThanOrEqual(result.video?.height ?? 9999, 480)
    }

    func testCancelStopsAndRemovesTheOutput() async throws {
        let clip = try await TestClips.makeMP4(seconds: 8, width: 1280, height: 720)
        let probe = try await engine.probe(url: clip)
        var spec = OutputSpec(format: .webm)
        spec.resolution = .hd720
        let plan = try FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: true)
        let output = Workspace.newOutputURL(fileName: "cancelled.webm")
        let job = TranscodeJob(id: UUID(), source: clip, probe: probe, spec: spec, plan: plan, output: output)
        let engine = self.engine!
        let task = Task { try await engine.run(job, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled conversion must throw")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDamagedFileIsReportedNotCrashed() async throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).mkv")
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: junk)
        do {
            _ = try await engine.probe(url: junk)
            XCTFail("should not be readable")
        } catch let error as ConversionError {
            if case .unreadable = error {} else { XCTFail("wrong error \(error)") }
        }
    }
}
