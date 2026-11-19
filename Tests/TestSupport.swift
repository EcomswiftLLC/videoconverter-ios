import XCTest
import AVFoundation
import CoreMedia
@testable import Fluxa

enum Samples {
    static func video(_ codec: VideoCodec?, name: String = "x", width: Int = 1920, height: Int = 1080, fps: Double = 30, rotation: Int = 0, hdr: Bool = false) -> VideoStreamInfo {
        VideoStreamInfo(codecName: codec?.rawValue ?? name, codec: codec, width: width, height: height, fps: fps, bitrate: 4_000_000, rotation: rotation, isHDR: hdr)
    }

    static func audio(_ codec: Fluxa.AudioCodec?, name: String = "x") -> AudioStreamInfo {
        AudioStreamInfo(codecName: codec?.rawValue ?? name, codec: codec, sampleRate: 44100, channels: 2, bitrate: 128_000)
    }

    static func probe(video: VideoCodec?, audio: Fluxa.AudioCodec?, native: Bool, container: String = "mp4", duration: Double = 60, hdr: Bool = false, protected: Bool = false) -> MediaProbe {
        MediaProbe(
            containerName: container, duration: duration, fileSize: 50_000_000, bitrate: 4_500_000,
            video: video == nil ? nil : Samples.video(video, hdr: hdr),
            audio: audio == nil ? [] : [Samples.audio(audio)],
            isProtected: protected, nativeReadable: native
        )
    }

    /// A representative source for each family of input files.
    static let sources: [(String, MediaProbe)] = [
        ("MP4 H.264 AAC", probe(video: .h264, audio: .aac, native: true)),
        ("MOV HEVC AAC", probe(video: .hevc, audio: .aac, native: true, container: "mov")),
        ("MOV ProRes PCM", probe(video: .prores, audio: .pcm, native: true, container: "mov")),
        ("3GP H.264 AAC", probe(video: .h264, audio: .aac, native: true, container: "3gp")),
        ("MKV H.264 AAC", probe(video: .h264, audio: .aac, native: false, container: "matroska,webm")),
        ("MKV HEVC AC3", probe(video: .hevc, audio: .ac3, native: false, container: "matroska,webm")),
        ("WebM VP9 Opus", probe(video: .vp9, audio: .opus, native: false, container: "matroska,webm")),
        ("AVI MPEG-4 MP3", probe(video: .mpeg4, audio: .mp3, native: false, container: "avi")),
        ("WMV WMV2 WMA", probe(video: .wmv2, audio: .wmav2, native: false, container: "asf")),
        ("FLV H.264 AAC", probe(video: .h264, audio: .aac, native: false, container: "flv")),
        ("MPG MPEG-2 AC3", probe(video: .mpeg2, audio: .ac3, native: false, container: "mpeg")),
        ("TS H.264 AAC", probe(video: .h264, audio: .aac, native: false, container: "mpegts")),
        ("OGV Theora Vorbis", probe(video: .theora, audio: .vorbis, native: false, container: "ogg")),
        ("MP4 H.264 no audio", probe(video: .h264, audio: nil, native: true)),
        ("Unknown codec", probe(video: nil, audio: .aac, native: false, container: "avi").with(video: Samples.video(nil, name: "indeo5"))),
        ("MP3", probe(video: nil, audio: .mp3, native: true, container: "mp3")),
        ("M4A AAC", probe(video: nil, audio: .aac, native: true, container: "m4a")),
        ("WAV PCM", probe(video: nil, audio: .pcm, native: true, container: "wav")),
        ("FLAC", probe(video: nil, audio: .flac, native: false, container: "flac")),
        ("OGG Vorbis", probe(video: nil, audio: .vorbis, native: false, container: "ogg")),
        ("Opus", probe(video: nil, audio: .opus, native: false, container: "ogg"))
    ]
}

extension MediaProbe {
    func with(video: VideoStreamInfo?) -> MediaProbe {
        var copy = self
        copy.video = video
        return copy
    }
}

// MARK: - Generated clips (no assets needed)

enum TestClips {
    /// Writes a small H.264 + AAC MP4 with a moving box and a tone, entirely from code.
    static func makeMP4(seconds: Double = 3, width: Int = 640, height: Int = 360, fps: Int = 30, audio: Bool = true, name: String = "clip.mp4") async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fx-test-\(UUID().uuidString)-\(name)")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
            ])
            writer.add(input)
            audioInput = input
        }
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        let rate = 44100
        let totalSamples = Int(seconds * Double(rate))
        var audioWritten = 0

        func waitReady(_ input: AVAssetWriterInput) async throws {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
                waited += 1
                if waited > 5_000 { throw NSError(domain: "TestClips", code: 1, userInfo: [NSLocalizedDescriptionKey: "writer stalled: \(String(describing: writer.error))"]) }
            }
        }

        for index in 0..<frames {
            try await waitReady(videoInput)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            if let pixels = buffer {
                CVPixelBufferLockBaseAddress(pixels, [])
                if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    context.setFillColor(CGColor(red: 0.05, green: 0.1, blue: 0.2, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    context.setFillColor(CGColor(red: 0.5, green: 0.9, blue: 0.8, alpha: 1))
                    let x = CGFloat(index % max(width - 80, 1))
                    context.fill(CGRect(x: x, y: CGFloat(height) / 2 - 40, width: 80, height: 80))
                }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
            }
            // Keep the audio level with the video: the writer interleaves, so one input cannot run far ahead of the other.
            if let audioInput {
                let target = min(totalSamples, Int(Double(index + 1) / Double(fps) * Double(rate)))
                while audioWritten < target {
                    try await waitReady(audioInput)
                    let count = min(4096, target - audioWritten)
                    var samples = [Int16](repeating: 0, count: count)
                    for i in 0..<count {
                        samples[i] = Int16(sin(2 * Double.pi * 440 * Double(audioWritten + i) / Double(rate)) * 9000)
                    }
                    if let sample = audioSampleBuffer(samples, rate: Double(rate), startFrame: Int64(audioWritten)) { audioInput.append(sample) }
                    audioWritten += count
                }
            }
        }
        videoInput.markAsFinished()
        if let audioInput {
            while audioWritten < totalSamples {
                try await waitReady(audioInput)
                let count = min(4096, totalSamples - audioWritten)
                var samples = [Int16](repeating: 0, count: count)
                for i in 0..<count {
                    samples[i] = Int16(sin(2 * Double.pi * 440 * Double(audioWritten + i) / Double(rate)) * 9000)
                }
                if let sample = audioSampleBuffer(samples, rate: Double(rate), startFrame: Int64(audioWritten)) { audioInput.append(sample) }
                audioWritten += count
            }
            audioInput.markAsFinished()
        }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "Could not build the test clip: \(String(describing: writer.error))")
        return url
    }

    static func audioSampleBuffer(_ samples: [Int16], rate: Double, startFrame: Int64) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { return nil }
        let length = samples.count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
        let status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard status == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: samples.count, presentationTimeStamp: CMTime(value: startFrame, timescale: CMTimeScale(rate)), packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
