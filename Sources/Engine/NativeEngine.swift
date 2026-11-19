import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

/// Converts with Apple's own frameworks: hardware H.264 and HEVC, AAC, PCM, lossless stream copy, and GIF/APNG through ImageIO.
final class NativeEngine: TranscodeEngine {
    let kind: EngineKind = .native

    // MARK: Probe

    func probe(url: URL) async throws -> MediaProbe {
        let asset = AVURLAsset(url: url)
        let readable = (try? await asset.load(.isReadable)) ?? false
        let protected = (try? await asset.load(.hasProtectedContent)) ?? false
        if protected {
            return MediaProbe(containerName: url.pathExtension.lowercased(), duration: 0, fileSize: Self.fileSize(url), bitrate: 0, video: nil, audio: [], isProtected: true, nativeReadable: false)
        }
        guard readable else { throw ConversionError.unreadable("not an Apple-readable file") }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let tracks = (try? await asset.load(.tracks)) ?? []
        var video: VideoStreamInfo?
        var audio: [AudioStreamInfo] = []
        var decodable = true

        for track in tracks {
            let isDecodable = (try? await track.load(.isDecodable)) ?? true
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            switch track.mediaType {
            case .video:
                if video != nil { continue }
                if !isDecodable { decodable = false }
                let size = (try? await track.load(.naturalSize)) ?? .zero
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
                let rate = Int((try? await track.load(.estimatedDataRate)) ?? 0)
                var codecName = "unknown"
                var hdr = false
                if let fd = descriptions.first {
                    let sub = CMFormatDescriptionGetMediaSubType(fd)
                    codecName = Self.fourCC(sub)
                    if let transfer = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                        hdr = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                    }
                }
                let angle = atan2(Double(transform.b), Double(transform.a)) * 180 / .pi
                let rotation = ((Int(angle.rounded()) % 360) + 360) % 360
                video = VideoStreamInfo(
                    codecName: codecName, codec: VideoCodec.fromName(codecName),
                    width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                    fps: fps > 0 ? fps : 30, bitrate: rate,
                    rotation: [0, 90, 180, 270].min(by: { abs($0 - rotation) < abs($1 - rotation) }) ?? 0,
                    isHDR: hdr
                )
            case .audio:
                if !isDecodable { decodable = false }
                var info = AudioStreamInfo(codecName: "unknown", codec: nil, sampleRate: 44100, channels: 2, bitrate: 0)
                if let fd = descriptions.first {
                    let name = Self.fourCC(CMFormatDescriptionGetMediaSubType(fd))
                    info.codecName = name
                    info.codec = AudioCodec.fromName(name)
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                        info.sampleRate = Int(asbd.mSampleRate)
                        info.channels = Int(asbd.mChannelsPerFrame)
                    }
                }
                info.bitrate = Int((try? await track.load(.estimatedDataRate)) ?? 0)
                audio.append(info)
            default:
                break
            }
        }
        if video == nil && audio.isEmpty { throw ConversionError.unreadable("no audio or video tracks") }
        let size = Self.fileSize(url)
        return MediaProbe(
            containerName: url.pathExtension.lowercased(),
            duration: duration.isFinite ? duration : 0,
            fileSize: size,
            bitrate: duration > 0 ? Int(Double(size) * 8 / duration) : 0,
            video: video, audio: audio,
            isProtected: false,
            nativeReadable: decodable
        )
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let text = String(bytes: bytes, encoding: .isoLatin1) ?? "????"
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Run

    func run(_ job: TranscodeJob, progress: @escaping @Sendable (TranscodeProgress) -> Void) async throws {
        try? FileManager.default.removeItem(at: job.output)
        let estimate = BitrateEstimator.estimatedBytes(probe: job.probe, spec: job.spec, plan: job.plan)
        try DiskSpace.ensure(estimatedBytes: estimate)

        switch job.plan.kind {
        case .animatedImage:
            try await runAnimatedImage(job, progress: progress)
        default:
            try await runReaderWriter(job, progress: progress)
        }
    }

    // MARK: Reader / writer pipeline (video, audio)

    private func fileType(for format: OutputFormat) throws -> AVFileType {
        switch format {
        case .mp4: return .mp4
        case .mov: return .mov
        case .m4v: return .m4v
        case .threeGP: return .mobile3GPP
        case .m4a: return .m4a
        case .wav: return .wav
        case .aiff: return .aiff
        case .caf: return .caf
        default: throw ConversionError.unsupportedCombination("\(format.displayName) needs the extended engine.")
        }
    }

    private func runReaderWriter(_ job: TranscodeJob, progress: @escaping @Sendable (TranscodeProgress) -> Void) async throws {
        let spec = job.spec
        let plan = job.plan
        let asset = AVURLAsset(url: job.source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let assetDuration = try await asset.load(.duration)

        let wantsVideo = spec.format.category == .video
        let wantsAudio = (spec.format.category == .audio) || (wantsVideo && !spec.mute)
        if wantsVideo && videoTracks.isEmpty { throw ConversionError.noVideoTrack }
        if spec.format.category == .audio && audioTracks.isEmpty { throw ConversionError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: job.output, fileType: try fileType(for: spec.format))
        writer.shouldOptimizeForNetworkUse = wantsVideo

        // Trim range.
        var startTime = CMTime.zero
        var rangeDuration = assetDuration
        if let trim = spec.trim {
            let start = max(0, trim.lowerBound)
            let end = min(trim.upperBound, assetDuration.seconds)
            if end > start {
                startTime = CMTime(seconds: start, preferredTimescale: 600)
                rangeDuration = CMTime(seconds: end - start, preferredTimescale: 600)
                reader.timeRange = CMTimeRange(start: startTime, duration: rangeDuration)
            }
        }
        let totalSeconds = max(rangeDuration.seconds, 0.001)

        // Metadata (title, date, location) unless the person chose to strip it.
        if !spec.stripMetadata && wantsVideo {
            let items = ((try? await asset.load(.commonMetadata)) ?? []).filter { $0.identifier != nil && $0.value != nil }
            if !items.isEmpty { writer.metadata = items }
        }

        var pumps: [(AVAssetWriterInput, AVAssetReaderOutput, Bool)] = []   // input, output, isVideo

        if wantsVideo, let track = videoTracks.first {
            let (output, input) = try await makeVideoPath(job: job, track: track, asset: asset, assetDuration: assetDuration)
            guard reader.canAdd(output) else { throw ConversionError.engineFailed("Could not read the video track.") }
            reader.add(output)
            guard writer.canAdd(input) else { throw ConversionError.engineFailed("Could not write the video track.") }
            writer.add(input)
            pumps.append((input, output, true))
        }

        if wantsAudio, let track = audioTracks.first {
            let (output, input) = try await makeAudioPath(job: job, track: track)
            guard reader.canAdd(output) else { throw ConversionError.engineFailed("Could not read the audio track.") }
            reader.add(output)
            guard writer.canAdd(input) else { throw ConversionError.engineFailed("Could not write the audio track.") }
            writer.add(input)
            pumps.append((input, output, false))
        }

        guard !pumps.isEmpty else { throw ConversionError.noAudioTrack }
        guard reader.startReading() else {
            throw ConversionError.unreadable(reader.error?.localizedDescription ?? "reading failed")
        }
        guard writer.startWriting() else {
            throw ConversionError.engineFailed(writer.error?.localizedDescription ?? "writing failed")
        }
        writer.startSession(atSourceTime: startTime)

        let flag = CancelFlag()
        let progressBox = ProgressBox()
        let startedAt = Date()
        let startSeconds = startTime.seconds

        let hasVideoPump = pumps.contains { $0.2 }
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for (input, output, isVideo) in pumps {
                    group.addTask {
                        await Self.pump(input: input, output: output, flag: flag) { time in
                            if isVideo == hasVideoPump {
                                let done = max(0, time.seconds - startSeconds) / totalSeconds
                                if progressBox.update(min(1, done), isVideo: isVideo) {
                                    let elapsed = Date().timeIntervalSince(startedAt)
                                    let speed = elapsed > 0.5 ? (done * totalSeconds) / elapsed : nil
                                    progress(TranscodeProgress(fraction: min(0.99, done), speed: speed))
                                }
                            }
                        }
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }

        if flag.isCancelled || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: job.output)
            throw ConversionError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: job.output)
            throw Self.map(reader.error)
        }
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: job.output)
            throw Self.map(writer.error)
        }
        progress(TranscodeProgress(fraction: 1, speed: nil))
    }

    static func map(_ error: Error?) -> ConversionError {
        guard let error else { return .engineFailed("") }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteOutOfSpaceError) { return .diskFull }
        if ns.domain == AVFoundationErrorDomain && ns.code == AVError.diskFull.rawValue { return .diskFull }
        if ns.domain == AVFoundationErrorDomain && ns.code == AVError.fileFormatNotRecognized.rawValue { return .unreadable("format not recognised") }
        if ns.domain == AVFoundationErrorDomain && ns.code == AVError.contentIsProtected.rawValue { return .drmProtected }
        if ns.domain == AVFoundationErrorDomain && ns.code == AVError.decoderNotFound.rawValue { return .unreadable("no decoder") }
        return .engineFailed(ns.localizedDescription)
    }

    /// Copies sample buffers from `output` into `input` on a private queue until the input ends, the writer refuses, or the job is cancelled.
    private static func pump(input: AVAssetWriterInput, output: AVAssetReaderOutput, flag: CancelFlag, onTime: @escaping (CMTime) -> Void) async {
        let queue = DispatchQueue(label: "app.fluxa.pump.\(UUID().uuidString)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if flag.isCancelled {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    if !input.append(sample) {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onTime(time)
                }
            }
        }
    }

    // MARK: Video path

    private func makeVideoPath(job: TranscodeJob, track: AVAssetTrack, asset: AVURLAsset, assetDuration: CMTime) async throws -> (AVAssetReaderOutput, AVAssetWriterInput) {
        let spec = job.spec
        let descriptions = try await track.load(.formatDescriptions)
        let transform = try await track.load(.preferredTransform)

        if job.plan.copyVideo {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let hint = descriptions.first
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            return (output, input)
        }

        let naturalSize = try await track.load(.naturalSize)
        let nominalFPS = Double(try await track.load(.nominalFrameRate))
        let sourceFPS = nominalFPS > 0 ? nominalFPS : 30
        let fps = min(spec.fps ?? sourceFPS, sourceFPS)

        // Build the full transform: stored rotation, then the person's rotation and flip, then scale.
        var t = transform
        if spec.rotation != .none {
            t = t.concatenating(CGAffineTransform(rotationAngle: CGFloat(Double(spec.rotation.rawValue) * .pi / 180)))
        }
        if spec.flipHorizontal {
            t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1))
        }
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(t)
        t = t.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let displayW = Int(abs(bounds.width).rounded()), displayH = Int(abs(bounds.height).rounded())
        let out = BitrateEstimator.outputSize(sourceWidth: displayW, sourceHeight: displayH, resolution: spec.resolution)
        t = t.concatenating(CGAffineTransform(scaleX: CGFloat(out.width) / max(abs(bounds.width), 1), y: CGFloat(out.height) / max(abs(bounds.height), 1)))

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: out.width, height: out.height)
        if fps >= sourceFPS - 0.01, let minDuration = try? await track.load(.minFrameDuration), minDuration.isValid, minDuration.seconds > 0 {
            composition.frameDuration = minDuration
        } else {
            composition.frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: assetDuration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        // Standard colour (BT.709): HDR sources are tone mapped by the system.
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: readerSettings)
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false

        let codec = job.plan.videoCodec ?? spec.resolvedVideoCodec ?? .h264
        let kbps = spec.videoBitrateKbps ?? BitrateEstimator.videoKbps(codec: codec, width: out.width, height: out.height, fps: fps, quality: spec.quality)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: kbps * 1000,
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            AVVideoMaxKeyFrameIntervalKey: max(1, Int((fps * 2).rounded())),
            AVVideoAllowFrameReorderingKey: true
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let settings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: out.width,
            AVVideoHeightKey: out.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return (output, input)
    }

    // MARK: Audio path

    private func makeAudioPath(job: TranscodeJob, track: AVAssetTrack) async throws -> (AVAssetReaderOutput, AVAssetWriterInput) {
        let spec = job.spec
        let descriptions = try await track.load(.formatDescriptions)

        if job.plan.copyAudio {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: descriptions.first)
            input.expectsMediaDataInRealTime = false
            return (output, input)
        }

        var sourceRate = 44100
        var sourceChannels = 2
        if let fd = descriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            sourceRate = Int(asbd.mSampleRate)
            sourceChannels = Int(asbd.mChannelsPerFrame)
        }
        let rate = spec.audioSampleRate ?? (sourceRate > 0 ? min(sourceRate, 48000) : 44100)
        let channels = max(1, min(sourceChannels, 2))
        let codec = job.plan.audioCodec ?? spec.resolvedAudioCodec ?? .aac
        let bigEndian = spec.format == .aiff

        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: readerSettings)
        output.alwaysCopiesSampleData = false

        var writerSettings: [String: Any]
        switch codec {
        case .aac:
            writerSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: (spec.audioBitrateKbps ?? AudioCodec.aac.defaultBitrate) * 1000
            ]
        case .alac:
            writerSettings = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: 16
            ]
        case .pcm:
            writerSettings = pcm
        default:
            throw ConversionError.unsupportedCombination("\(codec.displayName) needs the extended engine.")
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        input.expectsMediaDataInRealTime = false
        return (output, input)
    }

    // MARK: Animated images (GIF, APNG)

    private func runAnimatedImage(_ job: TranscodeJob, progress: @escaping @Sendable (TranscodeProgress) -> Void) async throws {
        let spec = job.spec
        let asset = AVURLAsset(url: job.source)
        let fullDuration = try await asset.load(.duration).seconds
        var start = 0.0
        var duration = fullDuration
        if let trim = spec.trim {
            start = max(0, trim.lowerBound)
            duration = max(0.1, min(trim.upperBound, fullDuration) - start)
        }
        let options = spec.gif
        let fps = max(3, min(options.fps, 450 / max(duration, 1)))
        let frameCount = max(1, Int((duration * fps).rounded(.down)))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maxWidth, height: options.maxWidth)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let type = spec.format == .gif ? UTType.gif.identifier : UTType.png.identifier
        guard let destination = CGImageDestinationCreateWithURL(job.output as CFURL, type as CFString, frameCount, nil) else {
            throw ConversionError.engineFailed("Could not create the image file.")
        }
        let delay = 1.0 / fps
        if spec.format == .gif {
            let fileProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: options.loops ? 0 : 1]]
            CGImageDestinationSetProperties(destination, fileProps as CFDictionary)
        } else {
            let fileProps = [kCGImagePropertyPNGDictionary as String: [kCGImagePropertyAPNGLoopCount as String: options.loops ? 0 : 1]]
            CGImageDestinationSetProperties(destination, fileProps as CFDictionary)
        }

        for index in 0..<frameCount {
            try Task.checkCancellation()
            let time = CMTime(seconds: start + Double(index) / fps, preferredTimescale: 600)
            let image: CGImage
            do {
                image = try await generator.image(at: time).image
            } catch {
                if Task.isCancelled { throw ConversionError.cancelled }
                if index > 0 { break }   // the last frames of some files can't be read: keep what we have
                throw Self.map(error)
            }
            let frameProps: [String: Any]
            if spec.format == .gif {
                frameProps = [kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delay
                ]]
            } else {
                frameProps = [kCGImagePropertyPNGDictionary as String: [
                    kCGImagePropertyAPNGDelayTime as String: delay,
                    kCGImagePropertyAPNGUnclampedDelayTime as String: delay
                ]]
            }
            CGImageDestinationAddImage(destination, image, frameProps as CFDictionary)
            progress(TranscodeProgress(fraction: min(0.95, Double(index + 1) / Double(frameCount) * 0.95), speed: nil))
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: job.output)
            throw ConversionError.cancelled
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: job.output)
            throw ConversionError.engineFailed("Could not finish the image file.")
        }
        progress(TranscodeProgress(fraction: 1, speed: nil))
    }
}

/// Keeps the progress shown to the person moving forward only, and ignores updates from the second stream.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    private(set) var videoStarted = false

    /// Returns true when the value moved forward by at least half a percent.
    func update(_ value: Double, isVideo: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isVideo { videoStarted = true }
        if value >= last + 0.005 || value >= 1 {
            last = max(last, value)
            return true
        }
        return false
    }
}
