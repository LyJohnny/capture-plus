import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Debug-only UI render harness. Activated by the `CAPTUREPLUS_RENDER` env var; never runs in
/// normal use. It builds a piece of UI, renders it to a PNG (via `cacheDisplay`, which
/// needs no Screen Recording permission), and exits — so UI changes can be inspected
/// without a human at the screen.
///
/// Usage: `CAPTUREPLUS_RENDER=annotation /Applications/Capture +.app/Contents/MacOS/Capture +`
@MainActor
enum UITestHarness {
    static func run(_ mode: String) {
        switch mode {
        case "annotation": renderAnnotation()
        case "texttest": runTextCommitTest()
        case "closetest": runCloseConfirmTest()
        case "cliptest": runClipboardTest()
        case "rectest": runRecordingTest()
        case "crashtest": runCrashTest()
        case "pillstop": runPillStopTest()
        case "repeattest": runRepeatTest()
        case "trimtest": runTrimDeleteTest()
        case "gaintest": runMicGainTest()
        case "micidtest": runMicResolutionTest()
        case "scrolltest": runScrollReverseTest()
        case "settingsrender": renderSettings()
        case "probe": runProbe()
        case "cliprender": renderClipboard()
        case "countdown": renderCountdown()
        case "countdownlive": showCountdownLive()
        default:
            NSApp.terminate(nil)
        }
    }

