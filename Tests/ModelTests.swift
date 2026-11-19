import XCTest
@testable import Fluxa

final class ModelTests: XCTestCase {
    // MARK: Estimator

    func testOutputSizeKeepsAspectAndEvenNumbers() {
        XCTAssertEqual(BitrateEstimator.outputSize(sourceWidth: 3840, sourceHeight: 2160, resolution: .hd1080).width, 1920)
        XCTAssertEqual(BitrateEstimator.outputSize(sourceWidth: 3840, sourceHeight: 2160, resolution: .hd1080).height, 1080)
        let vertical = BitrateEstimator.outputSize(sourceWidth: 1080, sourceHeight: 1920, resolution: .hd720)
        XCTAssertEqual(vertical.width, 720)
        XCTAssertEqual(vertical.height, 1280)
        // Never upscales.
        let small = BitrateEstimator.outputSize(sourceWidth: 640, sourceHeight: 360, resolution: .hd1080)
        XCTAssertEqual(small.width, 640)
        XCTAssertEqual(small.height, 360)
        // Odd source sizes become even.
        let odd = BitrateEstimator.outputSize(sourceWidth: 853, sourceHeight: 481, resolution: .keep)
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertEqual(odd.height % 2, 0)
    }

    func testBitrateGrowsWithQualityAndShrinksWithEfficientCodecs() {
        let low = BitrateEstimator.videoKbps(codec: .h264, width: 1920, height: 1080, fps: 30, quality: .low)
        let high = BitrateEstimator.videoKbps(codec: .h264, width: 1920, height: 1080, fps: 30, quality: .high)
        let hevc = BitrateEstimator.videoKbps(codec: .hevc, width: 1920, height: 1080, fps: 30, quality: .high)
        XCTAssertLessThan(low, high)
        XCTAssertLessThan(hevc, high)
        XCTAssertGreaterThan(high, 4000)
        XCTAssertLessThan(high, 12000)
    }

