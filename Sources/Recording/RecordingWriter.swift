//
//  RecordingWriter.swift
//  Capture + — crash-safe recording sink
//
//  Writes one capture stream's sample buffers into one .mp4 using our own
//  AVAssetWriter, replacing macOS 15's `SCRecordingOutput` convenience API.
//
//  WHY NOT SCRecordingOutput: it is a thin shim over ReplayKit, whose internal
//  writer reports `RPRecordingErrorFailedToProcessFirstSample` (-5822, surfaced as
//  "Failed due to failure to process first sample buffer") ONLY at stopCapture().
//  A recording can therefore appear to run for an hour while writing nothing. It
//  also exposes no fragment interval, so an interrupted file is unplayable, and it
//  gives no frame-level visibility. Every shipping open-source recorder
//  (QuickRecorder, Kap/Aperture, Azayaka by default) writes its own AVAssetWriter
//  for these reasons.
//
//  CRASH SAFETY: `movieFragmentInterval` makes the file playable up to the last
//  flushed fragment if the app or the Mac dies mid-recording. AVFoundation
//  defragments on a clean `finishWriting()`, so a normal recording is an ordinary
//  file with no downside. (AVAssetWriter.h, macOS 26.5 SDK.)
//

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Errors raised while writing a recording to disk.
enum RecordingWriterError: LocalizedError {
    /// Not one usable video frame arrived for the whole session.
    case noFramesWritten
    /// AVAssetWriter refused the configured video input (codec/dimensions).
    case cannotConfigureVideo
    /// The writer ended in a failed state.
    case writerFailed(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .noFramesWritten:
            return "No video frames were captured. The recording was empty."
        case .cannotConfigureVideo:
            return "This Mac couldn't encode the recording at the requested size or format."
        case .writerFailed(let underlying):
            return underlying.map { "Writing the recording failed: \($0.localizedDescription)" }
                ?? "Writing the recording failed."
        }
    }
}

/// A single output file. Thread-safe: sample buffers arrive on ScreenCaptureKit's
/// per-output queues, and every mutation happens under `lock`.
final class RecordingWriter: NSObject, @unchecked Sendable {

    /// Where this recording is written.
    let url: URL

    /// Complete video frames appended so far. The startup watchdog reads this to tell
    /// a dead capture from a merely idle screen — something the ReplayKit-backed API
    /// could never expose.
    var frameCount: Int { lock.withLock { _frameCount } }

    /// True once the first usable frame opened the writing session.
    var hasStarted: Bool { lock.withLock { started } }

    private let writer: AVAssetWriter
    private let codec: AVVideoCodecType
    private let fps: Int
    /// Software gain multiplier for microphone samples (1 == unchanged). Applied
    /// before the append, with clamping at digital full scale.
    private let micGain: Float
    private let lock = NSLock()

    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?

    private var started = false
    private var finished = false
    private var _frameCount = 0
    private var lastVideoPTS = CMTime.invalid
    private var lastAudioPTS = CMTime.invalid
    private var lastMicPTS = CMTime.invalid

    /// - Parameters:
    ///   - url: destination .mp4 (removed first if it exists).
    ///   - codec: video codec; falls back to H.264 if this Mac won't take it.
    ///   - fps: frame rate the stream is configured for, used to size the bitrate.
    ///   - captureSystemAudio / captureMicrophone: whether to build those tracks.
    init(url: URL,
         codec: AVVideoCodecType,
         fps: Int,
         captureSystemAudio: Bool,
         captureMicrophone: Bool,
         micGain: Float = 1) throws {
        self.url = url
        self.codec = codec
        self.fps = max(1, fps)
        self.micGain = micGain

        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // THE crash-safety setting: flush a playable index every few seconds so an
        // interrupted file opens and plays up to the last flush. Must be set before
        // startWriting(). A short first interval means even a crash in the opening
        // seconds still yields a playable file.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        super.init()

        // Audio inputs must exist BEFORE startWriting(); the video input is added
        // later from the first frame's real dimensions, so they're all in place by the
        // time writing begins.
        if captureSystemAudio { audioInput = makeAudioInput() }
        if captureMicrophone { micInput = makeAudioInput() }
    }

    // MARK: - Sample handling