    /// REAL end-to-end recording test: records the main display for 12 s, stops, and
    /// asserts the file is on disk, playable, and roughly the right duration. 12 s is
    /// deliberately longer than the engine's 8 s startup health check, so this also
    /// proves that check does NOT false-alarm on a healthy recording.
    ///
    /// Needs Screen Recording permission, and must be launched via `open` so macOS
    /// attributes the capture to Capture + rather than the parent shell.
    private static func runRecordingTest() {
        let engine = RecordingEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("captureplus-rectest-\(UUID().uuidString).mp4")
        var earlyFired = false
        engine.onEarlyFailure = { _ in earlyFired = true }

        // Accumulate rather than overwrite, so the pre-flight diagnostics survive
        // alongside the verdict (they're what let us compare machine to machine).
        var log = ""
        func report(_ text: String) {
            log += text
            try? log.write(toFile: "/tmp/captureplus-selftest.txt",
                           atomically: true, encoding: .utf8)
        }

        // Height under test: 0 = native (what the app defaults to, and what the user's
        // failing recording used). Overridable so native vs scaled can be compared.
        let maxHeight = Int(ProcessInfo.processInfo.environment["CAPTUREPLUS_RECTEST_HEIGHT"] ?? "0") ?? 0
        // System audio on by default in the app — include it here so the test matches
        // real-world use rather than a stripped-down happy path.
        let withAudio = (ProcessInfo.processInfo.environment["CAPTUREPLUS_RECTEST_AUDIO"] ?? "1") == "1"

        Task { @MainActor in
            do {
                let displays = try await engine.availableDisplays()
                guard let display = displays.first else {
                    report("recording=FAIL (no display available)\n"); exit(1)
                }

                // DIAGNOSTIC: compare the dimensions we ask SCKit for against the ones
                // SCKit derives from the content filter. A mismatch here is a prime
                // suspect for "failure to process first sample buffer".
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let filterW = filter.contentRect.width * CGFloat(filter.pointPixelScale)
                let filterH = filter.contentRect.height * CGFloat(filter.pointPixelScale)
                var modeW = 0, modeH = 0
                if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                    modeW = mode.pixelWidth; modeH = mode.pixelHeight
                }
                let dims = "filterDerived=\(Int(filterW))x\(Int(filterH)) "
                    + "displayMode=\(modeW)x\(modeH) "
                    + "match=\(Int(filterW) == modeW && Int(filterH) == modeH ? "YES" : "NO (SUSPECT)")"

                try await engine.startRecording(
                    target: .display(display),
                    captureSystemAudio: withAudio,
                    includeMicrophone: false,
                    microphoneDeviceID: nil,
                    maxHeight: maxHeight,
                    outputURLs: [url])
                report("started (height=\(maxHeight == 0 ? "native" : "\(maxHeight)") "
                       + "audio=\(withAudio))\n\(dims)\n")

                try await Task.sleep(nanoseconds: 12_000_000_000)
                _ = try await engine.stopRecording()
                // Give SCKit a moment to finalize the file after stopCapture returns.
                try await Task.sleep(nanoseconds: 1_500_000_000)

                let bytes = RecordingEngine.fileSize(of: url)
                let asset = AVURLAsset(url: url)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                let seconds = ((try? await asset.load(.duration)) ?? .zero).seconds
                let salvage = engine.salvageableFiles().count

                let ok = bytes > 0 && playable && seconds > 8 && !earlyFired
                report("""
                recording=\(ok ? "PASS" : "FAIL") height=\(maxHeight == 0 ? "native" : "\(maxHeight)") \
                audio=\(withAudio)
                fileBytes=\(bytes) playable=\(playable) \
                duration=\(String(format: "%.1f", seconds))s
                falseEarlyAlarm=\(earlyFired ? "YES (BUG)" : "no")
                salvageableFiles=\(salvage)

                """)
                try? FileManager.default.removeItem(at: url)
                exit(ok ? 0 : 1)
            } catch {
                report("recording=FAIL (\(error.localizedDescription))\n")
                exit(1)
            }
        }
    }

    /// Verifies the mouse scroll-reversal transform on synthetic CGEvents (creating
    /// events needs no permission; only tapping the live stream does):
    ///  - classic mouse wheel (line-based)      → inverted
    ///  - smooth mouse wheel (pixel, no phase)  → inverted
    ///  - trackpad gesture (pixel, with phase)  → untouched
    private static func runScrollReverseTest() {
        // Line-unit events carry their value in the line delta; pixel-unit events in
        // the point delta (the line delta is a small derived value).
        func lineDelta(_ event: CGEvent) -> Int64 {
            event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        }
        func pointDelta(_ event: CGEvent) -> Int64 {
            event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        }
        var verdicts: [String] = []

        if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                               wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0) {
            let before = lineDelta(wheel)
            let touched = ScrollReverser.reverseIfMouseScroll(wheel)
            let ok = touched && before != 0 && lineDelta(wheel) == -before
            verdicts.append("mouseWheel=\(ok ? "PASS" : "FAIL (\(before)→\(lineDelta(wheel)))")")
        } else { verdicts.append("mouseWheel=FAIL (event)") }

        if let smooth = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0) {
            // CGEvent scales pixel input across the linked delta fields, so assert
            // against the observed pre-transform value, not the constructor argument.
            let before = pointDelta(smooth)
            let touched = ScrollReverser.reverseIfMouseScroll(smooth)
            let ok = touched && before != 0 && pointDelta(smooth) == -before
            verdicts.append("smoothWheel=\(ok ? "PASS" : "FAIL (\(before)→\(pointDelta(smooth)))")")
        } else { verdicts.append("smoothWheel=FAIL (event)") }

        if let trackpad = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0) {
            // Mark as a gesture the way trackpad events are: an active scroll phase.
            trackpad.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2) // "changed"
            let touched = ScrollReverser.reverseIfMouseScroll(trackpad)
            verdicts.append("trackpad=\(!touched && pointDelta(trackpad) == 10 ? "PASS (untouched)" : "FAIL (\(pointDelta(trackpad)))")")
        } else { verdicts.append("trackpad=FAIL (event)") }

        let ok = verdicts.allSatisfy { $0.contains("PASS") }
        try? "scrollReverse=\(ok ? "PASS" : "FAIL")  \(verdicts.joined(separator: "  "))\n"
            .write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }

    /// Verifies that "Automatic" mic resolution finds the BUILT-IN microphone via
    /// CoreAudio and that its UID maps to a real AVCaptureDevice — the fix for
    /// Bluetooth headphones being captured as "system default" and collapsing all
    /// Mac audio to call quality during recordings.
    private static func runMicResolutionTest() {
        let builtInID = RecordingEngine.builtInMicrophoneID()
        let devices = RecordingEngine.availableMicrophones()
        let match = devices.first { $0.uniqueID == builtInID }
        let names = devices.map(\.localizedName).joined(separator: ", ")
        let ok = builtInID != nil && match != nil
        try? """
        micResolution=\(ok ? "PASS" : "FAIL")
        builtInUID=\(builtInID ?? "nil") resolvesTo=\(match?.localizedName ?? "NO MATCH")
        allInputs=[\(names)]

        """.write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }

    /// Verifies the microphone software-gain math on a constructed Float32 PCM buffer:
    /// boost is scaled AND clamped at full scale, 0% mutes, 50% halves.
    private static func runMicGainTest() {
        func makeBuffer(_ samples: [Float32]) -> CMSampleBuffer? {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            var format: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &format) == noErr, let format else { return nil }

            let byteCount = samples.count * MemoryLayout<Float32>.size
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount, flags: 0,
                blockBufferOut: &block) == noErr, let block else { return nil }
            var source = samples
            guard CMBlockBufferReplaceDataBytes(
                with: &source, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount) == noErr else { return nil }

            var sampleBuffer: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: format, sampleCount: CMItemCount(samples.count / 2),
                presentationTimeStamp: .zero, packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer) == noErr else { return nil }
            return sampleBuffer
        }

        func readBack(_ sampleBuffer: CMSampleBuffer, count: Int) -> [Float32] {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
            var out = [Float32](repeating: .nan, count: count)
            CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                       dataLength: count * MemoryLayout<Float32>.size,
                                       destination: &out)
            return out
        }

        func matches(_ got: [Float32], _ want: [Float32]) -> Bool {
            got.count == want.count
                && zip(got, want).allSatisfy { abs($0 - $1) < 0.0001 }
        }

        let input: [Float32] = [0.5, -0.5, 0.9, -0.9, 0.1, 0.0]
        var verdicts: [String] = []

        // 200%: doubled, clamped at ±1.0.
        if let buf = makeBuffer(input) {
            RecordingWriter.applyGain(2.0, to: buf)
            let want: [Float32] = [1.0, -1.0, 1.0, -1.0, 0.2, 0.0]
            verdicts.append("boostClamped=\(matches(readBack(buf, count: 6), want) ? "PASS" : "FAIL")")
        } else { verdicts.append("boostClamped=FAIL (buffer)") }

        // 0%: mute.
        if let buf = makeBuffer(input) {
            RecordingWriter.applyGain(0, to: buf)
            let want = [Float32](repeating: 0, count: 6)
            verdicts.append("mute=\(matches(readBack(buf, count: 6), want) ? "PASS" : "FAIL")")
        } else { verdicts.append("mute=FAIL (buffer)") }

        // 50%: halved.
        if let buf = makeBuffer(input) {
            RecordingWriter.applyGain(0.5, to: buf)
            let want: [Float32] = [0.25, -0.25, 0.45, -0.45, 0.05, 0.0]
            verdicts.append("half=\(matches(readBack(buf, count: 6), want) ? "PASS" : "FAIL")")
        } else { verdicts.append("half=FAIL (buffer)") }

        let ok = verdicts.allSatisfy { $0.contains("PASS") }
        try? "micGain=\(ok ? "PASS" : "FAIL")  \(verdicts.joined(separator: "  "))\n"
            .write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }

    /// Renders the Settings form with the microphone controls visible. Temporarily
    /// forces the mic toggle on for the render, then restores the user's real value.
    private static func renderSettings() {
        let settings = AppSettings.shared
        let originalMicToggle = settings.recordMicrophoneByDefault
        settings.recordMicrophoneByDefault = true

        let hosting = NSHostingView(rootView: SettingsView())
        hosting.setFrameSize(NSSize(width: 460, height: 1200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 1200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            writePNG(hosting, to: "/tmp/captureplus-settings.png")
            settings.recordMicrophoneByDefault = originalMicToggle
            exit(0)
        }
    }

    /// Two consecutive recordings in ONE process — the long-lived menu-bar app's real
    /// usage pattern. The old ReplayKit-backed API was documented to fail the second
    /// recording in a session (-5822); this proves our writer doesn't.
    private static func runRepeatTest() {
        let engine = RecordingEngine()

        func report(_ text: String) {
            try? text.write(toFile: "/tmp/captureplus-selftest.txt",
                            atomically: true, encoding: .utf8)
        }

        Task { @MainActor in
            guard let display = try? await engine.availableDisplays().first else {
                report("repeat=FAIL (no display)\n"); exit(1)
            }
            var verdicts: [String] = []
            for round in 1...2 {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("captureplus-repeat\(round)-\(UUID().uuidString).mp4")
                do {
                    try await engine.startRecording(
                        target: .display(display), captureSystemAudio: true,
                        includeMicrophone: false, microphoneDeviceID: nil,
                        maxHeight: 720, outputURLs: [url])
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    _ = try await engine.stopRecording()
                    let asset = AVURLAsset(url: url)
                    let playable = (try? await asset.load(.isPlayable)) ?? false
                    let seconds = ((try? await asset.load(.duration)) ?? .zero).seconds
                    verdicts.append("round\(round)=\(playable && seconds > 2 ? "PASS" : "FAIL") "
                                    + "(\(String(format: "%.1f", seconds))s)")
                    try? FileManager.default.removeItem(at: url)
                } catch {
                    verdicts.append("round\(round)=FAIL (\(error.localizedDescription))")
                }
            }
            let ok = verdicts.allSatisfy { $0.contains("PASS") }
            report("repeat=\(ok ? "PASS" : "FAIL")  \(verdicts.joined(separator: "  "))\n")
            exit(ok ? 0 : 1)
        }
    }

    /// Simulates the system indicator's "Stop Sharing" button: records for real, then
    /// injects `didStopWithError` with SCStreamErrorUserStopped (-3817) — the exact
    /// error that button produces. Must finish as SUCCESS with a playable file; the
    /// old code treated it as failure and false-alarmed "Recording recovered" on
    /// every pill-stopped recording.
    private static func runPillStopTest() {
        let engine = RecordingEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("captureplus-pillstop-\(UUID().uuidString).mp4")

        func report(_ text: String) {
            try? text.write(toFile: "/tmp/captureplus-selftest.txt",
                            atomically: true, encoding: .utf8)
        }

        Task { @MainActor in
            guard let display = try? await engine.availableDisplays().first else {
                report("pillstop=FAIL (no display)\n"); exit(1)
            }
            var result: Result<[URL], Error>?
            engine.onFinish = { result = $0 }

            do {
                try await engine.startRecording(
                    target: .display(display), captureSystemAudio: true,
                    includeMicrophone: false, microphoneDeviceID: nil,
                    maxHeight: 720, outputURLs: [url])
            } catch {
                report("pillstop=FAIL (start: \(error.localizedDescription))\n"); exit(1)
            }

            try? await Task.sleep(nanoseconds: 6_000_000_000)

            // Inject the exact error the system's Stop Sharing button delivers.
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let dummy = SCStream(filter: filter, configuration: SCStreamConfiguration(),
                                 delegate: nil)
            let userStopped = NSError(domain: SCStreamErrorDomain, code: -3817,
                                      userInfo: [NSLocalizedDescriptionKey:
                                                    "The user stopped the stream."])
            engine.stream(dummy, didStopWithError: userStopped)

            // Give the finalize path time to finish the file and deliver.
            try? await Task.sleep(nanoseconds: 4_000_000_000)

            switch result {
            case .success(let urls):
                let file = urls.first ?? url
                let asset = AVURLAsset(url: file)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                let seconds = ((try? await asset.load(.duration)) ?? .zero).seconds
                let ok = playable && seconds > 3
                report("""
                pillstop=\(ok ? "PASS" : "FAIL") (delivered SUCCESS — no false alarm)
                playable=\(playable) duration=\(String(format: "%.1f", seconds))s

                """)
                try? FileManager.default.removeItem(at: file)
                exit(ok ? 0 : 1)
            case .failure(let error):
                report("pillstop=FAIL (delivered FAILURE — would show the false "
                       + "'Recording recovered' popup: \(error.localizedDescription))\n")
                exit(1)
            case nil:
                report("pillstop=FAIL (no result delivered)\n")
                exit(1)
            }
        }
    }

    /// Reproduces the audio-after-delete bug: records a short clip, opens the real
    /// trimmer, plays it, runs the delete/discard path, and asserts the player is
    /// fully detached (detached player == immediate silence).
    private static func runTrimDeleteTest() {
        let engine = RecordingEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("captureplus-trimtest-\(UUID().uuidString).mp4")

        func report(_ text: String) {
            try? text.write(toFile: "/tmp/captureplus-selftest.txt",
                            atomically: true, encoding: .utf8)
        }

        Task { @MainActor in
            guard let display = try? await engine.availableDisplays().first else {
                report("trimdelete=FAIL (no display)\n"); exit(1)
            }
            do {
                try await engine.startRecording(
                    target: .display(display), captureSystemAudio: true,
                    includeMicrophone: false, microphoneDeviceID: nil,
                    maxHeight: 720, outputURLs: [url])
                try await Task.sleep(nanoseconds: 4_000_000_000)
                _ = try await engine.stopRecording()
            } catch {
                report("trimdelete=FAIL (record: \(error.localizedDescription))\n"); exit(1)
            }

            let trimmer = TrimmerWindowController()
            trimmer.present(url: url, suggestedName: "Test", date: Date()) { _ in }
            // Let AVPlayer load the item so play() actually starts audio.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let verdict = trimmer.debugPlayDeleteSelfTest()
            report("trimdelete: \(verdict)\n")
            exit(verdict.contains("PASS") ? 0 : 1)
        }
    }

    /// Records to a fixed path and never stops — the driver hard-kills it to simulate
    /// the app or the Mac dying. The point is whether the file is still PLAYABLE.
    private static func runCrashTest() {
        let engine = RecordingEngine()
        let url = URL(fileURLWithPath: "/tmp/captureplus-crashtest.mp4")
        try? FileManager.default.removeItem(at: url)
        Task { @MainActor in
            guard let display = try? await engine.availableDisplays().first else { exit(1) }
            try? await engine.startRecording(
                target: .display(display), captureSystemAudio: true,
                includeMicrophone: false, microphoneDeviceID: nil,
                maxHeight: 0, outputURLs: [url])
            while true { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
    }

    /// Authoritative playability probe for the file at $CAPTUREPLUS_PROBE_PATH — asks
    /// AVFoundation (what a player actually uses), not Spotlight metadata.
    private static func runProbe() {
        let path = ProcessInfo.processInfo.environment["CAPTUREPLUS_PROBE_PATH"] ?? ""
        let url = URL(fileURLWithPath: path)
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let seconds = ((try? await asset.load(.duration)) ?? .zero).seconds
            let tracks = (try? await asset.loadTracks(withMediaType: .video))?.count ?? 0
            let audio = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
            let bytes = RecordingEngine.fileSize(of: url)
            try? """
            probe=\(playable && seconds > 1 ? "PLAYABLE" : "NOT PLAYABLE")
            path=\(path)
            bytes=\(bytes) duration=\(String(format: "%.1f", seconds))s \
            videoTracks=\(tracks) audioTracks=\(audio)

            """.write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    private static func runClipboardTest() {
        var result = ClipboardManager().debugSelfTest() + "\n"
        // Classification on a NON-general test pasteboard, so it can't clobber the clipboard.
        let testPB = NSPasteboard(name: NSPasteboard.Name("com.joh.captureplus.test"))
        result += ClipboardManager(pasteboard: testPB).debugClassifyTest() + "\n"
        try? result.write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Renders the pre-recording countdown over a colorful "wallpaper" gradient so the
    /// translucency of the material backdrop is actually visible.
    private static func renderCountdown() {
        let model = CountdownModel(value: 3)
        let root = ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.44, blue: 0.78),
                         Color(red: 0.52, green: 0.26, blue: 0.68),
                         Color(red: 0.90, green: 0.46, blue: 0.40)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            CountdownView(model: model)
        }
        .frame(width: 900, height: 620)

        let hosting = NSHostingView(rootView: root)
        hosting.setFrameSize(NSSize(width: 900, height: 620))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            writePNG(hosting, to: "/tmp/captureplus-countdown.png")
            exit(0)
        }
    }

    /// Shows the REAL countdown window (with its live glass material) over the actual
    /// desktop and holds it briefly, so an external `screencapture` can grab a faithful
    /// shot. Materials only composite live, so this is the only way to preview them.
    private static func showCountdownLive() {
        let model = CountdownModel(value: 3)
        guard let screen = NSScreen.main else { exit(1) }
        let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.contentView = NSHostingView(rootView: CountdownView(model: model))
        win.setFrame(screen.frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        win.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { exit(0) }
    }

    private static func renderClipboard() {
        let model = ClipboardHistoryModel()
        var items: [ClipItem] = []
        if let shot = ClipItem.image(from: testImage()) { items.append(shot) }
        items.append(ClipItem(kind: .text("Some copied text — hello world")))
        model.items = items
        model.copiedBanner = true   // show the "Copied" banner for the render
        let hosting = NSHostingView(rootView: ClipboardHistoryView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            writePNG(hosting, to: "/tmp/captureplus-clipboard.png")
            exit(0)
        }
    }

    /// Verifies that clicking the annotation window's red close button (simulated via
    /// performClose) shows a confirmation sheet, even with NO annotations drawn — the
    /// exact scenario the user hit (just previewing, then closing).
    private static func runCloseConfirmTest() {
        let c = AnnotationWindowController()
        c.present(image: testImage(), suggestedName: "Test", defaultSaveDirectory: nil,
                  onCopy: { _ in }, onSave: { _, _ in }, onDelete: {})
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            c.window?.performClose(nil)   // simulate the red close button
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let hasSheet = (c.window?.attachedSheet != nil)
                // Write to a file (stdout buffers) and hard-exit (an attached sheet blocks
                // NSApp.terminate, which is itself a hint the sheet is up).
                let result = "closeShowsConfirmation=\(hasSheet ? "PASS" : "FAIL")\n"
                try? result.write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
                if let sheet = c.window?.attachedSheet, let content = sheet.contentView {
                    writePNG(content, to: "/tmp/captureplus-closesheet.png")
                    c.window?.endSheet(sheet)
                }
                exit(0)
            }
        }
    }

    private static func runTextCommitTest() {
        let controller = AnnotationWindowController()
        controller.present(image: testImage(), suggestedName: "Test",
                           defaultSaveDirectory: nil,
                           onCopy: { _ in }, onSave: { _, _ in }, onDelete: {})
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            print("SELFTEST: \(controller.debugTextCommitSelfTest())")
            NSApp.terminate(nil)
        }
    }

    private static func renderAnnotation() {
        let controller = AnnotationWindowController()
        controller.present(image: testImage(), suggestedName: "Test",
                           defaultSaveDirectory: nil,
                           onCopy: { _ in }, onSave: { _, _ in }, onDelete: {})
        controller.debugPopulateShapes()   // drop one of each shape to verify geometry

        // Let AppKit lay out the toolbar + canvas, then snapshot the window content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if let content = controller.window?.contentView {
                writePNG(content, to: "/tmp/captureplus-annotation.png")
            }
            NSApp.terminate(nil)
        }
    }

    private static func testImage() -> NSImage {
        let size = NSSize(width: 1000, height: 640)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            .font: NSFont.systemFont(ofSize: 34),
            .paragraphStyle: para,
        ]
        "annotation test canvas".draw(in: NSRect(x: 0, y: size.height / 2 - 24, width: size.width, height: 48),
                                      withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    private static func writePNG(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
