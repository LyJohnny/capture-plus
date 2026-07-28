//
//  RecordingEngine.swift
//  Capture + — Feature 3: Screen recording
//
//  ScreenCaptureKit record-to-file engine (macOS 15+ SCRecordingOutput API).
//  SCKit writes screen + system audio + optional mic into ONE .mp4 itself —
//  no AVAssetWriter, no BlackHole, no audio-device juggling.
//
//  API signatures below were verified against the macOS 26.5 SDK headers
//  (ScreenCaptureKit.framework: SCRecordingOutput.h, SCStream.h,
//  SCShareableContent.h, SCError.h) and WWDC24 session 10088.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics

/// Errors surfaced by the recording engine with user-meaningful messages.
public enum RecordingError: LocalizedError {
    /// Screen-recording TCC permission is missing / was declined by the user.
    case screenRecordingPermissionDenied
    /// No shareable display was found (nothing to capture).
    case noDisplayAvailable
    /// startRecording was called while a capture is already running.
    case alreadyRecording
    /// stopRecording was called with no active capture.
    case notRecording
    /// The output URL count didn't match the recording target (e.g. two
    /// displays but one URL). Carries the counts for context.
    case outputURLCountMismatch(expected: Int, got: Int)
    /// The capture started but nothing is being written to disk — e.g. SCKit failed
    /// on the first sample buffer. Detected seconds after start so the user isn't told
    /// at stop time that a long recording was never captured.
    case notCapturing
    /// SCKit reported it could not add the recording output to the stream.
    case couldNotStartRecordingOutput(underlying: Error?)
    /// Any other SCKit/stream failure, wrapped for context.
    case streamFailure(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return "Capture + doesn't have Screen Recording permission. Enable it in "
                + "System Settings → Privacy & Security → Screen & System Audio Recording, "
                + "then try again."
        case .noDisplayAvailable:
            return "No display is available to record."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "There is no active recording to stop."
        case .notCapturing:
            return "This recording isn't capturing anything — macOS didn't start "
                + "writing video to disk. Stop it and start a new recording."
        case .outputURLCountMismatch(let expected, let got):
            return "Expected \(expected) output file(s) for this recording target "
                + "but got \(got)."
        case .couldNotStartRecordingOutput(let underlying):
            if let underlying {
                return "Couldn't start recording: \(underlying.localizedDescription)"
            }
            return "Couldn't start recording output."
        case .streamFailure(let underlying):
            return "Recording failed: \(underlying.localizedDescription)"
        }
    }
}

/// What to capture in a recording session.
///
/// - `display`: one whole display → one file.
/// - `window`: one specific window (desktop-independent) → one file, sized to
///   the window's frame in pixels.
/// - `displays`: several displays at once → one file PER display (N monitors →
///   N files), each written from its own `SCStream`.
public enum RecordingTarget {
    case display(SCDisplay)
    case window(SCWindow)
    case displays([SCDisplay])
}

/// Screen-recording engine built on `SCStream` + `SCRecordingOutput`.
///
/// Typical integrator flow:
/// ```
/// let engine = RecordingEngine()
/// engine.onFinish = { result in /* hand URLs to trimmer, or show error */ }
/// let displays = try await engine.availableDisplays()
/// let mics = engine.availableMicrophones()
/// try await engine.startRecording(target: .display(displays[0]),
///                                 captureSystemAudio: true,
///                                 includeMicrophone: true,
///                                 microphoneDeviceID: mics.first?.uniqueID,
///                                 outputURLs: [url])
/// // …later…
/// let fileURLs = try await engine.stopRecording()
/// ```
///
/// Threading: methods are async and safe to call from the main actor.
/// The `onFinish` / `onError` closures are always delivered on the main queue.
public final class RecordingEngine: NSObject, @unchecked Sendable {

    // MARK: - Public state & callbacks

    /// True while any stream is active — i.e. between a successful
    /// `startRecording` and every stream finishing (via `stopRecording`, a
    /// delegate finish, or a failure).
    public private(set) var isRecording: Bool = false

    /// Called once when a recording session finishes — either successfully
    /// (with every output file URL) or with an error. Always delivered on the
    /// main queue. For a single-file recording the array has one element; for a
    /// multi-display recording it has one URL per display, in the same order as
    /// the `outputURLs` passed to `startRecording`. Fires on normal stop, on an
    /// unexpected stream stop, and on failure.
    public var onFinish: ((Result<[URL], Error>) -> Void)?

