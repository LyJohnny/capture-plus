import Foundation
import Combine
import ServiceManagement

/// The single app-wide settings store (the one allowed singleton).
/// Backed by `UserDefaults`; every property is `@Published` so SwiftUI views
/// observing `AppSettings.shared` update live, and each `didSet` persists.
///
/// Other modules should take primitives in their init (e.g. `retention: TimeInterval`)
/// rather than importing this type; this stays the config source of truth.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: Persisted keys

    private enum Key {
        static let retentionHours = "retentionHours"
        static let maxClipItems = "maxClipItems"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophoneByDefault = "recordMicrophoneByDefault"
        static let saveDirectoryPath = "saveDirectoryPath"
        static let recordingFilenameTemplate = "recordingFilenameTemplate"
        static let askWhereToSaveRecordings = "askWhereToSaveRecordings"
        static let lastRecordingSaveDirectoryPath = "lastRecordingSaveDirectoryPath"
        static let launchAtLogin = "launchAtLogin"
        static let screenshotRetentionDays = "screenshotRetentionDays"
        static let screenshotDirectoryPath = "screenshotDirectoryPath"
        static let askWhereToSaveScreenshots = "askWhereToSaveScreenshots"
        static let lastScreenshotSaveDirectoryPath = "lastScreenshotSaveDirectoryPath"
        static let screenshotPresets = "screenshotPresets"
        static let recordingCountdownSeconds = "recordingCountdownSeconds"
        static let screenshotKeepEnabled = "screenshotKeepEnabled"
        static let recordingResolutionHeight = "recordingResolutionHeight"
    }

    // MARK: Defaults

    private enum Default {
        static let retentionHours = 5
        static let maxClipItems = 200
        static let recordSystemAudio = true
        static let recordMicrophoneByDefault = false
        static let recordingFilenameTemplate = "Recording_{date}_{time}"
        static let askWhereToSaveRecordings = false
        static let launchAtLogin = false
        static let screenshotRetentionDays = 30
        static let askWhereToSaveScreenshots = false
        static let recordingCountdownSeconds = 3
        static let screenshotKeepEnabled = false
        static let recordingResolutionHeight = 0   // 0 == native
        static var saveDirectoryPath: String {
            let movies = FileManager.default
                .urls(for: .moviesDirectory, in: .userDomainMask)
                .first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
            return movies.appendingPathComponent("Capture +").path
        }
        static var screenshotDirectoryPath: String {
            let pictures = FileManager.default
                .urls(for: .picturesDirectory, in: .userDomainMask)
                .first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
            return pictures.appendingPathComponent("Capture + Screenshots").path
        }
    }

    private let defaults: UserDefaults

    // MARK: Published, persisted properties

    /// Clipboard-history retention window, in hours. Clamped to 1...24.
    @Published var retentionHours: Int {
        didSet {
            let clamped = min(max(retentionHours, 1), 24)
            if clamped != retentionHours { retentionHours = clamped; return }
            defaults.set(retentionHours, forKey: Key.retentionHours)
        }
    }

    /// Maximum number of clipboard-history items kept. Clamped to 10...1000.
    @Published var maxClipItems: Int {
        didSet {
            let clamped = min(max(maxClipItems, 10), 1000)
            if clamped != maxClipItems { maxClipItems = clamped; return }
            defaults.set(maxClipItems, forKey: Key.maxClipItems)
        }
    }

    /// Capture system audio while recording the screen.
    @Published var recordSystemAudio: Bool {
        didSet { defaults.set(recordSystemAudio, forKey: Key.recordSystemAudio) }
    }

    /// Start recordings with the microphone enabled by default.
    @Published var recordMicrophoneByDefault: Bool {
        didSet { defaults.set(recordMicrophoneByDefault, forKey: Key.recordMicrophoneByDefault) }
    }

    /// Absolute filesystem path recordings are saved under.
    @Published var saveDirectoryPath: String {
        didSet { defaults.set(saveDirectoryPath, forKey: Key.saveDirectoryPath) }
    }

    /// Filename template for saved recordings. Tokens: `{date}` (YYYY-MM-DD),
    /// `{time}` (HH.mm.ss), `{datetime}` (YYYY-MM-DD at HH.mm.ss). Expanded by
    /// `FileOrganizer.fileName(template:date:ext:)`.
    @Published var recordingFilenameTemplate: String {
        didSet { defaults.set(recordingFilenameTemplate, forKey: Key.recordingFilenameTemplate) }
    }

    /// When `true`, saving a recording prompts with an `NSSavePanel`; when
    /// `false`, recordings auto-save into the recordings folder.
    @Published var askWhereToSaveRecordings: Bool {
        didSet { defaults.set(askWhereToSaveRecordings, forKey: Key.askWhereToSaveRecordings) }
    }

    /// Directory the "save where?" panel last landed in; the panel reopens here.
    @Published var lastRecordingSaveDirectoryPath: String {
        didSet { defaults.set(lastRecordingSaveDirectoryPath, forKey: Key.lastRecordingSaveDirectoryPath) }
    }

    /// Whether Capture + is registered as a macOS login item.
    /// Setting this drives `SMAppService.mainApp` register/unregister.
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    /// Number of days region screenshots are kept on disk before purge. Clamped to 1...365.
    @Published var screenshotRetentionDays: Int {
        didSet {
            let clamped = min(max(screenshotRetentionDays, 1), 365)
            if clamped != screenshotRetentionDays { screenshotRetentionDays = clamped; return }
            defaults.set(screenshotRetentionDays, forKey: Key.screenshotRetentionDays)
        }
    }

    /// Absolute filesystem path region screenshots are saved under.
    @Published var screenshotDirectoryPath: String {
        didSet { defaults.set(screenshotDirectoryPath, forKey: Key.screenshotDirectoryPath) }
    }

    /// When `true`, saving a screenshot prompts with an `NSSavePanel`; when
    /// `false`, screenshots auto-save into the screenshot folder.
    @Published var askWhereToSaveScreenshots: Bool {
        didSet { defaults.set(askWhereToSaveScreenshots, forKey: Key.askWhereToSaveScreenshots) }
    }

    /// Directory the screenshot "save where?" panel last landed in; the panel reopens here.
    @Published var lastScreenshotSaveDirectoryPath: String {
        didSet { defaults.set(lastScreenshotSaveDirectoryPath, forKey: Key.lastScreenshotSaveDirectoryPath) }
    }

    /// User-defined "Save to ▸" folder presets shown in the screenshot HUD. Stored as a
    /// JSON blob in `UserDefaults` (not a plist primitive), encoded on every mutation.
    @Published var screenshotPresets: [ScreenshotPreset] {
        didSet {
            let data = (try? JSONEncoder().encode(screenshotPresets)) ?? Data()
            defaults.set(data, forKey: Key.screenshotPresets)
        }
    }

    /// Seconds counted down before a screen recording actually starts. Clamped to 0...10;
    /// `0` disables the countdown.
    @Published var recordingCountdownSeconds: Int {
        didSet {
            let clamped = min(max(recordingCountdownSeconds, 0), 10)
            if clamped != recordingCountdownSeconds { recordingCountdownSeconds = clamped; return }
            defaults.set(recordingCountdownSeconds, forKey: Key.recordingCountdownSeconds)
        }
    }

    /// When `true`, captured screenshots are saved into the screenshot folder and
    /// kept for `screenshotRetentionDays` before auto-purge. When `false` (default),
    /// a screenshot is a one-time thing: Copy puts it on the clipboard and nothing is
    /// written to disk unless the user explicitly Saves it.
    @Published var screenshotKeepEnabled: Bool {
        didSet { defaults.set(screenshotKeepEnabled, forKey: Key.screenshotKeepEnabled) }
    }

    /// Target height (px) for screen recordings. `0` records at the display's native
    /// resolution; otherwise the capture is scaled to this height (e.g. 1080, 720),
    /// preserving aspect ratio.
    @Published var recordingResolutionHeight: Int {
        didSet { defaults.set(recordingResolutionHeight, forKey: Key.recordingResolutionHeight) }
    }

    // MARK: Derived

    /// Retention window as a `TimeInterval`, for services that take seconds.
    var retention: TimeInterval { Double(retentionHours) * 3600 }

    /// The save directory as a file URL.
    var saveDirectoryURL: URL { URL(fileURLWithPath: saveDirectoryPath, isDirectory: true) }

    /// The last "save where?" directory as a file URL.
    var lastRecordingSaveDirectoryURL: URL { URL(fileURLWithPath: lastRecordingSaveDirectoryPath, isDirectory: true) }

    /// The screenshot directory as a file URL.
    var screenshotDirectoryURL: URL { URL(fileURLWithPath: screenshotDirectoryPath, isDirectory: true) }

    /// The last screenshot "save where?" directory as a file URL.
    var lastScreenshotSaveDirectoryURL: URL { URL(fileURLWithPath: lastScreenshotSaveDirectoryPath, isDirectory: true) }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Register code-level defaults so first-launch reads return sensible values.
        defaults.register(defaults: [
            Key.retentionHours: Default.retentionHours,
            Key.maxClipItems: Default.maxClipItems,
            Key.recordSystemAudio: Default.recordSystemAudio,
            Key.recordMicrophoneByDefault: Default.recordMicrophoneByDefault,
            Key.recordingFilenameTemplate: Default.recordingFilenameTemplate,
            Key.askWhereToSaveRecordings: Default.askWhereToSaveRecordings,
            Key.lastRecordingSaveDirectoryPath: Default.saveDirectoryPath,
            Key.launchAtLogin: Default.launchAtLogin,
            Key.saveDirectoryPath: Default.saveDirectoryPath,
            Key.screenshotRetentionDays: Default.screenshotRetentionDays,
            Key.screenshotDirectoryPath: Default.screenshotDirectoryPath,
            Key.askWhereToSaveScreenshots: Default.askWhereToSaveScreenshots,
            Key.lastScreenshotSaveDirectoryPath: Default.screenshotDirectoryPath,
            Key.recordingCountdownSeconds: Default.recordingCountdownSeconds,
            Key.screenshotKeepEnabled: Default.screenshotKeepEnabled,
            Key.recordingResolutionHeight: Default.recordingResolutionHeight,
        ])

        self.retentionHours = defaults.integer(forKey: Key.retentionHours)
        self.maxClipItems = defaults.integer(forKey: Key.maxClipItems)
        self.recordSystemAudio = defaults.bool(forKey: Key.recordSystemAudio)
        self.recordMicrophoneByDefault = defaults.bool(forKey: Key.recordMicrophoneByDefault)
        self.saveDirectoryPath = defaults.string(forKey: Key.saveDirectoryPath) ?? Default.saveDirectoryPath
        self.recordingFilenameTemplate = defaults.string(forKey: Key.recordingFilenameTemplate) ?? Default.recordingFilenameTemplate
        self.askWhereToSaveRecordings = defaults.bool(forKey: Key.askWhereToSaveRecordings)
        self.lastRecordingSaveDirectoryPath = defaults.string(forKey: Key.lastRecordingSaveDirectoryPath) ?? Default.saveDirectoryPath
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        self.screenshotRetentionDays = defaults.integer(forKey: Key.screenshotRetentionDays)
        self.screenshotDirectoryPath = defaults.string(forKey: Key.screenshotDirectoryPath) ?? Default.screenshotDirectoryPath
        self.askWhereToSaveScreenshots = defaults.bool(forKey: Key.askWhereToSaveScreenshots)
        self.lastScreenshotSaveDirectoryPath = defaults.string(forKey: Key.lastScreenshotSaveDirectoryPath) ?? Default.screenshotDirectoryPath
        self.recordingCountdownSeconds = defaults.integer(forKey: Key.recordingCountdownSeconds)
        self.screenshotKeepEnabled = defaults.bool(forKey: Key.screenshotKeepEnabled)
        self.recordingResolutionHeight = defaults.integer(forKey: Key.recordingResolutionHeight)
        if let data = defaults.data(forKey: Key.screenshotPresets),
           let decoded = try? JSONDecoder().decode([ScreenshotPreset].self, from: data) {
            self.screenshotPresets = decoded
        } else {
            self.screenshotPresets = []
        }

        // One-time migration: if the stored filename template is the OLD default
        // ("Recording {datetime}"), replace it with the current default. Custom
        // templates are left untouched. (This is a real mutation, so didSet persists it.)
        if recordingFilenameTemplate == "Recording {datetime}" {
            recordingFilenameTemplate = Default.recordingFilenameTemplate
        }
    }

    // MARK: Login item

    /// Reconcile the persisted `launchAtLogin` preference with the actual
    /// `SMAppService` registration. Safe to call at launch.
    func syncLoginItemState() {
        // If the real registration drifted from our stored preference, re-apply.
        let isRegistered = SMAppService.mainApp.status == .enabled
        if isRegistered != launchAtLogin {
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        // VERIFY: SMAppService.mainApp register()/unregister() throw; .status is
        // SMAppService.Status with case .enabled (macOS 13+). API confirmed stable.
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Capture +: failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
        }
    }

    // MARK: Screenshot preset helpers

    /// Append a new folder preset. No-op if `path` is empty.
    func addScreenshotPreset(name: String, path: String) {
        guard !path.isEmpty else { return }
        screenshotPresets.append(ScreenshotPreset(name: name, path: path))
    }

    /// Update an existing preset in place, matched by `id`. No-op if not found.
    func updateScreenshotPreset(_ preset: ScreenshotPreset) {
        guard let idx = screenshotPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        screenshotPresets[idx] = preset
    }

    /// Remove the preset with the given `id`, if present.
    func removeScreenshotPreset(id: ScreenshotPreset.ID) {
        screenshotPresets.removeAll { $0.id == id }
    }

    // MARK: Directory helper

    /// Ensure the configured save directory exists, creating it if needed.
    @discardableResult
    func ensureSaveDirectoryExists() -> Bool {
        do {
            try FileManager.default.createDirectory(at: saveDirectoryURL, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("Capture +: failed to create save directory at \(saveDirectoryPath): \(error.localizedDescription)")
            return false
        }
    }
}
