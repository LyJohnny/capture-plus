import AppKit
import AVFoundation
import ScreenCaptureKit
import Sparkle
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
        case "autostoptest": runAutoStopTest()
        case "pendingsavetest": runPendingSaveTest()
        case "updatetest": runUpdateTest()
        case "shots": renderProductShots()
        case "settingsrender": renderSettings()
        case "probe": runProbe()
        case "cliprender": renderClipboard()
        case "countdown": renderCountdown()
        case "countdownlive": showCountdownLive()
        default:
            NSApp.terminate(nil)
        }
    }

    /// REAL end-to-end update test: asks Sparkle to check the live feed, download the
    /// newest release, verify it, and install it in place, relaunching into the new
    /// version. Run it on a build whose version is LOWER than the latest release;
    /// afterwards /Applications holds the released version. Needs the network.
    private static var updateTest: (SPUStandardUpdaterController, UpdateTestDelegate)?
    private static func runUpdateTest() {
        try? "".write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
        let delegate = UpdateTestDelegate()
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: delegate,
                                                      userDriverDelegate: nil)
        updateTest = (controller, delegate)
        delegate.report("running=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")\n")
        controller.updater.automaticallyDownloadsUpdates = true
        controller.startUpdater()
        controller.updater.checkForUpdatesInBackground()
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            delegate.report("update=FAIL (timed out after 180 s)\n"); exit(1)
        }
    }

    private final class UpdateTestDelegate: NSObject, SPUUpdaterDelegate {
        func report(_ text: String) {
            let log = ((try? String(contentsOfFile: "/tmp/captureplus-selftest.txt", encoding: .utf8)) ?? "") + text
            try? log.write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
        }
        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            report("foundUpdate=\(item.displayVersionString) build=\(item.versionString)\n")
        }
        func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
            report("foundUpdate=none (\(error.localizedDescription))\n"); exit(0)
        }
        func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
            report("downloaded=yes\n")
        }
        func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                     immediateInstallationBlock: @escaping () -> Void) -> Bool {
            report("verified=yes installingNow=yes\n")
            immediateInstallationBlock()
            return true
        }
        func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
            report("update=FAIL (\(error.localizedDescription))\n"); exit(1)
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

    /// The "second recording buried the first" failsafe, end to end, with a REAL
    /// recording and TEMP folders only (never the user's real save folder):
    ///  A. pending trimmer + auto-save → saved, playable, source moved, trimmer done,
    ///     flagged auto; a same-named decoy in the destination is NOT overwritten
    ///  B. idempotent: a second auto-save call is a no-op
    ///  C. a trimmer with a sheet open (user mid-save/delete) is left alone, then
    ///     saved once the sheet is dismissed
    ///  D. launch sweep: stranded playable file filed; 0-byte file and non-mp4 left
    ///     untouched (never deleted); a second sweep files nothing new
    private static func runPendingSaveTest() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("captureplus-pending-\(UUID().uuidString)")
        let inProgress = root.appendingPathComponent("In Progress")
        let saveDir = root.appendingPathComponent("Saved")
        try? fm.createDirectory(at: inProgress, withIntermediateDirectories: true)
        try? fm.createDirectory(at: saveDir, withIntermediateDirectories: true)

        var lines: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(name)=\(ok ? "PASS" : "FAIL")\(detail.isEmpty ? "" : " (\(detail))")")
        }
        func finishTest() {
            let ok = lines.allSatisfy { $0.contains("=PASS") }
            try? ("pendingSave=\(ok ? "PASS" : "FAIL")\n" + lines.joined(separator: "\n") + "\n")
                .write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
            try? fm.removeItem(at: root)
            exit(ok ? 0 : 1)
        }
        func playable(_ url: URL) async -> Bool {
            let asset = AVURLAsset(url: url)
            let p = (try? await asset.load(.isPlayable)) ?? false
            let s = ((try? await asset.load(.duration)) ?? .zero).seconds
            return p && s > 1
        }

        Task { @MainActor in
            // A real 4s recording to play with.
            let clip = inProgress.appendingPathComponent("clip.mp4")
            let engine = RecordingEngine()
            do {
                guard let display = try await engine.availableDisplays().first else {
                    check("record", false, "no display"); finishTest(); return
                }
                try await engine.startRecording(
                    target: .display(display), captureSystemAudio: true,
                    includeMicrophone: false, microphoneDeviceID: nil,
                    maxHeight: 720, outputURLs: [clip])
                try await Task.sleep(nanoseconds: 4_000_000_000)
                _ = try await engine.stopRecording()
            } catch {
                check("record", false, error.localizedDescription); finishTest(); return
            }
            let clip2 = inProgress.appendingPathComponent("clip2.mp4")
            let clip3 = inProgress.appendingPathComponent("stranded.mp4")
            let clip4 = root.appendingPathComponent("quit-clip.mp4")   // outside In Progress
            try? fm.copyItem(at: clip, to: clip2)
            try? fm.copyItem(at: clip, to: clip3)
            try? fm.copyItem(at: clip, to: clip4)
            TrimmerWindowController.failsafeDirectoryOverride = saveDir

            // ---- A: pending trimmer auto-saved, decoy not overwritten ----
            let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)
            let expectedName = FileOrganizer().fileName(
                template: AppSettings.shared.recordingFilenameTemplate, date: fixedDate, ext: "mp4")
            let decoy = saveDir.appendingPathComponent(expectedName)
            try? Data("DECOY".utf8).write(to: decoy)

            var delivered: URL??
            let t1 = TrimmerWindowController()
            t1.present(url: clip, suggestedName: "T1", date: fixedDate) { delivered = .some($0) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            check("pendingBefore", TrimmerWindowController.hasPending)

            let saved = TrimmerWindowController.autoSavePending(into: saveDir)
            let savedURL = saved.first
            check("savedOne", saved.count == 1, "\(saved.count)")
            check("sourceMoved", !fm.fileExists(atPath: clip.path))
            check("playable", savedURL != nil ? await playable(savedURL!) : false)
            check("flaggedAuto", t1.wasAutoSaved)
            check("completionGotURL", delivered == .some(savedURL))
            let decoyIntact = (try? String(contentsOf: decoy, encoding: .utf8)) == "DECOY"
            check("decoyNotOverwritten", decoyIntact && savedURL != decoy,
                  savedURL?.lastPathComponent ?? "nil")

            // ---- B: idempotent ----
            check("secondCallNoop", TrimmerWindowController.autoSavePending(into: saveDir).isEmpty)
            check("noPendingAfter", !TrimmerWindowController.hasPending)

            // ---- C: trimmer with a sheet open is left alone ----
            let t2 = TrimmerWindowController()
            t2.present(url: clip2, suggestedName: "T2", date: fixedDate.addingTimeInterval(60)) { _ in }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            t2.window?.beginSheet(sheet, completionHandler: nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let skipped = TrimmerWindowController.autoSavePending(into: saveDir)
            check("sheetOpenSkipped", skipped.isEmpty && fm.fileExists(atPath: clip2.path))
            t2.window?.endSheet(sheet)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let afterSheet = TrimmerWindowController.autoSavePending(into: saveDir)
            check("savedAfterSheet", afterSheet.count == 1 && !fm.fileExists(atPath: clip2.path))

            // ---- E: window torn down without a choice (the APP-QUIT path) ----
            // This exact path deleted a real 14-minute recording on 2026-09-24.
            let t3 = TrimmerWindowController()
            t3.present(url: clip4, suggestedName: "T3", date: fixedDate.addingTimeInterval(120)) { _ in }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let before = Set((try? fm.contentsOfDirectory(atPath: saveDir.path)) ?? [])
            t3.window?.close()   // what app termination does to open windows
            try? await Task.sleep(nanoseconds: 300_000_000)
            let after = Set((try? fm.contentsOfDirectory(atPath: saveDir.path)) ?? [])
            let newFile = after.subtracting(before).first.map { saveDir.appendingPathComponent($0) }
            check("quitCloseNotDeleted", newFile != nil && !fm.fileExists(atPath: clip4.path),
                  newFile?.lastPathComponent ?? "file vanished")
            check("quitCloseSavedPlayable", newFile != nil ? await playable(newFile!) : false)
            check("quitCloseFlaggedAuto", t3.wasAutoSaved)

            // ---- D: launch sweep of stranded recordings ----
            let empty = inProgress.appendingPathComponent("empty.mp4")
            let notes = inProgress.appendingPathComponent("notes.txt")
            fm.createFile(atPath: empty.path, contents: Data())
            try? Data("x".utf8).write(to: notes)

            let organizer = FileOrganizer()
            let template = AppSettings.shared.recordingFilenameTemplate
            let listed = FileOrganizer.strandedRecordings(in: inProgress)
            check("listsOnlyMp4", Set(listed.map(\.lastPathComponent)) == ["stranded.mp4", "empty.mp4"],
                  listed.map(\.lastPathComponent).sorted().joined(separator: ","))
            let recovered = await organizer.recoverRecordings(listed, into: saveDir, template: template)
            check("recoveredPlayable", recovered.count == 1 && !fm.fileExists(atPath: clip3.path),
                  "\(recovered.count)")
            check("emptyLeftNotDeleted", fm.fileExists(atPath: empty.path))
            check("nonMp4Untouched", fm.fileExists(atPath: notes.path))
            let again = await organizer.recoverRecordings(
                FileOrganizer.strandedRecordings(in: inProgress), into: saveDir, template: template)
            check("sweepIdempotent", again.isEmpty)

            finishTest()
        }
    }

    /// Verifies the max-duration failsafe with a REAL recording: starts one with an
    /// 8-second limit, never calls stop, and asserts the engine stopped itself, flagged
    /// the stop as automatic, and produced a playable file of about the right length.
    private static func runAutoStopTest() {
        let engine = RecordingEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("captureplus-autostop-\(UUID().uuidString).mp4")
        let limit: TimeInterval = 8

        func report(_ text: String) {
            try? text.write(toFile: "/tmp/captureplus-selftest.txt",
                            atomically: true, encoding: .utf8)
        }

        Task { @MainActor in
            guard let display = try? await engine.availableDisplays().first else {
                report("autoStop=FAIL (no display)\n"); exit(1)
            }
            var result: Result<[URL], Error>?
            engine.onFinish = { result = $0 }

            do {
                try await engine.startRecording(
                    target: .display(display), captureSystemAudio: true,
                    includeMicrophone: false, microphoneDeviceID: nil,
                    maxHeight: 720, maxDuration: limit, outputURLs: [url])
            } catch {
                report("autoStop=FAIL (start: \(error.localizedDescription))\n"); exit(1)
            }

            // Wait past the limit WITHOUT stopping — the engine must do it itself.
            try? await Task.sleep(nanoseconds: 16_000_000_000)

            let stoppedItself = !engine.isRecording
            let flagged = engine.lastStopWasAutomatic
            var playable = false, seconds = 0.0
            if case .success(let urls) = result, let file = urls.first {
                let asset = AVURLAsset(url: file)
                playable = (try? await asset.load(.isPlayable)) ?? false
                seconds = ((try? await asset.load(.duration)) ?? .zero).seconds
                try? FileManager.default.removeItem(at: file)
            }
            // Allow generous slack: the timer has 5s tolerance by design.
            let rightLength = seconds > 4 && seconds < 16
            let ok = stoppedItself && flagged && playable && rightLength
            report("""
            autoStop=\(ok ? "PASS" : "FAIL")
            stoppedItself=\(stoppedItself) flaggedAutomatic=\(flagged) \
            playable=\(playable) duration=\(String(format: "%.1f", seconds))s (limit \(Int(limit))s)

            """)
            exit(ok ? 0 : 1)
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

    // MARK: - Product shots (README / release page)

    /// Captures each window with its real macOS chrome and shadow (needs Screen
    /// Recording, so launch via `open`), composited onto the Tahoe wallpaper.
    /// Output: /tmp/captureplus-shot-{annotation,clipboard,settings}.png
    private static var shotKeepAlive: [AnyObject] = []
    private static func renderProductShots() {
        Task { @MainActor in
            // A believable "screenshot" to annotate: the Settings window, shortened.
            let sampleSettings = SettingsWindowController()
            sampleSettings.show()
            sampleSettings.window?.setContentSize(NSSize(width: 460, height: 490))   // ends after App Permissions
            sampleSettings.window?.center()
            sampleSettings.window?.makeFirstResponder(nil)
            NSApp.activate(ignoringOtherApps: true)
            sampleSettings.window?.makeKeyAndOrderFront(nil)
            shotKeepAlive.append(sampleSettings)
            try? await Task.sleep(for: .seconds(1.2))
            guard let sampleCG = await capture(sampleSettings.window, margin: 0, shadow: false) else { exit(1) }
            let sampleScale = sampleSettings.window?.backingScaleFactor ?? 2
            let sample = NSImage(cgImage: sampleCG, size: NSSize(width: CGFloat(sampleCG.width) / sampleScale,
                                                                 height: CGFloat(sampleCG.height) / sampleScale))
            sampleSettings.window?.orderOut(nil)

            // 1. Annotation editor holding that screenshot.
            let annotation = AnnotationWindowController()
            annotation.present(image: sample, suggestedName: "Screenshot",
                               defaultSaveDirectory: nil,
                               onCopy: { _ in }, onSave: { _, _ in }, onDelete: {})
            shotKeepAlive.append(annotation)
            try? await Task.sleep(for: .seconds(1))
            await shoot(annotation.window, name: "annotation")
            annotation.window?.orderOut(nil)

            // 2. Clipboard history panel, styled like the live one.
            let model = ClipboardHistoryModel()
            var items: [ClipItem] = []
            if let shot = ClipItem.image(from: sample) { items.append(shot) }
            items.append(ClipItem(kind: .text("Meeting moved to Thursday, 3:00 PM")))
            items.append(ClipItem(kind: .text("https://github.com/LyJohnny/capture-plus")))
            model.items = items
            let panel = ClipboardHistoryPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                styleMask: [.nonactivatingPanel, .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: ClipboardHistoryView(model: model))
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            shotKeepAlive.append(panel)
            try? await Task.sleep(for: .seconds(1))
            await shoot(panel, name: "clipboard")
            panel.orderOut(nil)

            // 3. Settings, the real window, cut at a row boundary (it scrolls further).
            let settings = SettingsWindowController()
            settings.show()
            settings.window?.setContentSize(NSSize(width: 460, height: 905))
            settings.window?.center()
            settings.window?.makeFirstResponder(nil)
            NSApp.activate(ignoringOtherApps: true)
            settings.window?.makeKeyAndOrderFront(nil)
            shotKeepAlive.append(settings)
            try? await Task.sleep(for: .seconds(1.2))
            await shoot(settings.window, name: "settings")
            exit(0)
        }
    }

    /// Screenshots `window` via ScreenCaptureKit: its real chrome, optionally its
    /// shadow (with `margin` points of room around it), transparent elsewhere.
    private static func capture(_ window: NSWindow?, margin: CGFloat, shadow: Bool) async -> CGImage? {
        guard let window,
              let content = try? await SCShareableContent.current,
              let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        else { return nil }
        let scale = CGFloat(window.backingScaleFactor)
        // SCK rects are top-left origin in display points; AppKit's are bottom-left.
        let frame = window.frame
        let src = CGRect(x: frame.minX - margin,
                         y: display.frame.height - frame.maxY - margin,
                         width: frame.width + margin * 2, height: frame.height + margin * 2)
        let filter = SCContentFilter(display: display, including: [scWindow])
        let config = SCStreamConfiguration()
        config.sourceRect = src
        config.width = Int(src.width * scale)
        config.height = Int(src.height * scale)
        config.showsCursor = false
        config.backgroundColor = .clear
        config.ignoreShadowsDisplay = !shadow
        config.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures `window` with its shadow and composites it onto the wallpaper.
    private static func shoot(_ window: NSWindow?, name: String) async {
        guard let cg = await capture(window, margin: 80, shadow: true) else {
            try? "shot=\(name) FAIL\n".write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
            return
        }
        let canvasW = 2400, canvasH = 1500
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvasW, pixelsHigh: canvasH,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let canvas = NSRect(x: 0, y: 0, width: canvasW, height: canvasH)
        // macOS 26's default wallpaper (Tahoe Light). It ships inside the wallpaper
        // extension rather than Desktop Pictures.
        let wallpaper = "/System/Library/ExtensionKit/Extensions/NeptuneOneWallpaper.appex/Contents/Resources/TahoeLight.heic"
        if let wall = NSImage(contentsOfFile: wallpaper) {
            let ws = wall.size
            let f = max(canvas.width / ws.width, canvas.height / ws.height)
            let dw = ws.width * f, dh = ws.height * f
            wall.draw(in: NSRect(x: (canvas.width - dw) / 2, y: (canvas.height - dh) / 2, width: dw, height: dh))
        }
        var w = CGFloat(cg.width), h = CGFloat(cg.height)
        let f = min(1, canvas.width * 0.92 / w, canvas.height * 0.92 / h)
        w *= f; h *= f
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            .draw(in: NSRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "/tmp/captureplus-shot-\(name).png"))
    }

    private static func writePNG(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