    /// Called for non-terminal / terminal errors as they are observed from the
    /// SCKit delegates. Always delivered on the main queue. `onFinish` also
    /// fires with the failure for terminal errors.
    public var onError: ((Error) -> Void)?

    /// Called (on the main queue) a few seconds after a recording starts if nothing is
    /// being written to disk — i.e. the capture is dead on arrival. This exists so a
    /// failure SCKit only reports at `stopCapture()` (such as "failure to process first
    /// sample buffer") surfaces in seconds instead of costing the user an hour.
    public var onEarlyFailure: ((RecordingError) -> Void)?

    /// Output URLs from the most recent session. Unlike `outputURLs` — cleared when a
    /// session tears down — this survives failure, so a failed stop can still hand the
    /// partially written file back to the user instead of orphaning it.
    public private(set) var lastOutputURLs: [URL] = []

    /// Files from the last session that actually contain data. Used to salvage a
    /// recording when finishing failed: whatever was captured is still on disk.
    public func salvageableFiles() -> [URL] {
        lastOutputURLs.filter { Self.fileSize(of: $0) > 0 }
    }

    /// Bytes on disk for `url`, or 0 when it's missing.
    static func fileSize(of url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    // MARK: - Private state

    /// Active streams (one per display, or a single stream for display/window).
    private var streams: [SCStream] = []
    /// Crash-safe file writers, parallel to `streams`.
    private var writers: [RecordingWriter] = []
    /// Per-stream sample-buffer routers, retained for the life of the session
    /// (`addStreamOutput` does not retain its handler).
    private var outputAdapters: [StreamOutputAdapter] = []
    /// Destination URLs, parallel to `streams`.
    private var outputURLs: [URL] = []
    /// Count of outputs that have reported `didFinishRecording`.
    private var finishedOutputCount: Int = 0

    /// Guards against double-delivery of the terminal result.
    private var didFinish: Bool = false

    /// True while `stopRecording()` owns the teardown, so an external-stop delegate
    /// callback arriving mid-stop doesn't finalize a second time.
    private var isStopping = false

    /// One-shot timer verifying the capture is actually writing to disk shortly after
    /// it starts. See `onEarlyFailure`.
    private var startupCheckTimer: Timer?

    /// How long to wait before checking that real frames are being captured. Generous
    /// enough that normal encoder start-up latency can't trigger a false alarm.
    private static let startupCheckDelay: TimeInterval = 8

    /// Queues sample buffers arrive on. Separate per media type, per Apple's sample
    /// code, at a high QoS so frames aren't dropped under load.
    private let videoQueue = DispatchQueue(label: "com.captureplus.capture.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.captureplus.capture.audio", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "com.captureplus.capture.mic", qos: .userInitiated)

    // MARK: - Init

    public override init() {
        super.init()
    }

    // MARK: - Discovery

    /// The displays available to capture. Throws
    /// `RecordingError.screenRecordingPermissionDenied` when TCC has not been
    /// granted (SCKit returns `SCStreamErrorUserDeclined` in that case).
    public func availableDisplays() async throws -> [SCDisplay] {
        do {
            // Verified: `getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:`
            // bridges to this async Swift name.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return content.displays
        } catch {
            throw Self.mapPermissionError(error)
        }
    }

    /// On-screen windows worth offering as a capture target: normal
    /// application windows (layer 0) that are on screen, have a non-zero size,
    /// and carry a title or an owning app. Capture +'s own windows and desktop /
    /// system chrome are filtered out.
    ///
    /// Ordering follows `SCShareableContent`, which lists windows front-to-back,
    /// so the returned array is frontmost-first.
    // VERIFY: SCShareableContent.windows front-to-back ordering is documented
    // behavior but not header-guaranteed; confirm at runtime if strict
    // frontmost-first matters.
    public func availableWindows() async throws -> [SCWindow] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw Self.mapPermissionError(error)
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return content.windows.filter { window in
            // On screen only.
            guard window.isOnScreen else { return false }
            // Layer 0 == normal app windows. Non-zero layers are the menu bar,
            // Dock, wallpaper, notification/overlay chrome, etc.
            guard window.windowLayer == 0 else { return false }
            // Non-zero size.
            guard window.frame.width >= 1, window.frame.height >= 1 else { return false }

            // Exclude Capture +'s own windows.
            if let app = window.owningApplication {
                if let ownBundleID, app.bundleIdentifier == ownBundleID { return false }
                if app.processID == ownPID { return false }
            }

            // Must have a title or an owning app to be worth showing.
            let hasTitle = !(window.title ?? "").isEmpty
            return hasTitle || window.owningApplication != nil
        }
    }

