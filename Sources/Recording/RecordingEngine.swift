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

    // MARK: - Private state

    /// Active streams (one per display, or a single stream for display/window).
    private var streams: [SCStream] = []
    /// Recording outputs, parallel to `streams`.
    private var recordingOutputs: [SCRecordingOutput] = []
    /// Destination URLs, parallel to `streams`.
    private var outputURLs: [URL] = []
    /// Count of outputs that have reported `didFinishRecording`.
    private var finishedOutputCount: Int = 0

    /// Guards against double-delivery of the terminal result.
    private var didFinish: Bool = false

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

        // Build every stream + recording output up front (nothing captures yet).
        var builtStreams: [SCStream] = []
        var builtOutputs: [SCRecordingOutput] = []
        builtStreams.reserveCapacity(specs.count)
        builtOutputs.reserveCapacity(specs.count)

        for (index, spec) in specs.enumerated() {
            let (stream, output) = try makeStream(
                filter: spec.filter,
                pixelWidth: spec.width,
                pixelHeight: spec.height,
                captureSystemAudio: captureSystemAudio,
                includeMicrophone: includeMicrophone,
                microphoneDeviceID: microphoneDeviceID,
                codec: codec,
                outputURL: outputURLs[index]
            )
            builtStreams.append(stream)
            builtOutputs.append(output)
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
        recordingOutputs = builtOutputs
        self.outputURLs = outputURLs
        isRecording = true
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

        let activeStreams = streams
        let urls = outputURLs

        do {
            for stream in activeStreams {
                try await stream.stopCapture()
            }
        } catch {
            // Even on a stopCapture error, some files may be partially written;
            // surface the failure to the caller.
            isRecording = false
            clearSession()
            let mapped = RecordingError.streamFailure(underlying: error)
            deliverFinish(.failure(mapped))
            throw mapped
        }

        isRecording = false
        clearSession()
        // Note: the delegates' didFinishRecording also deliver success; the
        // didFinish guard prevents a double onFinish.
        deliverFinish(.success(urls))
        return urls
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
            let (w, h) = pixelDimensions(for: display)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return [FilterSpec(filter: filter, width: w, height: h)]

        case .window(let window):
            // Desktop-independent window filter isolates just this window.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let (w, h) = pixelDimensions(for: filter, fallback: window.frame)
            return [FilterSpec(filter: filter, width: w, height: h)]

        case .displays(let displays):
            guard !displays.isEmpty else { throw RecordingError.noDisplayAvailable }
            return displays.map { display in
                let (w, h) = pixelDimensions(for: display)
                let filter = SCContentFilter(display: display, excludingWindows: [])
                return FilterSpec(filter: filter, width: w, height: h)
            }
        }
    }

    /// Build a configured `SCStream` + `SCRecordingOutput` pair for one filter.
    /// Adds the recording output before returning (but does not start capture).
    private func makeStream(
        filter: SCContentFilter,
        pixelWidth: Int,
        pixelHeight: Int,
        captureSystemAudio: Bool,
        includeMicrophone: Bool,
        microphoneDeviceID: String?,
        codec: AVVideoCodecType,
        outputURL: URL
    ) throws -> (SCStream, SCRecordingOutput) {
        // Stream configuration.
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        // 60 fps target.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // Capture system audio into the same file (per the caller's choice).
        config.capturesAudio = captureSystemAudio
        // Don't record Capture +'s own output audio back into the file.
        config.excludesCurrentProcessAudio = true
        if includeMicrophone {
            config.captureMicrophone = true
            // nil => system-default input device.
            config.microphoneCaptureDeviceID = microphoneDeviceID
            // VERIFY: for a multi-display target this taps the same mic device
            // from N concurrent SCStreams. Each stream gets its own mic capture;
            // if that ever conflicts, restrict mic to the first stream instead.
        }

        // Recording output configuration.
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = outputURL
        recordingConfig.outputFileType = .mp4
        recordingConfig.videoCodecType = codec

        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        // Add the recording output BEFORE startCapture so the first sample is
        // written (per SCKit header guidance). addRecordingOutput throws.
        do {
            try stream.addRecordingOutput(output)
        } catch {
            throw RecordingError.couldNotStartRecordingOutput(underlying: error)
        }

        return (stream, output)
    }

    /// Clear all per-session stream state.
    private func clearSession() {
        streams = []
        recordingOutputs = []
        outputURLs = []
    }

    /// Pixel dimensions for a display. `SCDisplay.width/height` are in points;
    /// the backing store (Retina) is typically 2×. Query the active CG display
    /// mode for true pixel dimensions, falling back to the point sizes.
    private static func pixelDimensions(for display: SCDisplay) -> (Int, Int) {
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            let w = mode.pixelWidth
            let h = mode.pixelHeight
            if w > 0 && h > 0 { return (w, h) }
        }
        return (Int(display.width), Int(display.height))
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

// MARK: - SCRecordingOutputDelegate

extension RecordingEngine: SCRecordingOutputDelegate {

    public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        // No-op: startCapture()'s async completion already signals start.
    }

    public func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: Error
    ) {
        // Any output failing is terminal for the whole session.
        isRecording = false
        deliverError(error)
        deliverFinish(.failure(RecordingError.streamFailure(underlying: error)))
    }

    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        // Only deliver success once EVERY output has finished. Count against the
        // number of outputs we started (captured before clearSession runs).
        let total = recordingOutputs.count
        finishedOutputCount += 1
        guard total > 0, finishedOutputCount >= total else { return }
        isRecording = false
        deliverFinish(.success(outputURLs))
    }
}

// MARK: - SCStreamDelegate

extension RecordingEngine: SCStreamDelegate {

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // An unexpected stop (e.g. user revoked permission mid-record, display
        // disconnected). Treat as terminal failure for the whole session.
        isRecording = false
        deliverError(error)
        deliverFinish(.failure(Self.mapPermissionError(error)))
    }
}
