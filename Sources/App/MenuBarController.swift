import AppKit
import Combine
import ScreenCaptureKit
import UniformTypeIdentifiers
import UserNotifications

/// Owns the status-bar item, its menu, and every long-lived feature service.
/// All the cross-module wiring lives here; `AppDelegate` just drives launch.
@MainActor
final class MenuBarController: NSObject {

    // MARK: - Status item
    private var statusItem: NSStatusItem!
    private var recordMenuItem: NSMenuItem?
    private var recordSubmenuItem: NSMenuItem?

    // MARK: - Services (owned)
    private let settings = AppSettings.shared
    private let clipboard: ClipboardManager
    private let screenshot = ScreenshotService()
    private let screenshotStore: ScreenshotStore
    private let screenshotHUD = ScreenshotHUDController()
    private let recorder = RecordingEngine()
    private let countdownOverlay = RecordingCountdownOverlay()
    private let fileOrganizer = FileOrganizer()
    private let hotkeys = HotkeyManager()
    private let permissions = PermissionsManager()
    private let historyPanel = ClipboardHistoryPanelController()
    private let notifier = RecordingNotifier()

    private lazy var settingsWindow = SettingsWindowController()
    private lazy var onboarding = OnboardingWindowController()

    // MARK: - Recording session state
    private var recordingStartDate: Date?
    /// Displays discovered for the "Record ▸" submenu. Cached so the submenu can be
    /// built synchronously on menu open; refreshed only when the screen layout
    /// actually changes (see `didChangeScreenParametersNotification`), not on every
    /// open — display enumeration is heavy.
    private var cachedDisplays: [SCDisplay] = []
    /// Token for the screen-layout-change observer that keeps `cachedDisplays` fresh.
    private var screenChangeObserver: NSObjectProtocol?