    /// Microphones available for capture: built-in plus any external audio
    /// input devices. Returns `uniqueID`s the integrator can pass back into
    /// `startRecording(microphoneDeviceID:)`.
    public func availableMicrophones() -> [AVCaptureDevice] {
        Self.availableMicrophones()
    }

    /// Static so UI (the Settings mic picker) can enumerate without an engine.
    /// Listing devices does not require microphone permission; capturing does.
    public static func availableMicrophones() -> [AVCaptureDevice] {
        // `.microphone` (macOS 14+) supersedes the deprecated `.builtInMicrophone`;
        // `.external` picks up USB / interface / aggregate input devices.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices
    }

    // MARK: - Recording

    /// Start recording `target` to `outputURLs`.
    ///
    /// - Parameters:
    ///   - target: what to capture — a whole display, a specific window, or
    ///     several displays at once (one file per display).
    ///   - captureSystemAudio: when true, records the system/app audio into the
    ///     file(s). For a multi-display target, system audio is captured into
    ///     every file so each is self-contained.
    ///   - includeMicrophone: when true, mixes the microphone in alongside any
    ///     system audio. Independent of `captureSystemAudio` — you can record
    ///     mic-only, system-only, both, or (if both are false) a silent video.
    ///     For a multi-display target the mic is mixed into every file.
    ///   - microphoneDeviceID: the `AVCaptureDevice.uniqueID` to record from,
    ///     or nil for the system-default input. Ignored when
    ///     `includeMicrophone` is false.
    ///   - codec: video codec for the output. Defaults to HEVC.
    ///   - outputURLs: destination file(s). Its count must match the target:
    ///     1 for `.display` / `.window`, and `displays.count` for `.displays`
    ///     (index i writes displays[i]). Parent directories must exist and any
    ///     existing file at each URL should be removed by the caller first.
    public func startRecording(
        target: RecordingTarget,
        captureSystemAudio: Bool,
        includeMicrophone: Bool,
        microphoneDeviceID: String?,
        microphoneGain: Double = 1.0,
        codec: AVVideoCodecType = .hevc,
        maxHeight: Int = 0,
        outputURLs: [URL]
    ) async throws {
        guard !isRecording else { throw RecordingError.alreadyRecording }

        // Resolve the target into one (filter, pixelWidth, pixelHeight) per
        // stream, and validate the URL count.
        let nativeSpecs = try Self.resolveFilters(for: target)
        guard nativeSpecs.count == outputURLs.count else {
            throw RecordingError.outputURLCountMismatch(
                expected: nativeSpecs.count,
                got: outputURLs.count
            )
        }

        // Optionally scale each stream down to a target height (0 == native),
        // preserving aspect ratio and keeping even dimensions for the encoder.
        let specs: [FilterSpec] = nativeSpecs.map { spec in
            guard maxHeight > 0, spec.height > maxHeight else { return spec }
            let scale = Double(maxHeight) / Double(spec.height)
            var w = Int((Double(spec.width) * scale).rounded())
            var h = maxHeight
            if w % 2 != 0 { w -= 1 }
            if h % 2 != 0 { h -= 1 }
            return FilterSpec(filter: spec.filter, width: max(2, w), height: max(2, h))
        }

        // Build every stream + writer up front (nothing captures yet).
        var builtStreams: [SCStream] = []
        var builtWriters: [RecordingWriter] = []
        var builtAdapters: [StreamOutputAdapter] = []
        builtStreams.reserveCapacity(specs.count)
        builtWriters.reserveCapacity(specs.count)

        for (index, spec) in specs.enumerated() {
            let (stream, writer, adapter) = try makeStream(
                filter: spec.filter,
                pixelWidth: spec.width,
                pixelHeight: spec.height,
                captureSystemAudio: captureSystemAudio,
                includeMicrophone: includeMicrophone,
                microphoneDeviceID: microphoneDeviceID,
                microphoneGain: microphoneGain,
                codec: codec,
                outputURL: outputURLs[index]
            )
            builtStreams.append(stream)
            builtWriters.append(writer)
            builtAdapters.append(adapter)
        }

        // Reset terminal-state guards for this session.
        didFinish = false
        finishedOutputCount = 0

        // Start every stream. On any failure, roll back the ones already
        // started so the engine stays reusable.
        var startedStreams: [SCStream] = []
        for stream in builtStreams {
            do {
                try await stream.startCapture()
                startedStreams.append(stream)
            } catch {
                for started in startedStreams {
                    try? await started.stopCapture()
                }
                throw Self.mapPermissionError(error)
            }
        }

        streams = builtStreams
        writers = builtWriters
        outputAdapters = builtAdapters
        self.outputURLs = outputURLs
        // Remembered beyond teardown so a failed finish can still surface the file.
        lastOutputURLs = outputURLs
        isRecording = true

        scheduleStartupCheck()
    }

