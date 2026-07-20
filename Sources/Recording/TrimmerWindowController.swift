import AppKit
import AVKit
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

/// Presents a QuickTime-style trim window for a just-recorded file.
///
/// Hosts an `AVPlayerView` with the system trim UI (`beginTrimming`), then
/// exports the chosen range losslessly via `AVAssetExportPresetPassthrough`.
/// Owns the recording's file lifecycle end-to-end: on Save it exports the
/// trimmed range (if any), then persists the result to its final location —
/// either via an `NSSavePanel` or auto-filed into the recordings folder,
/// depending on `AppSettings`. The completion receives the **final saved URL**
/// or `nil` if the recording was discarded. The trimmer's destructive **Delete**
/// button confirms and then discards the recording; when the user instead tries
/// to close the window an unsaved recording a Save / Delete / Cancel confirmation
/// guards against accidental data loss. Either discard path deletes the raw temp
/// file.
///
/// Usage:
/// ```
/// let trimmer = TrimmerWindowController()
/// trimmer.present(url: recordedURL, suggestedName: "Recording", date: startDate) { savedURL in
///     // savedURL == nil on discard (raw file already cleaned up);
///     // otherwise the final on-disk file.
/// }
/// ```
@MainActor
final class TrimmerWindowController: NSWindowController {

    // MARK: - Live-instance retention
    // present() is typically called on a freshly created controller that the
    // caller does not otherwise retain. Keep ourselves alive for the lifetime
    // of the window so we aren't deallocated mid-trim.
    private static var liveControllers: Set<TrimmerWindowController> = []

    // MARK: - State
    private var player: AVPlayer?
    private var playerView: AVPlayerView?
    private var sourceURL: URL?
    private var recordingDate: Date = Date()
    private var completion: ((URL?) -> Void)?
    private var trimStateTimer: Timer?

    /// Config/save source of truth (the one allowed singleton) + file mover.
    private let settings = AppSettings.shared
    private let fileOrganizer = FileOrganizer()

    private var trimButton: NSButton?
    private var saveButton: NSButton?
    private var deleteButton: NSButton?
    private var statusLabel: NSTextField?
    private var spinner: NSProgressIndicator?

    private var isExporting = false
    private var didFinish = false

    // MARK: - Init
    init() {
        // Build the window up front; content is populated in present().
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 480)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trim Recording"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// Present the trim window for `url`. Calls `completion` exactly once with
    /// the final saved file URL, or `nil` if the user discarded the recording
    /// (in which case the raw file at `url` is deleted for you). `date` seeds
    /// the filename template for the saved file.
    func present(url: URL, suggestedName: String, date: Date = Date(), completion: @escaping (URL?) -> Void) {
        self.sourceURL = url
        self.recordingDate = date
        self.completion = completion
        self.didFinish = false

        TrimmerWindowController.liveControllers.insert(self)

        guard let window = self.window else {
            completion(nil)
            return
        }
        window.title = suggestedName.isEmpty ? "Trim Recording" : "Trim \(suggestedName)"

        // Size the preview to fill most of the screen so the user can actually see
        // the recording, then re-center.
        if let screen = window.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            window.setContentSize(NSSize(width: vf.width * 0.82, height: vf.height * 0.84))
            window.center()
        }

        let player = AVPlayer(url: url)
        self.player = player

        let playerView = AVPlayerView(frame: window.contentView?.bounds ?? .zero)
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.autoresizingMask = [.width, .height]
        self.playerView = playerView

        buildContent(hosting: playerView, in: window)

        // canBeginTrimming flips true once the item becomes ready to play.
        // Poll it (cheap, and avoids KVO keypath fragility) to keep the Trim
        // button in sync until the window closes.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isExporting else { return }
                self.trimButton?.isEnabled = self.playerView?.canBeginTrimming ?? false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.trimStateTimer = timer

        // App is normally an accessory/menu-bar app; bring the window forward
        // so the trim UI is usable. (Integrator manages activation policy.)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI construction