    // MARK: - Screenshot purge
    private var screenshotPurgeTimer: Timer?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    override init() {
        self.clipboard = ClipboardManager(
            retention: AppSettings.shared.retention,
            maxItems: AppSettings.shared.maxClipItems
        )
        self.screenshotStore = ScreenshotStore(
            directory: AppSettings.shared.screenshotDirectoryURL,
            retentionDays: AppSettings.shared.screenshotRetentionDays
        )
        super.init()
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    // MARK: - Install (called once at launch)
    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "Capture +")
        }
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu

        wireRecorder()
        wireNotifier()
        observeSettings()
        wireSettingsMenuShortcut()
    }

    /// Point the application menu's "Settings…" item (⌘,) at us. `MainMenu` builds
    /// that item target-less because it's constructed before this controller exists;
    /// we resolve it by tag now so ⌘, opens Settings from any Capture + window.
    private func wireSettingsMenuShortcut() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let settingsItem = appMenu.item(withTag: MainMenu.settingsMenuItemTag) else { return }
        settingsItem.target = self
        settingsItem.action = #selector(openSettingsMenu(_:))
    }

    /// Start background services + register global hotkeys. Called at launch.
    func startServices() {
        clipboard.start()
        startScreenshotPurge()
        startDisplayObservation()
        hotkeys.register(
            onCaptureRegion: { [weak self] in self?.performCaptureRegion() },
            onToggleRecording: { [weak self] in self?.performToggleRecording() },
            onShowHistory: { [weak self] in self?.performShowHistory() }
        )
    }

    /// Creates the screenshot folder if missing, purges expired shots once at launch,
    /// then hourly. Mirrors the clipboard purge timer's shape.
    private func startScreenshotPurge() {
        try? FileManager.default.createDirectory(
            at: settings.screenshotDirectoryURL, withIntermediateDirectories: true)
        // Purging only touches the filesystem — get it off the main thread so launch
        // isn't blocked scanning the screenshot folder.
        DispatchQueue.global(qos: .utility).async { [screenshotStore] in
            screenshotStore.purgeExpired()
        }

        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenshotStore.purgeExpired() }
        }
        // Hourly cleanup is not time-critical; a wide tolerance lets the OS coalesce
        // the wake for battery/efficiency.
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        screenshotPurgeTimer = timer
    }

    /// Refresh the cached display list once now, then keep it fresh only when the
    /// screen layout actually changes — instead of re-enumerating on every menu open.
    private func startDisplayObservation() {
        // Initial refresh so the "Record ▸" submenu is correct on first open.
        refreshDisplaysAndRebuildSubmenu()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplaysAndRebuildSubmenu() }
        }
    }

    func showOnboardingIfNeeded() {
        // First launch: open Settings (which now hosts the App Permissions section)
        // instead of a separate onboarding window.
        let key = "didOnboard"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        settingsWindow.show()
    }

    // MARK: - Menu construction
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Capture +", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(item("Screenshot Snippet", #selector(captureRegionMenu(_:)),
                          symbol: "camera.viewfinder", key: "2", modifiers: [.command, .shift]))

        let record = item("Start Recording", #selector(toggleRecordingMenu(_:)),
                          symbol: "record.circle", key: "1", modifiers: [.command, .shift])
        recordMenuItem = record
        menu.addItem(record)

        // Submenu of alternate recording sources (specific display, a window, or every
        // display at once). Named distinctly from "Start Recording" so it doesn't read as
        // the primary record button. Populated lazily (display discovery is async).
        let recordSub = NSMenuItem(title: "Record a Specific Source", action: nil, keyEquivalent: "")
        if let subImg = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil) {
            subImg.isTemplate = true
            recordSub.image = subImg
        }
        recordSub.submenu = NSMenu(title: "Record a Specific Source")
        recordSubmenuItem = recordSub
        menu.addItem(recordSub)
        rebuildRecordSubmenu()

        menu.addItem(item("Show Clipboard History", #selector(showHistoryMenu(_:)),
                          symbol: "clipboard", key: "v", modifiers: [.command, .shift]))

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettingsMenu(_:)),
                          symbol: "gearshape", key: ",", modifiers: .command))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Capture +",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    /// Builds a menu item with an optional SF Symbol icon (macOS-style, template-tinted)
    /// and an optional key-equivalent shown right-aligned next to the title.
    private func item(_ title: String,
                      _ action: Selector,
                      symbol: String? = nil,
                      key: String = "",
                      modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = modifiers
        mi.target = self
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            img.isTemplate = true
            mi.image = img
        }
        return mi
    }

    private func updateRecordMenuTitle() {
        let recording = recorder.isRecording
        recordMenuItem?.title = recording ? "Stop Recording" : "Start Recording"
        // Can't start a second session while one is running.
        recordSubmenuItem?.isEnabled = !recording
    }

    /// Rebuild the "Record ▸" submenu from `cachedDisplays`: one item per display,
    /// a "Window…" chooser, and — when 2+ displays exist — "All Displays".
    private func rebuildRecordSubmenu() {
        guard let submenu = recordSubmenuItem?.submenu else { return }
        submenu.removeAllItems()

        if cachedDisplays.isEmpty {
            let none = NSMenuItem(title: "No displays found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            for index in cachedDisplays.indices {
                let mi = item("Record Entire Display \(index + 1)",
                              #selector(recordDisplayMenu(_:)), symbol: "display")
                mi.tag = index
                submenu.addItem(mi)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(item("Record a Window…", #selector(recordWindowMenu(_:)), symbol: "macwindow"))

        if cachedDisplays.count >= 2 {
            submenu.addItem(item("Record All Displays (separate files)",
                                 #selector(recordAllDisplaysMenu(_:)), symbol: "display.2"))
        }
    }

    /// Refresh the cached display list off the main-menu open, then rebuild the
    /// submenu. Discovery is async; the submenu is already populated from the
    /// previous cache, so it's usable immediately and self-corrects on the next open.
    private func refreshDisplaysAndRebuildSubmenu() {
        Task { [weak self] in
            guard let self else { return }
            let displays = (try? await self.recorder.availableDisplays()) ?? []
            self.cachedDisplays = displays
            self.rebuildRecordSubmenu()
            self.updateRecordMenuTitle()
        }
    }

    // MARK: - Menu actions (@objc trampolines)
    @objc private func captureRegionMenu(_ sender: Any?) { performCaptureRegion() }
    @objc private func toggleRecordingMenu(_ sender: Any?) { performToggleRecording() }
    @objc private func recordDisplayMenu(_ sender: NSMenuItem) {
        guard cachedDisplays.indices.contains(sender.tag) else { return }
        beginRecording(target: .display(cachedDisplays[sender.tag]))
    }
    @objc private func recordWindowMenu(_ sender: Any?) { performRecordWindow() }
    @objc private func recordAllDisplaysMenu(_ sender: Any?) {
        guard cachedDisplays.count >= 2 else { return }
        beginRecording(target: .displays(cachedDisplays))
    }
    @objc private func showHistoryMenu(_ sender: Any?) { performShowHistory() }
    @objc private func openSettingsMenu(_ sender: Any?) { settingsWindow.show() }
    @objc private func openOnboardingMenu(_ sender: Any?) { onboarding.show() }

    // MARK: - Feature flows

    private func performCaptureRegion() {
        screenshot.captureRegion { [weak self] fileURL, image in
            guard let self, let image, let fileURL else { return }

            // A snippet is an INSTANT copy: put it on the clipboard right away and into
            // history, so it's already safe the moment the thumbnail appears — dismissing
            // (✕) can't lose it. Nothing is written to disk unless "Keep captured
            // screenshots" is on; otherwise the HUD acts on a throwaway temp file that's
            // deleted when the thumbnail dismisses.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            self.clipboard.ingestImage(image)
            // We wrote + ingested it ourselves; stop the poll re-adding a duplicate.
            self.clipboard.markCurrentPasteboardHandled()

            let stash = self.stashCapture(image: image, existingFile: fileURL)
            self.showScreenshotHUD(image: image, fileURL: stash.url, isTemp: stash.isTemp)
        }
    }

    /// Persist a capture for the HUD to act on. With "Keep captured screenshots" on, it
    /// goes into the purge-tracked library (persistent). Otherwise it's a throwaway temp
    /// file (`isTemp == true`) that's removed when the HUD dismisses.
    private func stashCapture(image: NSImage, existingFile: URL?) -> (url: URL, isTemp: Bool) {
        if settings.screenshotKeepEnabled {
            if let existingFile, let stored = screenshotStore.store(fileURL: existingFile, date: Date()) {
                return (stored, false)
            }
            if let stored = screenshotStore.store(image: image, date: Date()) { return (stored, false) }
            return (tempPNG(image), true)
        }
        if let existingFile { return (existingFile, true) }   // screencapture's own temp file
        return (tempPNG(image), true)
    }

    /// Write `image` to a throwaway temp PNG and return its URL.
    private func tempPNG(_ image: NSImage) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Capture +-\(UUID().uuidString).png")
        if let data = Self.pngData(from: image) { try? data.write(to: url) }
        return url
    }

    /// Presents the bottom-right thumbnail HUD for a fresh (or re-annotated) capture and
    /// wires its action buttons. `currentImage`/`currentURL` are captured mutably so an
    /// annotate round-trip can point later actions at the marked-up image on disk.
    private func showScreenshotHUD(image: NSImage, fileURL: URL, isTemp: Bool) {
        let currentImage = image
        let currentURL = fileURL

        let actions = ScreenshotHUDActions(
            onCopy: { [weak self] in
                // Copy to the clipboard — that's the whole point of a snippet. Nothing is
                // written to disk; the thumbnail auto-dismisses on its own.
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([currentImage])
                self?.clipboard.ingestImage(currentImage)
            },
            onAnnotate: { [weak self] in
                guard let self else { return }
                // Match the macOS thumbnail → Markup behavior: dismiss the corner card
                // first, then open the enlarged editor.
                self.screenshotHUD.dismiss()
                // Open the editor at the last screenshot save dir, falling back to the
                // managed screenshot folder if that path is gone.
                let last = self.settings.lastScreenshotSaveDirectoryURL
                let defaultDir = FileManager.default.fileExists(atPath: last.path)
                    ? last : self.settings.screenshotDirectoryURL
                let editor = AnnotationWindowController()
                editor.present(
                    image: currentImage,
                    suggestedName: "Screenshot",
                    defaultSaveDirectory: defaultDir,
                    onCopy: { [weak self] annotated in
                        // Copy: put the annotated image on the pasteboard + into history,
                        // then MINIMIZE BACK TO THE CORNER THUMBNAIL with the annotated image.
                        guard let self else { return }
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.writeObjects([annotated])
                        self.clipboard.ingestImage(annotated)
                        let stash = self.stashCapture(image: annotated, existingFile: nil)
                        self.showScreenshotHUD(image: annotated, fileURL: stash.url, isTemp: stash.isTemp)
                    },
                    onSave: { [weak self] annotated, url in
                        // Save: write the annotated PNG to the user-chosen URL, remember
                        // its folder as the last screenshot save dir, then reveal it.
                        guard let self else { return }
                        let fm = FileManager.default
                        do {
                            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                            if let data = Self.pngData(from: annotated) {
                                try data.write(to: url)
                            }
                            self.settings.lastScreenshotSaveDirectoryPath = url.deletingLastPathComponent().path
                            self.fileOrganizer.revealInFinder(url)
                        } catch {
                            self.presentError(error)
                        }
                    },
                    onDelete: { [weak self] in
                        // Destructive Delete confirmed in the editor: remove the stored
                        // screenshot from disk and make sure the HUD is gone.
                        guard let self else { return }
                        try? FileManager.default.removeItem(at: currentURL)
                        self.screenshotHUD.dismiss()
                    }
                )
            },
            onSaveAs: { [weak self] in
                // Dismiss the floating HUD FIRST so the save panel isn't opened behind it.
                self?.screenshotHUD.dismiss()
                self?.saveScreenshotAs(image: currentImage, suggestedURL: currentURL)
            },
            onSaveToDesktop: { [weak self] in
                self?.saveScreenshotToUserDirectory(
                    .desktopDirectory, image: currentImage, sourceURL: currentURL)
            },
            onSaveToDocuments: { [weak self] in
                self?.saveScreenshotToUserDirectory(
                    .documentDirectory, image: currentImage, sourceURL: currentURL)
            },
            onOpenInPreview: {
                Self.openInPreview(currentURL)
            },
            onShowInFinder: { [weak self] in
                self?.fileOrganizer.revealInFinder(currentURL)
            },
            onDelete: { [weak self] in
                // Remove the current (temp or stored) capture, then close the HUD.
                try? FileManager.default.removeItem(at: currentURL)
                self?.screenshotHUD.dismiss()
            },
            onClose: { [weak self] in
                self?.screenshotHUD.dismiss()
            },
            saveLocationName: isTemp ? "" : fileURL.deletingLastPathComponent().lastPathComponent,
            presets: settings.screenshotPresets,
            onSaveToPreset: { [weak self] preset in
                self?.saveScreenshot(currentImage, sourceURL: currentURL, to: preset)
            },
            onDismiss: {
                // A copy-only (temp) capture leaves nothing behind — clean up the temp file.
                if isTemp { try? FileManager.default.removeItem(at: fileURL) }
            }
        )

        screenshotHUD.show(image: image, fileURL: fileURL, actions: actions)
    }

    /// "Save As…" — lets the user save a copy of the capture anywhere. Runs through
    /// `SavePanelHelper` so it opens at (and remembers) the last screenshot save
    /// directory, falling back to the managed screenshot folder. Copies the stored
    /// PNG bytes when available (preserving the original), else re-encodes the image.
    private func saveScreenshotAs(image: NSImage, suggestedURL: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let settings = self.settings
        SavePanelHelper.presentSavePanel(
            suggestedName: suggestedURL.lastPathComponent,
            allowedType: .png,
            getLastDirectory: {
                // Prefer the last chosen save dir; fall back to the screenshot folder
                // if it's gone (SavePanelHelper only honors directories that exist).
                let last = settings.lastScreenshotSaveDirectoryURL
                return FileManager.default.fileExists(atPath: last.path)
                    ? last : settings.screenshotDirectoryURL
            },
            setLastDirectory: { settings.lastScreenshotSaveDirectoryPath = $0.path }
        ) { [weak self] dest in
            guard let self, let dest else { return }
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                if fm.fileExists(atPath: suggestedURL.path) {
                    try fm.copyItem(at: suggestedURL, to: dest)
                } else if let data = Self.pngData(from: image) {
                    try data.write(to: dest)
                }
            } catch {
                self.presentError(error)
            }
        }
    }

    /// Write the current capture into a standard user directory (Desktop / Documents) with
    /// a macOS-style timestamped name ("Screenshot <yyyy-MM-dd at HH.mm.ss>.png"). Prefers
    /// copying the on-disk PNG bytes when the source file exists; otherwise re-encodes the
    /// image. Chooses a collision-free name so repeated saves don't overwrite.
    private func saveScreenshotToUserDirectory(
        _ directory: FileManager.SearchPathDirectory, image: NSImage, sourceURL: URL
    ) {
        let fm = FileManager.default
        guard let dir = fm.urls(for: directory, in: .userDomainMask).first else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screenshot \(formatter.string(from: Date())).png"
        let dest = Self.uniqueDestination(dir.appendingPathComponent(name))
        do {
            if fm.fileExists(atPath: sourceURL.path) {
                try fm.copyItem(at: sourceURL, to: dest)
            } else if let data = Self.pngData(from: image) {
                try data.write(to: dest)
            }
        } catch {
            presentError(error)
        }
    }

    /// Open a capture in Preview.app, falling back to the default image app if Preview
    /// can't be found at its system path.
    private static func openInPreview(_ url: URL) {
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        if FileManager.default.fileExists(atPath: preview.path) {
            NSWorkspace.shared.open(
                [url], withApplicationAt: preview,
                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Copy the current capture into a "Save to ▸" preset folder, creating the folder if
    /// needed and choosing a collision-free name. Prefers copying the on-disk PNG bytes
    /// (preserving the original); falls back to re-encoding the image.
    private func saveScreenshot(_ image: NSImage, sourceURL: URL, to preset: ScreenshotPreset) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: preset.url, withIntermediateDirectories: true)
            let dest = Self.uniqueDestination(
                preset.url.appendingPathComponent(sourceURL.lastPathComponent))
            if fm.fileExists(atPath: sourceURL.path) {
                try fm.copyItem(at: sourceURL, to: dest)
            } else if let data = Self.pngData(from: image) {
                try data.write(to: dest)
            }
        } catch {
            presentError(error)
        }
    }

    /// Returns `url` if free, else appends " (2)", " (3)", … before the extension until a
    /// non-existent path is found.
    private static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) (\(n))")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// PNG-encodes an `NSImage` via its TIFF representation. Used only as the Save-As
    /// fallback when no on-disk source file exists.
    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func performShowHistory() {
        historyPanel.toggle(
            manager: clipboard,
            onPick: { [weak self] item in self?.clipboard.copy(item) }
        )
    }

    private func performToggleRecording() {
        if recorder.isRecording {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.recorder.stopRecording()
                } catch {
                    self.presentError(error)
                }
                self.updateRecordMenuTitle()
            }
        } else {
            // Top-level "Start Recording" → the common case: the main display.
            // Resolve the display, then funnel through beginRecording(target:) so the
            // pre-roll countdown fires here just like the submenu/hotkey entry points.
            Task { [weak self] in
                guard let self else { return }
                do {
                    let displays = try await self.recorder.availableDisplays()
                    guard let display = displays.first else {
                        throw RecordingError.noDisplayAvailable
                    }
                    self.cachedDisplays = displays
                    self.beginRecording(target: .display(display))
                } catch {
                    self.presentError(error)
                    self.updateRecordMenuTitle()
                }
            }
        }
        updateRecordMenuTitle()
    }

    /// Start a recording for an already-resolved target. Runs the pre-roll countdown
    /// (on the target's display) first so it isn't captured, then kicks off the engine
    /// and refreshes menu state; errors surface via `presentError`.
    ///
    /// Every start entry point (top-level "Start Recording", the submenu display/window/
    /// all-displays items, and the hotkey) funnels through here, so the countdown is
    /// applied uniformly. Stop does NOT pass through here, so it's never delayed.
    private func beginRecording(target: RecordingTarget) {
        // First actual recording: now ask for notification permission (so the
        // "Recording saved" banner can appear). Deferred from launch so users who
        // never record aren't prompted out of the blue. No-op on later recordings.
        notifier.requestAuthorizationIfNeeded()
        let targetScreen = screen(for: target)
        countdownOverlay.run(seconds: settings.recordingCountdownSeconds, on: targetScreen) { [weak self] in
            // Fires on the main thread once the countdown clears (or immediately when
            // the countdown is disabled). Hop explicitly onto the main actor to touch
            // the @MainActor engine + menu state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.startSession(target: target)
                } catch {
                    self.presentError(error)
                }
                self.updateRecordMenuTitle()
            }
        }
    }

    /// The `NSScreen` a recording target lives on, so the countdown overlay appears on
    /// that display. Windows and multi-display batches fall back to the main screen.
    private func screen(for target: RecordingTarget) -> NSScreen? {
        switch target {
        case .display(let display):
            let match = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == display.displayID
            }
            return match ?? NSScreen.main
        case .window, .displays:
            return NSScreen.main
        }
    }

    /// Resolve mic settings + temp output URLs for `target` and hand off to the
    /// engine. One URL per output file: 1 for a display/window, N for N displays.
    private func startSession(target: RecordingTarget) async throws {
        let includeMic = settings.recordMicrophoneByDefault
        let micID: String? = includeMic
            ? recorder.availableMicrophones().first?.uniqueID
            : nil

        let count: Int
        switch target {
        case .display, .window: count = 1
        case .displays(let displays): count = displays.count
        }

        let urls = (0..<count).map { _ in
            FileManager.default.temporaryDirectory
                .appendingPathComponent("Capture +-\(UUID().uuidString).mp4")
        }
        recordingStartDate = Date()

        try await recorder.startRecording(
            target: target,
            captureSystemAudio: settings.recordSystemAudio,
            includeMicrophone: includeMic,
            microphoneDeviceID: micID,
            maxHeight: settings.recordingResolutionHeight,
            outputURLs: urls
        )
    }

    /// "Window…" — discover shareable windows, let the user pick one, record it.
    private func performRecordWindow() {
        Task { [weak self] in
            guard let self else { return }
            let windows: [SCWindow]
            do {
                windows = try await self.recorder.availableWindows()
            } catch {
                self.presentError(error)
                return
            }

            // The picker needs a focusable window; briefly become a regular app.
            NSApp.setActivationPolicy(.regular)
            RecordingTargetPickerController().pickWindow(windows) { [weak self] chosen in
                guard let self else {
                    NSApp.setActivationPolicy(.accessory)
                    return
                }
                guard let chosen else {
                    // Cancelled — nothing recorded.
                    NSApp.setActivationPolicy(.accessory)
                    return
                }
                NSApp.setActivationPolicy(.accessory)
                self.beginRecording(target: .window(chosen))
            }
        }
    }

    private func wireRecorder() {
        recorder.onFinish = { [weak self] result in
            guard let self else { return }
            self.updateRecordMenuTitle()
            switch result {
            case .success(let urls):
                if urls.count > 1 {
                    // Multi-display: skip the trimmer (can't sync-trim N files),
                    // save each and post one summary notification.
                    self.saveMultipleRecordings(urls)
                } else if let url = urls.first {
                    self.presentTrimmer(for: url)
                }
            case .failure(let error):
                self.presentError(error)
            }
        }
    }

    private func presentTrimmer(for recordedURL: URL) {
        let date = recordingStartDate ?? Date()

        // The trimmer needs a real, focusable window; briefly become a regular app.
        NSApp.setActivationPolicy(.regular)

        let trimmer = TrimmerWindowController()
        // The trimmer now owns the full save lifecycle (trim → export → save/
        // discard) and returns the FINAL saved URL, or nil if discarded (in which
        // case it already deleted the raw temp file).
        trimmer.present(url: recordedURL, suggestedName: "Recording", date: date) { [weak self] savedURL in
            defer { NSApp.setActivationPolicy(.accessory) }
            guard let self else { return }
            guard let savedURL else { return } // discarded; nothing to notify
            self.notifier.notifySaved(url: savedURL)
        }
    }

    /// Save each file from a multi-display recording via `FileOrganizer` (auto-
    /// filed, or into a folder chosen once when "ask where to save" is on), then
    /// post a single "N recordings saved" notification. No trimmer for the batch.
    private func saveMultipleRecordings(_ urls: [URL]) {
        let date = recordingStartDate ?? Date()

        // Resolve the destination directory once for the whole batch.
        let directory: URL
        if settings.askWhereToSaveRecordings {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Save"
            panel.message = "Choose where to save \(urls.count) recordings"
            let startDir = settings.lastRecordingSaveDirectoryURL
            panel.directoryURL = FileManager.default.fileExists(atPath: startDir.path)
                ? startDir : settings.saveDirectoryURL

            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let response = panel.runModal()
            NSApp.setActivationPolicy(.accessory)

            guard response == .OK, let chosen = panel.url else {
                // Cancelled: discard the raw temp files.
                for url in urls { try? FileManager.default.removeItem(at: url) }
                return
            }
            settings.lastRecordingSaveDirectoryPath = chosen.path
            directory = chosen
        } else {
            directory = settings.saveDirectoryURL
        }

        var savedURLs: [URL] = []
        for url in urls {
            let name = fileOrganizer.fileName(
                template: settings.recordingFilenameTemplate,
                date: date,
                ext: "mp4"
            )
            do {
                let saved = try fileOrganizer.save(tempURL: url, directory: directory, fileName: name)
                savedURLs.append(saved)
            } catch {
                presentError(error)
            }
        }

        guard !savedURLs.isEmpty else { return }
        notifier.notifyMultipleSaved(urls: savedURLs)
    }

    private func wireNotifier() {
        notifier.onReveal = { [weak self] url in
            self?.fileOrganizer.revealInFinder(url)
        }
    }

    // MARK: - Settings observation
    private func observeSettings() {
        // Keep clipboard retention in sync with the live setting.
        settings.$retentionHours
            .sink { [weak self] hours in
                self?.clipboard.retention = Double(hours) * 3600
            }
            .store(in: &cancellables)

        // Keep the screenshot store's directory + retention in sync with settings.
        settings.$screenshotRetentionDays
            .sink { [weak self] days in
                self?.screenshotStore.retentionDays = days
            }
            .store(in: &cancellables)

        settings.$screenshotDirectoryPath
            .sink { [weak self] path in
                self?.screenshotStore.directory = URL(fileURLWithPath: path, isDirectory: true)
            }
            .store(in: &cancellables)
    }

    // MARK: - Error surface
    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Capture +"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - NSMenuDelegate
extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateRecordMenuTitle()
        // Rebuild "Record ▸" synchronously from the cached display list — no heavy
        // re-enumeration here. The cache is kept current by the screen-parameters
        // observer, so it already reflects monitors connected since last open.
        rebuildRecordSubmenu()
    }
}

// MARK: - Recording-saved notifications

/// Posts a local notification when a recording is saved, with a "Reveal in
/// Finder" action. Not `@MainActor`: `UNUserNotificationCenterDelegate` methods
/// are invoked off the main queue, so it hops to main before touching `onReveal`.
final class RecordingNotifier: NSObject, UNUserNotificationCenterDelegate {

    /// Called (on the main queue) when the user taps the notification or its
    /// "Reveal in Finder" action.
    var onReveal: ((URL) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let revealActionID = "CAPTUREPLUS_REVEAL"
    private let categoryID = "CAPTUREPLUS_RECORDING_SAVED"
    /// Whether we've already asked for notification authorization. The system only
    /// prompts once regardless, but this avoids redundant requests.
    private var didRequestAuthorization = false

    override init() {
        super.init()
        center.delegate = self

        let reveal = UNNotificationAction(identifier: revealActionID,
                                          title: "Reveal in Finder",
                                          options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [reveal],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
        // Authorization is NOT requested here — it's deferred to the first recording
        // (see `requestAuthorizationIfNeeded()`) so launch doesn't prompt users who
        // never record.
    }

    /// Requests notification authorization the first time a recording starts. Safe to
    /// call repeatedly; only the first call reaches the system.
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifySaved(url: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Recording saved"
        // State WHERE it landed: subtitle carries the containing folder name so the
        // user knows the destination at a glance; body is the file name.
        content.subtitle = "in \(url.deletingLastPathComponent().lastPathComponent)"
        content.body = url.lastPathComponent
        content.categoryIdentifier = categoryID
        content.userInfo = ["path": url.path]

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    /// Posts one summary notification for a multi-file (all-displays) recording.
    /// "Reveal in Finder" selects all the saved files at once.
    func notifyMultipleSaved(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(urls.count) recordings saved"
        // All files from one batch land in the same folder; name it in the subtitle.
        content.subtitle = "in \(urls[0].deletingLastPathComponent().lastPathComponent)"
        content.body = urls.map { $0.lastPathComponent }.joined(separator: ", ")
        content.categoryIdentifier = categoryID
        // Reveal the first file; onReveal selects it in its containing folder.
        content.userInfo = ["path": urls[0].path]

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    // Show a banner even while Capture + is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier
        if let path = userInfo["path"] as? String,
           actionID == "CAPTUREPLUS_REVEAL" || actionID == UNNotificationDefaultActionIdentifier {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async { [weak self] in
                self?.onReveal?(url)
            }
        }
        completionHandler()
    }
}