    // MARK: - Startup health check

    /// Arm the one-shot check that confirms bytes are reaching the output file(s).
    private func scheduleStartupCheck() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startupCheckTimer?.invalidate()
            let timer = Timer(timeInterval: Self.startupCheckDelay, repeats: false) { [weak self] _ in
                self?.runStartupCheck()
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.startupCheckTimer = timer
        }
    }

    /// If every output file is still empty well after start, the capture is dead on
    /// arrival — report it now rather than letting the user record for an hour into a
    /// file that will never materialize.
    private func runStartupCheck() {
        guard isRecording, !writers.isEmpty else { return }
        // Ask the writers directly how many real frames they've taken. This is far
        // better than watching file size: it distinguishes a genuinely dead capture
        // from a merely static screen (ScreenCaptureKit only emits frames on change).
        let nothingCaptured = writers.allSatisfy { $0.frameCount == 0 }
        guard nothingCaptured else { return }
        let cb = onEarlyFailure
        DispatchQueue.main.async { cb?(.notCapturing) }
    }

    /// Stop every active stream, finalize the file(s), and return their URLs.
    ///
    /// `stopCapture()` flushes and closes each file; the SCKit
    /// `recordingOutputDidFinishRecording` delegate also fires per output (which
    /// drives `onFinish`). This method returns the URLs directly for convenience.
    @discardableResult
    public func stopRecording() async throws -> [URL] {
        guard isRecording, !streams.isEmpty else {
            throw RecordingError.notRecording
        }

        // Claim teardown so a didStopWithError racing in (stopCapture can trigger it)
        // doesn't run a second finalize.
        isStopping = true
        defer { isStopping = false }

        let activeStreams = streams
        let activeWriters = writers

        // Stop capturing first; a failure here doesn't stop us finalizing the files,
        // because whatever was already written is still the user's recording.
        var stopError: Error?
        for stream in activeStreams {
            do { try await stream.stopCapture() } catch { stopError = error }
        }

        // Finalize every file. This can take a while for a long recording and must NOT
        // be interrupted — an aborted finalize is what corrupts an .mp4.
        var finished: [URL] = []
        var writeError: Error?
        for writer in activeWriters {
            do { finished.append(try await writer.finish()) } catch { writeError = error }
        }

        isRecording = false
        clearSession()

        guard !finished.isEmpty else {
            let underlying = writeError ?? stopError
            let mapped: RecordingError = (underlying as? RecordingWriterError) != nil
                ? .notCapturing
                : .streamFailure(underlying: underlying ?? RecordingWriterError.noFramesWritten)
            deliverFinish(.failure(mapped))
            throw mapped
        }

        lastOutputURLs = finished
        deliverFinish(.success(finished))
        return finished
    }

    // MARK: - Helpers

    /// A resolved capture spec: the content filter plus target pixel dimensions.
    private struct FilterSpec {
        let filter: SCContentFilter
        let width: Int
        let height: Int
    }

    /// Turn a `RecordingTarget` into one filter spec per stream.
    private static func resolveFilters(for target: RecordingTarget) throws -> [FilterSpec] {
        switch target {
        case .display(let display):
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let (w, h) = pixelDimensions(for: filter, fallback: display)
            return [FilterSpec(filter: filter, width: w, height: h)]

        case .window(let window):
            // Desktop-independent window filter isolates just this window.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let (w, h) = pixelDimensions(for: filter, fallback: window.frame)
            return [FilterSpec(filter: filter, width: w, height: h)]

        case .displays(let displays):
            guard !displays.isEmpty else { throw RecordingError.noDisplayAvailable }
            return displays.map { display in
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let (w, h) = pixelDimensions(for: filter, fallback: display)
                return FilterSpec(filter: filter, width: w, height: h)
            }
        }
    }

    /// Build a configured `SCStream` writing into our own `RecordingWriter`, with the
    /// sample-buffer outputs attached (but capture not yet started).
    private func makeStream(
        filter: SCContentFilter,
        pixelWidth: Int,
        pixelHeight: Int,
        captureSystemAudio: Bool,
        includeMicrophone: Bool,
        microphoneDeviceID: String?,
        microphoneGain: Double = 1.0,
        codec: AVVideoCodecType,
        outputURL: URL
    ) throws -> (SCStream, RecordingWriter, StreamOutputAdapter) {
        let fps = 60

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // 6 is comfortably inside SCKit's 3...8 range: deep enough to absorb encoder
        // hiccups without handing the WindowServer a lot of extra surfaces.
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true

        config.capturesAudio = captureSystemAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        // Don't record Capture +'s own output audio back into the file.
        config.excludesCurrentProcessAudio = true
        if includeMicrophone {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = microphoneDeviceID   // nil => default input
        }

        let writer = try RecordingWriter(
            url: outputURL,
            codec: codec,
            fps: fps,
            captureSystemAudio: captureSystemAudio,
            captureMicrophone: includeMicrophone,
            micGain: Float(microphoneGain))

        let adapter = StreamOutputAdapter(writer: writer)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        // Attach outputs BEFORE startCapture so no leading frames are missed.
        do {
            try stream.addStreamOutput(adapter, type: .screen, sampleHandlerQueue: videoQueue)
            if captureSystemAudio {
                try stream.addStreamOutput(adapter, type: .audio, sampleHandlerQueue: audioQueue)
            }
            if includeMicrophone {
                try stream.addStreamOutput(adapter, type: .microphone, sampleHandlerQueue: micQueue)
            }
        } catch {
            throw RecordingError.couldNotStartRecordingOutput(underlying: error)
        }

        return (stream, writer, adapter)
    }

    /// Clear all per-session stream state. `lastOutputURLs` deliberately survives so a
    /// failed finish can still salvage the partially written file.
    private func clearSession() {
        streams = []
        writers = []
        outputAdapters = []
        outputURLs = []
        DispatchQueue.main.async { [weak self] in
            self?.startupCheckTimer?.invalidate()
            self?.startupCheckTimer = nil
        }
    }

    /// Pixel dimensions for a display filter.
    ///
    /// Derived from the FILTER (`contentRect` × `pointPixelScale`) — the size
    /// ScreenCaptureKit itself will deliver — rather than from
    /// `CGDisplayCopyDisplayMode`, which reports the physical panel mode and diverges
    /// under scaled Retina modes and mirroring. Handing the encoder dimensions that
    /// disagree with the delivered frames is a known cause of a capture that produces
    /// no usable first frame. Rounded to even for H.264/HEVC chroma subsampling.
    private static func pixelDimensions(
        for filter: SCContentFilter,
        fallback display: SCDisplay
    ) -> (Int, Int) {
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        if rect.width >= 1, rect.height >= 1, scale > 0 {
            return (evenPixels(rect.width * scale), evenPixels(rect.height * scale))
        }
        // Fall back to the display mode, then to point sizes — never zero.
        if let mode = CGDisplayCopyDisplayMode(display.displayID),
           mode.pixelWidth > 0, mode.pixelHeight > 0 {
            return (evenPixels(CGFloat(mode.pixelWidth)), evenPixels(CGFloat(mode.pixelHeight)))
        }
        return (evenPixels(CGFloat(display.width)), evenPixels(CGFloat(display.height)))
    }

    /// Pixel dimensions for a window filter. `contentRect` is in points and
    /// `pointPixelScale` (macOS 14+) is the backing-store scale, so their
    /// product is the true pixel size. Falls back to the window's point frame
    /// (scale 1) if the filter reports a degenerate rect. Rounded to even so
    /// HEVC is happy with the dimensions.
    private static func pixelDimensions(
        for filter: SCContentFilter,
        fallback frame: CGRect
    ) -> (Int, Int) {
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        var wPoints = rect.width
        var hPoints = rect.height
        var pixelScale = scale > 0 ? scale : 1
        if wPoints < 1 || hPoints < 1 {
            wPoints = frame.width
            hPoints = frame.height
            pixelScale = 1
        }
        let w = Self.evenPixels(wPoints * pixelScale)
        let h = Self.evenPixels(hPoints * pixelScale)
        return (w, h)
    }

    /// Round a pixel dimension up to the nearest positive even integer.
    private static func evenPixels(_ value: CGFloat) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded % 2 == 0 ? rounded : rounded + 1
    }

    /// Map SCKit permission/decline errors to a clear engine error; pass others
    /// through wrapped as `streamFailure`.
    private static func mapPermissionError(_ error: Error) -> RecordingError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            // Raw values from SCError.h (SCStreamErrorCode). Compared as ints
            // to avoid depending on the bridged enum's exact Swift spelling.
            let userDeclined = -3801        // SCStreamErrorUserDeclined
            let missingEntitlements = -3803 // SCStreamErrorMissingEntitlements
            switch nsError.code {
            case userDeclined, missingEntitlements:
                return .screenRecordingPermissionDenied
            default:
                return .streamFailure(underlying: error)
            }
        }
        return .streamFailure(underlying: error)
    }

    /// Deliver the terminal result exactly once, on the main queue.
    private func deliverFinish(_ result: Result<[URL], Error>) {
        guard !didFinish else { return }
        didFinish = true
        let cb = onFinish
        DispatchQueue.main.async { cb?(result) }
    }

    /// Deliver a non-terminal error notification on the main queue.
    private func deliverError(_ error: Error) {
        let cb = onError
        DispatchQueue.main.async { cb?(error) }
    }
}