    /// Append a screen frame. The first usable frame creates the video input from the
    /// buffer's OWN dimensions and opens the session — so a mismatch between what we
    /// asked ScreenCaptureKit for and what it actually delivers can't wedge the writer.
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer) else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        if !started {
            guard let formatDescription = sampleBuffer.formatDescription else { return }
            let dimensions = formatDescription.dimensions
            guard startSession(width: Int(dimensions.width),
                               height: Int(dimensions.height),
                               at: sampleBuffer.presentationTimeStamp) else { return }
        }

        guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
        // A single out-of-order timestamp permanently fails an AVAssetWriter, so drop
        // rather than append non-monotonic frames.
        let pts = sampleBuffer.presentationTimeStamp
        if lastVideoPTS.isValid, pts <= lastVideoPTS { return }

        if videoInput.append(sampleBuffer) {
            lastVideoPTS = pts
            _frameCount += 1
        }
    }

    /// Append system audio. Dropped until video has opened the session, so the audio
    /// timeline always starts at or after the video's.
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        append(sampleBuffer, to: audioInput, last: &lastAudioPTS)
    }

    /// Append microphone audio. Kept on its OWN track — mixing mic and system audio
    /// into one track is the documented cause of corrupt MP4s with this pipeline.
    /// The user's mic-volume setting is applied here as a software gain.
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        if micGain != 1 { Self.applyGain(micGain, to: sampleBuffer) }
        append(sampleBuffer, to: micInput, last: &lastMicPTS)
    }

    /// Scale Float32 PCM samples in place by `gain`, clamped to [-1, 1] so boosting
    /// can't wrap past digital full scale. LPCM sample bytes live contiguously in the
    /// buffer's block, so scaling every float covers interleaved and planar layouts
    /// alike. Non-Float32 or non-contiguous buffers are left untouched (appended at
    /// their original level) rather than risking corruption.
    ///
    /// Internal (not private) so the self-test harness can verify the math directly.
    static func applyGain(_ gain: Float, to sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription,
              let asbd = format.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == noErr,
              let raw = pointer,
              totalLength >= MemoryLayout<Float32>.size,
              CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: totalLength)
        else { return }

        let samples = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: Float32.self)
        for index in 0..<(totalLength / MemoryLayout<Float32>.size) {
            samples[index] = max(-1, min(1, samples[index] * gain))
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer,
                        to input: AVAssetWriterInput?,
                        last: inout CMTime) {
        guard sampleBuffer.isValid else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finished, started, let input, input.isReadyForMoreMediaData else { return }
        let pts = sampleBuffer.presentationTimeStamp
        if last.isValid, pts <= last { return }
        if input.append(sampleBuffer) { last = pts }
    }

    // MARK: - Lifecycle

    /// Build the video input at the frame's real size and begin writing. Caller holds
    /// `lock`. Returns false if the writer refuses the configuration.
    private func startSession(width: Int, height: Int, at time: CMTime) -> Bool {
        // Even dimensions only — H.264/HEVC chroma subsampling requires it.
        let w = max(2, width - (width % 2))
        let h = max(2, height - (height % 2))

        var input = makeVideoInput(width: w, height: h, codec: codec)
        if !writer.canAdd(input) {
            // This Mac may not offer the requested codec (varies by machine, notably
            // HEVC on Intel). Fall back rather than fail the recording.
            input = makeVideoInput(width: w, height: h, codec: .h264)
            guard writer.canAdd(input) else { return false }
        }
        writer.add(input)
        videoInput = input

        for audio in [audioInput, micInput].compactMap({ $0 }) where writer.canAdd(audio) {
            writer.add(audio)
        }

        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)
        started = true
        return true
    }

    /// Finish the file and return its URL. Throws if nothing was ever captured or the
    /// writer failed. Must not be called on the main thread — finalizing a long
    /// recording can take a while, and interrupting it is what corrupts files.
    func finish() async throws -> URL {
        lock.lock()
        let didStart = started
        let alreadyFinished = finished
        finished = true
        let inputs = [videoInput, audioInput, micInput].compactMap { $0 }
        lock.unlock()

        guard !alreadyFinished else { return url }

        guard didStart else {
            writer.cancelWriting()
            throw RecordingWriterError.noFramesWritten
        }

        for input in inputs { input.markAsFinished() }
        await writer.finishWriting()

        if writer.status == .failed {
            throw RecordingWriterError.writerFailed(underlying: writer.error)
        }
        return url
    }

    // MARK: - Inputs

    private func makeVideoInput(width: Int, height: Int, codec: AVVideoCodecType)
        -> AVAssetWriterInput {
        // ~0.05 bits per pixel per frame for HEVC (double for H.264), clamped to a sane
        // range so 5K displays don't produce absurd files and small ones aren't mushy.
        let bitsPerPixel = codec == .h264 ? 0.10 : 0.05
        let raw = Double(width * height * fps) * bitsPerPixel
        let bitRate = Int(min(max(raw, 2_000_000), 120_000_000))

        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// ScreenCaptureKit delivers idle/blank/suspended frames that carry no new content;
    /// only `.complete` frames are real video.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