    func testEstimatedSizeForVideoAudioAndCopy() {
        let probe = Samples.probe(video: .h264, audio: .aac, native: true, duration: 100)
        var spec = OutputSpec(format: .mp4, videoCodec: .h264, audioCodec: .aac)
        spec.resolution = .hd720
        let plan = try? FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: true)
        let bytes = BitrateEstimator.estimatedBytes(probe: probe, spec: spec, plan: plan)
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 1_000_000)

        let remux = OutputSpec(format: .mov)
        let remuxPlan = try? FormatMatrix.plan(probe: probe, spec: remux, ffmpegAvailable: true)
        let copyBytes = BitrateEstimator.estimatedBytes(probe: probe, spec: remux, plan: remuxPlan) ?? 0
        // 4 Mbit/s video + 128 kbit/s audio for 100 s is about 51.6 MB.
        XCTAssertEqual(Double(copyBytes), 51_600_000, accuracy: 5_000_000)
    }

    func testEstimatedSizeForAudioMatchesBitrate() {
        let probe = Samples.probe(video: nil, audio: .aac, native: true, container: "m4a", duration: 60)
        let mp3 = BitrateEstimator.estimatedBytes(probe: probe, spec: OutputSpec(format: .mp3, audioBitrateKbps: 192), plan: nil) ?? 0
        XCTAssertEqual(Double(mp3), 192_000.0 / 8 * 60, accuracy: 1000)
        let wav = BitrateEstimator.estimatedBytes(probe: probe, spec: OutputSpec(format: .wav), plan: nil) ?? 0
        XCTAssertEqual(Double(wav), 44100.0 * 16 * 2 / 8 * 60, accuracy: 10000)
    }

    func testTrimShortensTheEstimate() {
        let probe = Samples.probe(video: .h264, audio: .aac, native: true, duration: 100)
        var spec = OutputSpec(format: .mp4, videoCodec: .h264)
        let full = BitrateEstimator.estimatedBytes(probe: probe, spec: spec, plan: nil) ?? 0
        spec.trim = 0...25
        let quarter = BitrateEstimator.estimatedBytes(probe: probe, spec: spec, plan: nil) ?? 0
        XCTAssertEqual(Double(quarter) / Double(full), 0.25, accuracy: 0.01)
    }

    // MARK: Naming

    func testFileNames() {
        XCTAssertEqual(OutputNamer.fileName(source: "Holiday.mkv", format: .mp4), "Holiday.mp4")
        XCTAssertEqual(OutputNamer.fileName(source: "/path/to/My clip.final.avi", format: .threeGP), "My clip.final.3gp")
        XCTAssertEqual(OutputNamer.fileName(source: "a:b/c.mov", format: .webm), "c.webm")
        XCTAssertEqual(OutputNamer.fileName(source: "", format: .mp3), "Fluxa.mp3")
        XCTAssertEqual(OutputNamer.fileName(source: "Song.flac", format: .mp3, existing: ["song.mp3"]), "Song 2.mp3")
        XCTAssertEqual(OutputNamer.fileName(source: "Song.flac", format: .mp3, existing: ["song.mp3", "song 2.mp3"]), "Song 3.mp3")
        XCTAssertLessThanOrEqual(OutputNamer.baseName(String(repeating: "x", count: 300)).count, 80)
    }

    // MARK: Errors and formatting

    func testEveryErrorHasATitleAndAMessage() {
        let errors: [ConversionError] = [.drmProtected, .unreadable("x"), .unreadable(""), .noVideoTrack, .noAudioTrack, .needsAdvancedEngine, .unsupportedCombination("Nope"), .diskFull, .cancelled, .outputTooLarge, .engineFailed("boom"), .engineFailed("")]
        for error in errors {
            XCTAssertFalse(error.title.isEmpty)
            XCTAssertFalse(error.message.isEmpty)
        }
        XCTAssertTrue(ConversionError.drmProtected.message.contains("DRM"))
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.duration(0), "0:00")
        XCTAssertEqual(Fmt.duration(65), "1:05")
        XCTAssertEqual(Fmt.duration(3725), "1:02:05")
        XCTAssertEqual(Fmt.duration(-3), "0:00")
        XCTAssertEqual(Fmt.duration(.nan), "0:00")
    }

    func testCodecNameMapping() {
        XCTAssertEqual(VideoCodec.fromName("avc1"), .h264)
        XCTAssertEqual(VideoCodec.fromName("hvc1"), .hevc)
        XCTAssertEqual(VideoCodec.fromName("mpeg4"), .mpeg4)
        XCTAssertEqual(VideoCodec.fromName("apcn"), .prores)
        XCTAssertNil(VideoCodec.fromName("indeo5"))
        XCTAssertEqual(AudioCodec.fromName("mp4a"), .aac)
        XCTAssertEqual(AudioCodec.fromName("lpcm"), .pcm)
        XCTAssertEqual(AudioCodec.fromName("pcm_s16le"), .pcm)
        XCTAssertEqual(AudioCodec.fromName(".mp3"), .mp3)
        XCTAssertEqual(AudioCodec.fromName("ec-3"), .ac3)
        XCTAssertNil(AudioCodec.fromName("cook"))
    }

    // MARK: Rewarded policy (shared rules with the other apps)

    func testRewardedPolicyOffersOnlyWhenAnAdIsReady() {
        let policy = RewardedPolicy()
        XCTAssertEqual(policy.decision(adsReady: false, adReady: true, reloadInFlightAfterEarlyClose: false), .exportNow)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: false, reloadInFlightAfterEarlyClose: false), .exportNow)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: true, reloadInFlightAfterEarlyClose: false), .offerAd)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: false, reloadInFlightAfterEarlyClose: true), .waitForAd)
    }

    func testOneWatchedAdCoversTheWholeBatch() {
        var policy = RewardedPolicy()
        let t0 = Date()
        policy.didEarnReward(now: t0)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: true, reloadInFlightAfterEarlyClose: false, now: t0.addingTimeInterval(30)), .exportNow)
        policy.exportDidEnd(now: t0.addingTimeInterval(40))
        XCTAssertEqual(policy.decision(adsReady: true, adReady: true, reloadInFlightAfterEarlyClose: false, now: t0.addingTimeInterval(100)), .exportNow)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: true, reloadInFlightAfterEarlyClose: false, now: t0.addingTimeInterval(200)), .offerAd)
    }

    func testAdUnitIdsAreNeverUnresolvedPlaceholders() {
        XCTAssertNil(AdsConfiguration.normalizedUnitID("$(ADMOB_BANNER_UNIT_ID)"))
        XCTAssertNil(AdsConfiguration.normalizedUnitID(""))
        XCTAssertEqual(AdsConfiguration.normalizedUnitID(" ca-app-pub-1/2 "), "ca-app-pub-1/2")
        XCTAssertNotNil(AdsConfiguration.bannerUnitID)
        XCTAssertNotNil(AdsConfiguration.rewardedUnitID)
    }
}