// MARK: - Sample-buffer routing

/// Routes one stream's sample buffers to its writer. A separate object (rather than
/// the engine itself) so each stream in a multi-display session feeds its own file
/// without any lookup on the capture queue.
final class StreamOutputAdapter: NSObject, SCStreamOutput {
    private let writer: RecordingWriter

    init(writer: RecordingWriter) {
        self.writer = writer
        super.init()
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Handled synchronously on SCKit's queue so the buffer stays valid.
        switch type {
        case .screen: writer.appendVideo(sampleBuffer)
        case .audio: writer.appendSystemAudio(sampleBuffer)
        case .microphone: writer.appendMicrophone(sampleBuffer)
        @unknown default: break
        }
    }
}

// MARK: - SCStreamDelegate

extension RecordingEngine: SCStreamDelegate {

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Fires when the stream stops from OUTSIDE our stopRecording() path. Two very
        // different cases share this callback:
        //
        //  - The user clicked the system indicator's "Stop Sharing" button
        //    (SCStreamErrorUserStopped, -3817), or the system ended the capture on
        //    lock/logout/display change (SCStreamErrorSystemStoppedStream, -3821).
        //    These are NORMAL stops: finalize and deliver success, exactly like a
        //    menu-bar stop. Treating them as failures showed a false "Recording
        //    recovered" alarm after every pill-stopped recording.
        //
        //  - A genuine mid-capture failure (permission revoked, stream died).
        //    Finalize the writers FIRST — the fragments on disk are the user's
        //    footage — then report the failure so the salvage flow can offer it.
        let nsError = error as NSError
        let intentional = nsError.domain == SCStreamErrorDomain
            && (nsError.code == Self.userStoppedCode || nsError.code == Self.systemStoppedCode)
        Task { [weak self] in
            await self?.handleExternalStop(error: error, intentional: intentional)
        }
    }

    /// SCStreamErrorUserStopped — the system UI's "Stop Sharing" button.
    private static let userStoppedCode = -3817
    /// SCStreamErrorSystemStoppedStream (macOS 15+) — lock screen / logout / display change.
    private static let systemStoppedCode = -3821

    /// Finalize a session that was ended from outside `stopRecording()`.
    private func handleExternalStop(error: Error, intentional: Bool) async {
        // Our own stopRecording() already owns teardown; don't double-finalize.
        guard isRecording, !isStopping else { return }
        isRecording = false

        let activeWriters = writers
        var finished: [URL] = []
        for writer in activeWriters {
            if let url = try? await writer.finish() { finished.append(url) }
        }
        clearSession()

        if !finished.isEmpty {
            lastOutputURLs = finished
            if intentional {
                deliverFinish(.success(finished))
            } else {
                deliverError(error)
                deliverFinish(.failure(Self.mapPermissionError(error)))
            }
        } else {
            if !intentional { deliverError(error) }
            deliverFinish(.failure(intentional
                ? RecordingError.notCapturing
                : Self.mapPermissionError(error)))
        }
    }
}
