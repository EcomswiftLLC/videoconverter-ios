import XCTest
@testable import Fluxa

final class FFmpegBuilderTests: XCTestCase {
    private func job(_ probe: MediaProbe, _ spec: OutputSpec) throws -> TranscodeJob {
        let plan = try FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: true)
        return TranscodeJob(id: UUID(), source: URL(fileURLWithPath: "/tmp/in.mkv"), probe: probe, spec: spec, plan: plan, output: URL(fileURLWithPath: "/tmp/out.\(spec.format.fileExtension)"))
    }

    private func args(_ probe: MediaProbe, _ spec: OutputSpec) throws -> [String] {
        FFmpegCommandBuilder.arguments(job: try job(probe, spec))
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func testEveryOutputFormatBuildsACommand() throws {
        for format in OutputFormat.allCases {
            for (name, probe) in Samples.sources {
                var spec = OutputSpec()
                spec.format = format
                guard let planned = try? FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: true) else { continue }
                let job = TranscodeJob(id: UUID(), source: URL(fileURLWithPath: "/in/\(name).bin"), probe: probe, spec: spec, plan: planned, output: URL(fileURLWithPath: "/out/o.\(format.fileExtension)"))
                let a = FFmpegCommandBuilder.arguments(job: job)
                let label = "\(name) -> \(format.displayName)"
                XCTAssertEqual(a.first, "-hide_banner", label)
                XCTAssertEqual(a.last, "/out/o.\(format.fileExtension)", label)
                XCTAssertEqual(value(after: "-f", in: a), FFmpegCommandBuilder.muxer(for: format), label)
                XCTAssertEqual(value(after: "-i", in: a), "/in/\(name).bin", label)
                XCTAssertTrue(a.contains("-y"), label)
                // No stray empty arguments, which FFmpeg would read as file names.
                XCTAssertFalse(a.contains(""), label)
            }
        }
    }

    func testMKVToMP4CopiesStreams() throws {
        let a = try args(Samples.probe(video: .h264, audio: .aac, native: false, container: "matroska,webm"), OutputSpec(format: .mp4))
        XCTAssertEqual(value(after: "-c:v", in: a), "copy")
        XCTAssertEqual(value(after: "-c:a", in: a), "copy")
        XCTAssertEqual(value(after: "-tag:v", in: a), "avc1")
        XCTAssertTrue(a.contains("+faststart"))
        XCTAssertTrue(a.contains("-sn"))
    }

    func testH264VideoToolboxEncodeHasBitrateAndFilters() throws {
        var spec = OutputSpec(format: .mp4, videoCodec: .h264, audioCodec: .aac, resolution: .hd720)
        spec.fps = 24
        let a = try args(Samples.probe(video: .hevc, audio: .aac, native: false, container: "matroska,webm"), spec)
        XCTAssertEqual(value(after: "-c:v", in: a), "h264_videotoolbox")
        XCTAssertNotNil(value(after: "-b:v", in: a))
        let vf = value(after: "-vf", in: a) ?? ""
        XCTAssertTrue(vf.contains("scale=1280:720"), vf)
        XCTAssertTrue(vf.contains("fps=24"), vf)
        XCTAssertTrue(vf.hasSuffix("format=yuv420p"), vf)
    }

    func testVerticalVideoKeepsOrientationWhenScaling() throws {
        var probe = Samples.probe(video: .h264, audio: .aac, native: true)
        probe.video = Samples.video(.h264, width: 1080, height: 1920)
        var spec = OutputSpec(format: .mp4, resolution: .hd720)
        spec.videoCodec = .hevc
        let a = try args(probe, spec)
        XCTAssertTrue((value(after: "-vf", in: a) ?? "").contains("scale=720:1280"))
    }

    func testRotationSwapsTheOutputSize() throws {
        var spec = OutputSpec(format: .mp4, videoCodec: .h264, resolution: .hd720)
        spec.rotation = .cw90
        let a = try args(Samples.probe(video: .h264, audio: .aac, native: true), spec)
        let vf = value(after: "-vf", in: a) ?? ""
        XCTAssertTrue(vf.hasPrefix("transpose=1"), vf)
        XCTAssertTrue(vf.contains("scale=720:1280"), vf)
    }

    func testWebMUsesVP9AndOpus() throws {
        let a = try args(Samples.probe(video: .h264, audio: .aac, native: true), OutputSpec(format: .webm))
        XCTAssertEqual(value(after: "-c:v", in: a), "libvpx-vp9")
        XCTAssertEqual(value(after: "-c:a", in: a), "libopus")
        XCTAssertEqual(value(after: "-ar", in: a), "48000")
        XCTAssertEqual(value(after: "-f", in: a), "webm")
    }

    func testMPEG2FrameRateIsSnappedToAllowedRates() throws {
        var probe = Samples.probe(video: .h264, audio: .aac, native: true)
        probe.video = Samples.video(.h264, fps: 29.97)
        let a = try args(probe, OutputSpec(format: .mpg))
        XCTAssertTrue((value(after: "-vf", in: a) ?? "").contains("fps=30000/1001"))
        XCTAssertEqual(FFmpegCommandBuilder.snappedMPEGFrameRate(14.9), "24000/1001")
        XCTAssertEqual(FFmpegCommandBuilder.snappedMPEGFrameRate(61), "60")
    }

    func testAudioFormatsPickTheRightEncoders() throws {
        let probe = Samples.probe(video: .h264, audio: .aac, native: true)
        let expectations: [(OutputFormat, String)] = [
            (.mp3, "libmp3lame"), (.flac, "flac"), (.opus, "libopus"), (.ogg, "libvorbis"), (.ac3, "ac3"),
            (.wav, "pcm_s16le"), (.aiff, "pcm_s16be"), (.caf, "pcm_s16le")
        ]
        for (format, encoder) in expectations {
            let a = try args(probe, OutputSpec(format: format))
            XCTAssertEqual(value(after: "-c:a", in: a), encoder, "\(format)")
            XCTAssertTrue(a.contains("-vn"), "\(format)")
        }
        let mp3 = try args(probe, OutputSpec(format: .mp3, audioBitrateKbps: 256))
        XCTAssertEqual(value(after: "-b:a", in: mp3), "256k")
    }

    func testTrimUsesFastSeekBeforeInput() throws {
        var spec = OutputSpec(format: .mp4, videoCodec: .h264)
        spec.trim = 5...15
        let a = try args(Samples.probe(video: .h264, audio: .aac, native: true), spec)
        let ss = a.firstIndex(of: "-ss"), i = a.firstIndex(of: "-i"), t = a.firstIndex(of: "-t")
        XCTAssertNotNil(ss); XCTAssertNotNil(i); XCTAssertNotNil(t)
        XCTAssertLessThan(ss!, i!)
        XCTAssertGreaterThan(t!, i!)
        XCTAssertEqual(value(after: "-t", in: a), "10.000")
    }

    func testStripMetadata() throws {
        var spec = OutputSpec(format: .mp4)
        spec.stripMetadata = true
        let a = try args(Samples.probe(video: .h264, audio: .aac, native: true), spec)
        XCTAssertEqual(value(after: "-map_metadata", in: a), "-1")
    }

    func testMuteRemovesAudioStream() throws {
        var spec = OutputSpec(format: .mkv)
        spec.mute = true
        let a = try args(Samples.probe(video: .h264, audio: .aac, native: true), spec)
        XCTAssertTrue(a.contains("-an"))
        XCTAssertFalse(a.contains("0:a:0"))
    }

    func testGifUsesPaletteFilters() throws {
        var spec = OutputSpec(format: .gif)
        spec.gif = GifOptions(fps: 15, maxWidth: 320, maxColors: 64, loops: true, dither: true)
        let a = try args(Samples.probe(video: .h264, audio: .aac, native: true, duration: 10), spec)
        let vf = value(after: "-vf", in: a) ?? ""
        XCTAssertTrue(vf.contains("palettegen=max_colors=64"), vf)
        XCTAssertTrue(vf.contains("paletteuse"), vf)
        XCTAssertTrue(vf.contains("scale=320:-2"), vf)
        XCTAssertTrue(vf.contains("fps=15"), vf)
        XCTAssertEqual(value(after: "-loop", in: a), "0")
        XCTAssertTrue(a.contains("-an"))
    }

    func testLongGifLowersFrameRateToStayUnder600Frames() throws {
        var spec = OutputSpec(format: .gif)
        spec.gif.fps = 24
        let a = try args(Samples.probe(video: .h264, audio: nil, native: true, duration: 120), spec)
        let vf = value(after: "-vf", in: a) ?? ""
        XCTAssertTrue(vf.contains("fps=5"), vf)
    }

    func testWebPAndAPNGEncoders() throws {
        let probe = Samples.probe(video: .h264, audio: .aac, native: true, duration: 5)
        XCTAssertEqual(value(after: "-c:v", in: try args(probe, OutputSpec(format: .webp))), "libwebp_anim")
        XCTAssertEqual(value(after: "-c:v", in: try args(probe, OutputSpec(format: .apng))), "apng")
    }

    func testProResUses422AndProfile() throws {
        let a = try args(Samples.probe(video: .h264, audio: .aac, native: true), OutputSpec(format: .mov, videoCodec: .prores, audioCodec: .pcm))
        XCTAssertEqual(value(after: "-c:v", in: a), "prores_ks")
        XCTAssertTrue((value(after: "-vf", in: a) ?? "").hasSuffix("format=yuv422p10le"))
        XCTAssertEqual(value(after: "-c:a", in: a), "pcm_s16le")
    }

    func testHDRToneMapOnlyWithZscale() throws {
        var probe = Samples.probe(video: .hevc, audio: .aac, native: true, hdr: true)
        probe.video?.isHDR = true
        var spec = OutputSpec(format: .mp4, videoCodec: .h264)
        spec.tonemapHDR = true
        let planned = try FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: true)
        let job = TranscodeJob(id: UUID(), source: URL(fileURLWithPath: "/in"), probe: probe, spec: spec, plan: planned, output: URL(fileURLWithPath: "/out.mp4"))
        let without = FFmpegCommandBuilder.arguments(job: job, capabilities: FFmpegCapabilities(hasZscale: false))
        let with = FFmpegCommandBuilder.arguments(job: job, capabilities: FFmpegCapabilities(hasZscale: true))
        XCTAssertFalse((value(after: "-vf", in: without) ?? "").contains("tonemap"))
        XCTAssertTrue((value(after: "-vf", in: with) ?? "").contains("tonemap"))
    }

    // MARK: Probe parser

    func testParsesATypicalMKVProbe() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_name":"h264","codec_type":"video","width":1920,"height":1080,"r_frame_rate":"24000/1001","avg_frame_rate":"24000/1001","bit_rate":"8000000","pix_fmt":"yuv420p"},
          {"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":6,"bit_rate":"384000"},
          {"index":2,"codec_name":"ac3","codec_type":"audio","sample_rate":"48000","channels":2},
          {"index":3,"codec_name":"subrip","codec_type":"subtitle"}
        ],"format":{"format_name":"matroska,webm","duration":"5400.250000","size":"6000000000","bit_rate":"8900000"}}
        """
        let probe = try FFmpegProbeParser.parse(json: json, fileSize: 1)
        XCTAssertEqual(probe.video?.codec, .h264)
        XCTAssertEqual(probe.video?.width, 1920)
        XCTAssertEqual(Double(probe.video?.fps ?? 0), 23.976, accuracy: 0.01)
        XCTAssertEqual(probe.audio.count, 2)
        XCTAssertEqual(probe.audio.first?.codec, .aac)
        XCTAssertEqual(probe.audio.first?.channels, 6)
        XCTAssertEqual(probe.subtitleCount, 1)
        XCTAssertEqual(probe.duration, 5400.25, accuracy: 0.001)
        XCTAssertEqual(probe.fileSize, 6_000_000_000)
        XCTAssertFalse(probe.nativeReadable)
    }

    func testIgnoresCoverArtAndReadsRotation() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_name":"mjpeg","codec_type":"video","width":500,"height":500,"disposition":{"attached_pic":1}},
          {"index":1,"codec_name":"mp3","codec_type":"audio","sample_rate":"44100","channels":2}
        ],"format":{"format_name":"mp3","duration":"200.0","size":"3200000","bit_rate":"128000"}}
        """
        let audioOnly = try FFmpegProbeParser.parse(json: json, fileSize: 0)
        XCTAssertNil(audioOnly.video)
        XCTAssertTrue(audioOnly.isAudioOnly)

        let rotated = """
        {"streams":[{"index":0,"codec_name":"hevc","codec_type":"video","width":3840,"height":2160,"avg_frame_rate":"30/1","side_data_list":[{"side_data_type":"Display Matrix","rotation":-90}],"color_transfer":"arib-std-b67"}],"format":{"format_name":"mov,mp4","duration":"10","size":"1000"}}
        """
        let probe = try FFmpegProbeParser.parse(json: rotated, fileSize: 0)
        XCTAssertEqual(probe.video?.rotation, 90)
        XCTAssertEqual(probe.video?.displaySize.width, 2160)
        XCTAssertTrue(probe.video?.isHDR == true)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try FFmpegProbeParser.parse(json: "not json", fileSize: 0))
        XCTAssertThrowsError(try FFmpegProbeParser.parse(json: "{\"streams\":[],\"format\":{}}", fileSize: 0))
    }

    func testFailureMapping() {
        XCTAssertEqual(FFmpegEngine.mapFailure("No space left on device"), .diskFull)
        XCTAssertEqual(FFmpegEngine.mapFailure("moov atom not found"), .unreadable("the file looks damaged or incomplete"))
        XCTAssertEqual(FFmpegEngine.mapFailure("something odd"), .engineFailed(""))
    }
}
