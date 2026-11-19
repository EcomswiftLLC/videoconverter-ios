import XCTest
@testable import Fluxa

final class FormatMatrixTests: XCTestCase {
    private func plan(_ probe: MediaProbe, _ format: OutputFormat, ffmpeg: Bool = true, tweak: (inout OutputSpec) -> Void = { _ in }) throws -> ConversionPlan {
        var spec = OutputSpec()
        spec.format = format
        tweak(&spec)
        return try FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: ffmpeg)
    }

    // MARK: Spot checks

    func testMKVH264AACToMP4IsLosslessRemux() throws {
        let p = try plan(Samples.probe(video: .h264, audio: .aac, native: false, container: "matroska,webm"), .mp4)
        XCTAssertEqual(p.kind, .remux)
        XCTAssertEqual(p.engine, .ffmpeg)
        XCTAssertTrue(p.copyVideo)
        XCTAssertTrue(p.copyAudio)
        XCTAssertEqual(p.badge, "Lossless · fast")
    }

    func testMP4ToMOVRemuxesNatively() throws {
        let p = try plan(Samples.probe(video: .h264, audio: .aac, native: true), .mov)
        XCTAssertEqual(p.kind, .remux)
        XCTAssertEqual(p.engine, .native)
    }

    func testResolutionChangeForcesReencodeOnHardware() throws {
        let p = try plan(Samples.probe(video: .h264, audio: .aac, native: true), .mp4) { $0.resolution = .hd720 }
        XCTAssertEqual(p.kind, .transcode)
        XCTAssertEqual(p.engine, .native)
        XCTAssertFalse(p.copyVideo)
        XCTAssertTrue(p.copyAudio)
        XCTAssertEqual(p.badge, "Hardware")
    }

    func testHEVCTargetIsNativeAndNeedsReencodeFromH264() throws {
        let p = try plan(Samples.probe(video: .h264, audio: .aac, native: true), .mp4) { $0.videoCodec = .hevc }
        XCTAssertEqual(p.videoCodec, .hevc)
        XCTAssertEqual(p.engine, .native)
        XCTAssertFalse(p.copyVideo)
    }

    func testWebMTargetNeedsFFmpeg() throws {
        let p = try plan(Samples.probe(video: .h264, audio: .aac, native: true), .webm)
        XCTAssertEqual(p.engine, .ffmpeg)
        XCTAssertEqual(p.videoCodec, .vp9)
        XCTAssertEqual(p.audioCodec, .opus)
        XCTAssertThrowsError(try plan(Samples.probe(video: .h264, audio: .aac, native: true), .webm, ffmpeg: false)) {
            XCTAssertEqual($0 as? ConversionError, .needsAdvancedEngine)
        }
    }

    func testMKVSourceWithoutFFmpegFailsClearly() {
        XCTAssertThrowsError(try plan(Samples.probe(video: .h264, audio: .aac, native: false, container: "matroska,webm"), .mp4, ffmpeg: false)) {
            XCTAssertEqual($0 as? ConversionError, .needsAdvancedEngine)
        }
    }

    func testAudioExtractFromMP4ToM4AUsesCopy() throws {
        let p = try plan(Samples.probe(video: .h264, audio: .aac, native: true), .m4a)
        XCTAssertEqual(p.kind, .extractAudio)
        XCTAssertTrue(p.copyAudio)
        XCTAssertEqual(p.engine, .native)
    }

    func testMP3OutputIsFFmpegOnly() throws {
        let p = try plan(Samples.probe(video: .h264, audio: .aac, native: true), .mp3)
        XCTAssertEqual(p.engine, .ffmpeg)
        XCTAssertEqual(p.audioCodec, .mp3)
    }

    func testWAVFromAnyNativeAudioIsNative() throws {
        let p = try plan(Samples.probe(video: nil, audio: .aac, native: true, container: "m4a"), .wav)
        XCTAssertEqual(p.kind, .audioConvert)
        XCTAssertEqual(p.engine, .native)
        XCTAssertFalse(p.copyAudio)
    }

    func testGifPrefersFFmpegWhenAvailableAndFallsBackToNative() throws {
        let source = Samples.probe(video: .h264, audio: .aac, native: true)
        XCTAssertEqual(try plan(source, .gif, ffmpeg: true).engine, .ffmpeg)
        XCTAssertEqual(try plan(source, .gif, ffmpeg: false).engine, .native)
        XCTAssertEqual(try plan(source, .apng, ffmpeg: false).engine, .native)
        XCTAssertThrowsError(try plan(source, .webp, ffmpeg: false))
    }

    func testMuteDropsAudio() throws {
        let p = try plan(Samples.probe(video: .h264, audio: .aac, native: true), .mp4) { $0.mute = true }
        XCTAssertNil(p.audioCodec)
        XCTAssertEqual(p.kind, .remux)
    }

    func testDRMIsRefusedWithAClearError() {
        let probe = Samples.probe(video: .h264, audio: .aac, native: false, protected: true)
        for format in OutputFormat.allCases {
            XCTAssertThrowsError(try plan(probe, format)) { XCTAssertEqual($0 as? ConversionError, .drmProtected) }
        }
    }

    func testAudioOnlySourceCannotMakeVideo() {
        let probe = Samples.probe(video: nil, audio: .mp3, native: true, container: "mp3")
        for format in OutputFormat.formats(in: .video) + OutputFormat.formats(in: .image) {
            XCTAssertThrowsError(try plan(probe, format)) { XCTAssertEqual($0 as? ConversionError, .noVideoTrack, "\(format)") }
        }
    }

    func testVideoWithoutAudioCannotExtractAudio() {
        let probe = Samples.probe(video: .h264, audio: nil, native: true)
        for format in OutputFormat.formats(in: .audio) {
            XCTAssertThrowsError(try plan(probe, format)) { XCTAssertEqual($0 as? ConversionError, .noAudioTrack, "\(format)") }
        }
    }

    func testTrimForcesReencode() throws {
        let p = try plan(Samples.probe(video: .h264, audio: .aac, native: true), .mp4) { $0.trim = 2...10 }
        XCTAssertFalse(p.copyVideo)
        XCTAssertFalse(p.copyAudio)
    }

    // MARK: Every source with every output

    func testEveryPairHasADecisionAndIsConsistent() {
        for (name, probe) in Samples.sources {
            for format in OutputFormat.allCases {
                for ffmpeg in [true, false] {
                    var spec = OutputSpec()
                    spec.format = format
                    do {
                        let plan = try FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: ffmpeg)
                        let label = "\(name) -> \(format.displayName) (ffmpeg \(ffmpeg))"
                        if !ffmpeg { XCTAssertEqual(plan.engine, .native, label) }
                        if plan.engine == .native {
                            XCTAssertTrue(probe.nativeReadable, label)
                            XCTAssertNotNil(format.avFileTypeName ?? (format == .gif || format == .apng ? "image" : nil), label)
                        }
                        if let v = plan.videoCodec, format.category == .video {
                            XCTAssertTrue(format.videoCodecs.contains(v), "\(label): \(v) not allowed in \(format)")
                        }
                        if let a = plan.audioCodec {
                            XCTAssertTrue(format.audioCodecs.contains(a) || format.category == .audio && a == format.defaultAudioCodec, "\(label): \(a) not allowed")
                        }
                        if plan.kind == .remux {
                            XCTAssertTrue(plan.copyVideo, label)
                        }
                    } catch let error as ConversionError {
                        let allowed: [ConversionError] = [.needsAdvancedEngine, .noVideoTrack, .noAudioTrack]
                        XCTAssertTrue(allowed.contains(error), "\(name) -> \(format.displayName): unexpected \(error)")
                        if error == .needsAdvancedEngine { XCTAssertFalse(ffmpeg, "\(name) -> \(format.displayName)") }
                    } catch {
                        XCTFail("unexpected error \(error)")
                    }
                }
            }
        }
    }

    func testWithFFmpegEveryVideoSourceReachesEveryVideoAndAudioFormat() {
        for (name, probe) in Samples.sources where probe.hasVideo {
            for format in OutputFormat.formats(in: .video) + OutputFormat.formats(in: .image) {
                XCTAssertNoThrow(try plan(probe, format), "\(name) -> \(format.displayName)")
            }
            if probe.hasAudio {
                for format in OutputFormat.formats(in: .audio) {
                    XCTAssertNoThrow(try plan(probe, format), "\(name) -> \(format.displayName)")
                }
            }
        }
    }

    func testEveryAudioSourceReachesEveryAudioFormat() {
        for (name, probe) in Samples.sources where probe.isAudioOnly {
            for format in OutputFormat.formats(in: .audio) {
                XCTAssertNoThrow(try plan(probe, format), "\(name) -> \(format.displayName)")
            }
        }
    }

    // MARK: Tables

    func testEveryFormatHasCodecsAndNames() {
        for format in OutputFormat.allCases {
            XCTAssertFalse(format.displayName.isEmpty)
            XCTAssertFalse(format.fileExtension.isEmpty)
            XCTAssertFalse(format.summary.isEmpty)
            switch format.category {
            case .video:
                XCTAssertFalse(format.videoCodecs.isEmpty, "\(format)")
                XCTAssertFalse(format.audioCodecs.isEmpty, "\(format)")
            case .audio:
                XCTAssertTrue(format.videoCodecs.isEmpty, "\(format)")
                XCTAssertFalse(format.audioCodecs.isEmpty, "\(format)")
            case .image:
                XCTAssertTrue(format.audioCodecs.isEmpty, "\(format)")
            }
        }
        XCTAssertEqual(Set(OutputFormat.allCases.map { $0.fileExtension }).count, OutputFormat.allCases.count)
    }

    func testPresetsAreValid() {
        XCTAssertGreaterThanOrEqual(ConversionPreset.all.count, 10)
        XCTAssertEqual(Set(ConversionPreset.all.map { $0.id }).count, ConversionPreset.all.count)
        for preset in ConversionPreset.all {
            let spec = preset.spec
            if let v = spec.videoCodec { XCTAssertTrue(spec.format.videoCodecs.contains(v), "\(preset.id)") }
            if let a = spec.audioCodec { XCTAssertTrue(spec.format.audioCodecs.contains(a), "\(preset.id)") }
            XCTAssertNotNil(spec.format.defaultAudioCodec ?? spec.format.defaultVideoCodec ?? (spec.format.category == .image ? OutputFormat.gif : nil))
        }
    }

    func testInputGroupsCoverTheSpecList() {
        let all = Set(InputFormats.allExtensions)
        for ext in ["mp4", "mov", "m4v", "3gp", "mkv", "webm", "avi", "wmv", "asf", "flv", "f4v", "mpg", "mpeg", "vob", "ts", "m2ts", "mts", "mxf", "ogv", "rm", "rmvb", "dv", "gif", "webp", "mp3", "aac", "m4a", "wav", "aiff", "caf", "flac", "opus", "wma", "amr", "ac3", "eac3"] {
            XCTAssertTrue(all.contains(ext), "missing \(ext)")
        }
    }
}