    private func buildContent(hosting playerView: AVPlayerView, in window: NSWindow) {
        let container = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 720, height: 480))
        container.autoresizingMask = [.width, .height]

        let barHeight: CGFloat = 52
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: container.bounds.width, height: barHeight))
        bar.autoresizingMask = [.width]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        playerView.frame = NSRect(x: 0, y: barHeight, width: container.bounds.width, height: container.bounds.height - barHeight)
        playerView.autoresizingMask = [.width, .height]

        // Buttons (right-aligned: Delete, Trim, Save).
        let delete = makeButton(title: "Delete", action: #selector(deleteTapped))
        // Destructive styling, consistent with the annotation editor's Delete.
        delete.hasDestructiveAction = true
        delete.bezelColor = NSColor.systemRed
        let trim = makeButton(title: "Trim", action: #selector(trimTapped))
        trim.isEnabled = false
        let save = makeButton(title: "Save", action: #selector(saveTapped))
        save.keyEquivalent = "\r" // Return
        save.bezelColor = NSColor.controlAccentColor

        self.deleteButton = delete
        self.trimButton = trim
        self.saveButton = save

        // Status label + spinner (left side), shown during export.
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 12, y: (barHeight - 16) / 2, width: 260, height: 16)
        label.autoresizingMask = [.maxXMargin]
        self.statusLabel = label

        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: (barHeight - 16) / 2, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        self.spinner = spinner

        // Lay out buttons from the right edge.
        let buttonWidth: CGFloat = 84
        let spacing: CGFloat = 8
        let rightInset: CGFloat = 12
        let y: CGFloat = (barHeight - 32) / 2
        var x = container.bounds.width - rightInset - buttonWidth
        for button in [save, trim, delete] {
            button.frame = NSRect(x: x, y: y, width: buttonWidth, height: 32)
            button.autoresizingMask = [.minXMargin]
            bar.addSubview(button)
            x -= (buttonWidth + spacing)
        }

        // Place spinner just left of where labels sit.
        spinner.frame.origin = NSPoint(x: 12, y: (barHeight - 16) / 2)
        label.frame.origin = NSPoint(x: 34, y: (barHeight - 16) / 2)

        bar.addSubview(spinner)
        bar.addSubview(label)

        container.addSubview(playerView)
        container.addSubview(bar)
        window.contentView = container
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        return button
    }

    // MARK: - Actions

    @objc private func trimTapped() {
        guard let playerView, playerView.canBeginTrimming else { return }
        player?.pause()
        playerView.beginTrimming { _ in
            // The trim UI mutates the current item's forward/reverse playback
            // end times in place. We read them on Save; the OK/Cancel result
            // here only affects whether those handles were committed, which is
            // already reflected in the item, so nothing else to do.
        }
    }

    @objc private func deleteTapped() {
        confirmDelete()
    }

    @objc private func saveTapped() {
        guard !isExporting, !didFinish else { return }
        // Stop preview playback immediately — an AVPlayer keeps emitting audio even
        // with no visible view, so if the user was previewing when they hit Save it
        // would otherwise keep playing through the whole export.
        player?.pause()
        guard let sourceURL else {
            finish(with: nil)
            return
        }

        let range = currentTrimRange()

        // No effective trim → persist the original untouched.
        guard let range else {
            persist(tempURL: sourceURL)
            return
        }

        beginBusy("Exporting…")
        Task { [weak self] in
            let result = await Self.export(source: sourceURL, timeRange: range)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let outURL):
                    self.persist(tempURL: outURL)
                case .failure(let error):
                    self.endBusy()
                    self.showExportError(error)
                    // Leave the window open so the user can retry or cancel.
                }
            }
        }
    }

    // MARK: - Delete / close confirmation

    /// The Delete button's confirmation: a destructive, two-button prompt. On
    /// confirm the recording is discarded (raw temp file removed) and the window
    /// closes without saving; Cancel keeps the window open.
    private func confirmDelete() {
        guard let window, !isExporting, !didFinish else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "The recording will be discarded."
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "Delete") // .alertFirstButtonReturn
        // VERIFY: NSButton.hasDestructiveAction (macOS 11+) tints Delete.
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")                    // .alertSecondButtonReturn
        alert.buttons[1].keyEquivalent = "\u{1b}"               // Esc → Cancel
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.discardAndFinish() }
            // Cancel: keep the window open.
        }
    }

    /// The window-close confirmation: guards a stray close from silently losing
    /// (or silently keeping) an unsaved recording by forcing an explicit choice.
    /// Save proceeds to the save flow; Delete discards the raw file and closes;
    /// Cancel keeps the window open.
    private func confirmClose() {
        guard let window, !isExporting, !didFinish else { return }
        let alert = NSAlert()
        alert.messageText = "Save this recording before closing?"
        alert.informativeText = "This recording hasn’t been saved yet."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")                      // .alertFirstButtonReturn (default)
        let deleteButton = alert.addButton(withTitle: "Delete") // .alertSecondButtonReturn
        // VERIFY: NSButton.hasDestructiveAction (macOS 11+) tints Delete.
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")                    // .alertThirdButtonReturn
        alert.buttons[2].keyEquivalent = "\u{1b}"               // Esc → Cancel
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:  self.saveTapped()
            case .alertSecondButtonReturn: self.discardAndFinish()
            default:                       break // Cancel: keep window open
            }
        }
    }

    /// Delete the raw recording and deliver `nil`.
    private func discardAndFinish() {
        if let sourceURL { try? FileManager.default.removeItem(at: sourceURL) }
        finish(with: nil)
    }

    // MARK: - Persisting to final location

    /// Move `tempURL` to its final home. Save now ALWAYS presents the
    /// save-location panel (as a sheet on the trimmer window) so the user sees
    /// and controls where the recording lands — cancelling it returns to the
    /// trimmer without losing data. This is the fix for "no clue where it's
    /// going": the previous default silently auto-filed into the recordings
    /// folder. The narrow silent auto-file path survives only when the user has
    /// explicitly opted out via the "Ask where to save each recording" toggle
    /// (which persists a user-domain value); on a fresh/default install the
    /// toggle sits at its registered default and we still show the dialog.
    /// Cleans up the raw source when a trimmed export replaced it, then delivers
    /// the final URL.
    private func persist(tempURL: URL) {
        let fileName = fileOrganizer.fileName(
            template: settings.recordingFilenameTemplate,
            date: recordingDate,
            ext: "mp4"
        )

        if userExplicitlyDisabledAsking {
            beginBusy("Saving…")
            do {
                let finalURL = try fileOrganizer.save(
                    tempURL: tempURL,
                    directory: settings.saveDirectoryURL,
                    fileName: fileName
                )
                cleanUpRawSource(movedTemp: tempURL)
                finish(with: finalURL)
            } catch {
                endBusy()
                showExportError(error)
            }
        } else {
            promptForSaveLocation(tempURL: tempURL, defaultName: fileName)
        }
    }

    /// Whether Save may skip the panel and auto-file silently. True only when the
    /// user has *explicitly* turned the "Ask where to save each recording" toggle
    /// OFF — i.e. a value was written to the persistent (user) domain and it is
    /// `false`. `AppSettings` registers a `false` *default* for this key, so a
    /// plain `object(forKey:)` would report a value even on first launch; reading
    /// the persistent domain instead excludes the registration domain, keeping
    /// the DEFAULT behavior "show the dialog."
    private var userExplicitlyDisabledAsking: Bool {
        guard let domainName = Bundle.main.bundleIdentifier,
              let userDomain = UserDefaults.standard.persistentDomain(forName: domainName),
              let stored = userDomain["askWhereToSaveRecordings"] as? Bool
        else { return false }
        return stored == false
    }

    /// Present an `NSSavePanel` starting at the remembered directory. On confirm,
    /// move the temp file to the chosen URL (honoring the panel's own overwrite
    /// decision), remember the directory, and finish. On cancel, return to the
    /// trimmer with the recording intact.
    private func promptForSaveLocation(tempURL: URL, defaultName: String) {
        guard let window else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        // VERIFY: UTType.mpeg4Movie is the .mp4 content type (UniformTypeIdentifiers).
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true

        let startDir = settings.lastRecordingSaveDirectoryURL
        if FileManager.default.fileExists(atPath: startDir.path) {
            panel.directoryURL = startDir
        } else {
            panel.directoryURL = settings.saveDirectoryURL
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else {
                // Cancelled the panel: keep the trimmer open, nothing lost.
                self.endBusy()
                return
            }
            self.beginBusy("Saving…")
            self.settings.lastRecordingSaveDirectoryPath = destination.deletingLastPathComponent().path
            do {
                // The panel already handled overwrite confirmation; honor its choice.
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                do {
                    try fm.moveItem(at: tempURL, to: destination)
                } catch {
                    try fm.copyItem(at: tempURL, to: destination)
                    try? fm.removeItem(at: tempURL)
                }
                self.cleanUpRawSource(movedTemp: tempURL)
                self.finish(with: destination)
            } catch {
                self.endBusy()
                self.showExportError(error)
            }
        }
    }

    /// When a trimmed export (a distinct temp file) was the thing we moved, the
    /// original raw recording is now redundant — remove it.
    private func cleanUpRawSource(movedTemp: URL) {
        guard let sourceURL, sourceURL != movedTemp else { return }
        try? FileManager.default.removeItem(at: sourceURL)
    }

    // MARK: - Trim-range computation

    /// Returns the trim range the user set, or `nil` if the handles are at the
    /// full bounds (i.e. no meaningful trim).
    private func currentTrimRange() -> CMTimeRange? {
        guard let item = player?.currentItem else { return nil }
        let duration = item.duration
        guard duration.isValid, duration.isNumeric, duration > .zero else { return nil }

        var start = CMTime.zero
        var end = duration

        let reverse = item.reversePlaybackEndTime   // trim start
        if reverse.isValid, reverse.isNumeric, reverse > .zero {
            start = reverse
        }
        let forward = item.forwardPlaybackEndTime    // trim end
        if forward.isValid, forward.isNumeric, forward < duration {
            end = forward
        }

        // Treat sub-frame differences as "no trim".
        let trimmedStart = start > CMTime(value: 1, timescale: 30)
        let trimmedEnd = end < (duration - CMTime(value: 1, timescale: 30))
        guard trimmedStart || trimmedEnd, end > start else { return nil }

        return CMTimeRange(start: start, end: end)
    }

    // MARK: - Export

    private enum ExportError: Error {
        case couldNotCreateSession
    }

    /// Passthrough export of `source` restricted to `timeRange`, written to a
    /// temp `.mp4`. Lossless and near-instant; cuts snap to nearest keyframe.
    nonisolated private static func export(source: URL, timeRange: CMTimeRange) async -> Result<URL, Error> {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return .failure(ExportError.couldNotCreateSession)
        }
        session.timeRange = timeRange

        let baseName = source.deletingPathExtension().lastPathComponent
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-trimmed-\(UUID().uuidString.prefix(8)).mp4")

        // export(to:) fails if the destination already exists.
        try? FileManager.default.removeItem(at: outURL)

        do {
            // Modern async export (macOS 15+). The old exportAsynchronously/
            // status API is deprecated. `isolation` defaults to the caller's.
            try await session.export(to: outURL, as: .mp4)
            return .success(outURL)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            return .failure(error)
        }
    }

    // MARK: - Busy UI state

    /// Enter a busy state (exporting or saving): disable controls, show a
    /// spinner + `message`, and block window close.
    private func beginBusy(_ message: String) {
        isExporting = true
        trimButton?.isEnabled = false
        saveButton?.isEnabled = false
        deleteButton?.isEnabled = false
        statusLabel?.stringValue = message
        spinner?.isHidden = false
        spinner?.startAnimation(nil)
    }

    private func endBusy() {
        isExporting = false
        trimButton?.isEnabled = (playerView?.canBeginTrimming ?? false)
        saveButton?.isEnabled = true
        deleteButton?.isEnabled = true
        statusLabel?.stringValue = ""
        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
    }

    private func showExportError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t export the trimmed recording"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: - Teardown

    /// Deliver the result exactly once, tear down, and close the window.
    private func finish(with url: URL?) {
        guard !didFinish else { return }
        didFinish = true

        player?.pause()
        trimStateTimer?.invalidate()
        trimStateTimer = nil

        let completion = self.completion
        self.completion = nil

        completion?(url)

        window?.orderOut(nil)
        // Drop the self-retention; may deallocate after this returns.
        TrimmerWindowController.liveControllers.remove(self)
    }
}

// MARK: - NSWindowDelegate

extension TrimmerWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Don't allow closing mid-export/-save.
        if isExporting { return false }
        // Already delivered a result → let it close.
        if didFinish { return true }
        // Unsaved recording: force an explicit Save / Delete / Cancel choice, then
        // close programmatically on Save or Delete.
        confirmClose()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Safety net: if the window is torn down without a delivered result,
        // treat it as a discard so the raw temp file isn't leaked.
        if !didFinish {
            discardAndFinish()
        }
    }
}
