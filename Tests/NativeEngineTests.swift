import XCTest
import AVFoundation
import ImageIO
@testable import Fluxa

/// Real conversions with Apple's frameworks on clips generated in code (no assets, no FFmpeg).
final class NativeEngineTests: XCTestCase {
    private let engine = NativeEngine()

    struct Inspection {
        var duration: Double
        var videoSize: CGSize?
        var videoCodec: String?
        var audioCodec: String?
        var hasVideo: Bool { videoSize != nil }
        var hasAudio: Bool { audioCodec != nil }
    }

    private func inspect(_ url: URL) async throws -> Inspection {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var result = Inspection(duration: duration)
        for track in try await asset.load(.tracks) {
            let descriptions = try await track.load(.formatDescriptions)
            let code = descriptions.first.map { NativeEngine.fourCC(CMFormatDescriptionGetMediaSubType($0)) }
            if track.mediaType == .video {
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                result.videoSize = CGSize(width: abs(rect.width), height: abs(rect.height))
                result.videoCodec = code
            } else if track.mediaType == .audio {
                result.audioCodec = code
            }
        }
        return result
    }

    @discardableResult
    private func convert(_ source: URL, _ spec: OutputSpec, progress: @escaping @Sendable (TranscodeProgress) -> Void = { _ in }) async throws -> (URL, ConversionPlan) {
        let probe = try await engine.probe(url: source)
        let plan = try FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: false)
        XCTAssertEqual(plan.engine, .native)
        let output = Workspace.newOutputURL(fileName: OutputNamer.fileName(source: "clip.mp4", format: spec.format))
        let job = TranscodeJob(id: UUID(), source: source, probe: probe, spec: spec, plan: plan, output: output)
        try await engine.run(job, progress: progress)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        return (output, plan)
    }

    // MARK: Probe

    func testProbeReadsTheGeneratedClip() async throws {
        let clip = try await TestClips.makeMP4(seconds: 2)
        let probe = try await engine.probe(url: clip)
        XCTAssertEqual(probe.video?.codec, .h264)
        XCTAssertEqual(probe.video?.width, 640)
        XCTAssertEqual(probe.video?.height, 360)
        XCTAssertEqual(probe.primaryAudio?.codec, .aac)
        XCTAssertEqual(probe.duration, 2, accuracy: 0.3)
        XCTAssertTrue(probe.nativeReadable)
        XCTAssertFalse(probe.isProtected)
    }

    func testProbeRejectsNonMedia() async throws {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).mp4")
        try Data("this is not a video".utf8).write(to: bogus)
        do {
            _ = try await engine.probe(url: bogus)
            XCTFail("should have thrown")
        } catch let error as ConversionError {
            if case .unreadable = error {} else { XCTFail("wrong error \(error)") }
        }
    }

    // MARK: Video

    func testRemuxMP4ToMOVKeepsEveryStream() async throws {
        let clip = try await TestClips.makeMP4(seconds: 3)
        let (out, plan) = try await convert(clip, OutputSpec(format: .mov))
        XCTAssertEqual(plan.kind, .remux)
        let info = try await inspect(out)
        XCTAssertEqual(info.videoCodec, "avc1")
        XCTAssertEqual(info.audioCodec, "aac")
        XCTAssertEqual(info.duration, 3, accuracy: 0.3)
        XCTAssertEqual(info.videoSize, CGSize(width: 640, height: 360))
    }

    func testTranscodeScalesAndKeepsAudio() async throws {
        let clip = try await TestClips.makeMP4(seconds: 3, width: 1280, height: 720)
        var spec = OutputSpec(format: .mp4, videoCodec: .h264, audioCodec: .aac, resolution: .sd480)
        spec.quality = .balanced
        let (out, plan) = try await convert(clip, spec)
        XCTAssertEqual(plan.kind, .transcode)
        let info = try await inspect(out)
        // 16:9 at 480 lines: the encoder may round the width to a multiple of 4 (852 or 854).
        XCTAssertEqual(info.videoSize?.height ?? 0, 480, accuracy: 0.5)
        XCTAssertEqual(info.videoSize?.width ?? 0, 854, accuracy: 4)
        XCTAssertEqual(info.videoCodec, "avc1")
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.duration, 3, accuracy: 0.4)
    }

    func testRotationSwapsDimensions() async throws {
        let clip = try await TestClips.makeMP4(seconds: 2, width: 640, height: 360)
        var spec = OutputSpec(format: .mp4, videoCodec: .h264)
        spec.rotation = .cw90
        let (out, _) = try await convert(clip, spec)
        let info = try await inspect(out)
        XCTAssertEqual(info.videoSize, CGSize(width: 360, height: 640))
    }

    func testTrimKeepsOnlyTheChosenRange() async throws {
        let clip = try await TestClips.makeMP4(seconds: 4)
        var spec = OutputSpec(format: .mp4, videoCodec: .h264)
        spec.trim = 1...2.5
        let (out, _) = try await convert(clip, spec)
        let info = try await inspect(out)
        XCTAssertEqual(info.duration, 1.5, accuracy: 0.4)
    }

    func testMuteRemovesTheAudioTrack() async throws {
        let clip = try await TestClips.makeMP4(seconds: 2)
        var spec = OutputSpec(format: .mp4)
        spec.mute = true
        let (out, plan) = try await convert(clip, spec)
        XCTAssertEqual(plan.kind, .remux)
        let info = try await inspect(out)
        XCTAssertTrue(info.hasVideo)
        XCTAssertFalse(info.hasAudio)
    }

    func testHEVCEncodeWhenTheMachineSupportsIt() async throws {
        let clip = try await TestClips.makeMP4(seconds: 2)
        let spec = OutputSpec(format: .mp4, videoCodec: .hevc, audioCodec: .aac)
        do {
            let (out, _) = try await convert(clip, spec)
            let info = try await inspect(out)
            XCTAssertTrue(["hvc1", "hev1"].contains(info.videoCodec ?? ""))
        } catch {
            throw XCTSkip("HEVC hardware encoding is not available on this runner: \(error)")
        }
    }

    func test3GPOutput() async throws {
        let clip = try await TestClips.makeMP4(seconds: 2, width: 320, height: 240)
        let (out, _) = try await convert(clip, OutputSpec(format: .threeGP))
        let info = try await inspect(out)
        XCTAssertTrue(info.hasVideo)
        XCTAssertEqual(info.duration, 2, accuracy: 0.4)
    }

    func testProgressReachesOne() async throws {
        let clip = try await TestClips.makeMP4(seconds: 3, width: 1280, height: 720)
        let box = ProgressRecorder()
        var spec = OutputSpec(format: .mp4, videoCodec: .h264)
        spec.resolution = .sd480
        try await convert(clip, spec) { box.add($0.fraction) }
        let values = box.values
        XCTAssertEqual(values.last ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(values, values.sorted(), "progress must never go backwards")
    }

    // MARK: Audio

    func testExtractAudioToEveryNativeAudioFormat() async throws {
        let clip = try await TestClips.makeMP4(seconds: 2)
        for format in [OutputFormat.m4a, .wav, .aiff, .caf] {
            let (out, plan) = try await convert(clip, OutputSpec(format: format))
            XCTAssertEqual(plan.kind, .extractAudio, "\(format)")
            let info = try await inspect(out)
            XCTAssertFalse(info.hasVideo, "\(format)")
            XCTAssertTrue(info.hasAudio, "\(format)")
            XCTAssertEqual(info.duration, 2, accuracy: 0.3, "\(format)")
            if format == .wav || format == .aiff || format == .caf {
                XCTAssertEqual(info.audioCodec, "lpcm", "\(format)")
            }
        }
    }

    func testWAVToM4AEncodesAAC() async throws {
        let clip = try await TestClips.makeMP4(seconds: 2)
        let (wav, _) = try await convert(clip, OutputSpec(format: .wav))
        let (m4a, plan) = try await convert(wav, OutputSpec(format: .m4a, audioBitrateKbps: 128))
        XCTAssertEqual(plan.kind, .audioConvert)
        let info = try await inspect(m4a)
        XCTAssertEqual(info.audioCodec, "aac")
    }

    // MARK: Animated images

    func testGIFOutputIsAnimated() async throws {
        let clip = try await TestClips.makeMP4(seconds: 2, width: 640, height: 360)
        var spec = OutputSpec(format: .gif)
        spec.gif = GifOptions(fps: 10, maxWidth: 320, maxColors: 128, loops: true, dither: true)
        let (out, plan) = try await convert(clip, spec)
        XCTAssertEqual(plan.kind, .animatedImage)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "GIF8")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertGreaterThanOrEqual(CGImageSourceGetCount(source), 15)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(first.width, 320)
    }

    func testAPNGOutputIsAnimated() async throws {
        let clip = try await TestClips.makeMP4(seconds: 1, width: 320, height: 180)
        var spec = OutputSpec(format: .apng)
        spec.gif = GifOptions(fps: 8, maxWidth: 240, maxColors: 128, loops: true, dither: true)
        let (out, _) = try await convert(clip, spec)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 3)
    }

    // MARK: Cancel and failure

    func testCancelStopsAndRemovesTheOutput() async throws {
        let clip = try await TestClips.makeMP4(seconds: 6, width: 1280, height: 720)
        let probe = try await engine.probe(url: clip)
        var spec = OutputSpec(format: .mp4, videoCodec: .h264)
        spec.resolution = .sd480
        let plan = try FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: false)
        let output = Workspace.newOutputURL(fileName: "cancelled.mp4")
        let job = TranscodeJob(id: UUID(), source: clip, probe: probe, spec: spec, plan: plan, output: output)
        let engine = self.engine
        let task = Task { try await engine.run(job, progress: { _ in }) }
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled conversion must throw")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testNotEnoughDiskSpaceIsReportedBeforeStarting() {
        XCTAssertThrowsError(try DiskSpace.ensure(estimatedBytes: Int64.max / 4)) {
            XCTAssertEqual($0 as? ConversionError, .diskFull)
        }
        XCTAssertNoThrow(try DiskSpace.ensure(estimatedBytes: 1_000_000))
    }

    func testNativeCannotWriteFormatsItDoesNotSupport() async throws {
        let clip = try await TestClips.makeMP4(seconds: 1)
        let probe = try await engine.probe(url: clip)
        var spec = OutputSpec(); spec.format = .mkv
        let plan = ConversionPlan(kind: .transcode, engine: .native, fallback: nil, copyVideo: false, copyAudio: false, videoCodec: .h264, audioCodec: .aac)
        let job = TranscodeJob(id: UUID(), source: clip, probe: probe, spec: spec, plan: plan, output: Workspace.newOutputURL(fileName: "x.mkv"))
        do {
            try await engine.run(job, progress: { _ in })
            XCTFail("should have thrown")
        } catch let error as ConversionError {
            if case .unsupportedCombination = error {} else { XCTFail("wrong error \(error)") }
        }
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func add(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
