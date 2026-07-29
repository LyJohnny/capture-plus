import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import KeyboardShortcuts

/// The settings form. Edits `AppSettings.shared` live; changes persist immediately.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var permissions = SettingsPermissionsModel()
    @State private var isEditingFilename = false
    /// Connected input devices for the microphone picker, refreshed on appear.
    @State private var microphones: [(id: String, name: String)] = []
    /// Whether Accessibility permission (needed by the scroll reverser) is granted.
    /// Refreshed on appear and when the toggle changes.
    @State private var axTrusted = ScrollReverser.hasPermission

    var body: some View {
        ScrollView {
            form
                // Let the grouped Form lay out at its natural full height so the
                // outer ScrollView owns the overflow. This keeps every section
                // reachable even when the window is shorter than the content.
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 460)
        .onAppear {
            permissions.refresh()
            refreshMicrophones()
            axTrusted = ScrollReverser.hasPermission
        }
    }

    /// Enumerate connected microphones and heal a stale selection (device unplugged
    /// since it was chosen) back to System Default so the picker never shows a
    /// selection that isn't in its list.
    private func refreshMicrophones() {
        microphones = RecordingEngine.availableMicrophones()
            .map { (id: $0.uniqueID, name: $0.localizedName) }
        if !settings.microphoneDeviceID.isEmpty,
           !microphones.contains(where: { $0.id == settings.microphoneDeviceID }) {
            settings.microphoneDeviceID = ""
        }
    }

    private var form: some View {
        Form {
            AboutView()

            Section("App Permissions") {
                PermissionRow(
                    title: "Screen Recording",
                    subtitle: "Required for recordings and region screenshots.",
                    state: permissions.screenRecordingState,
                    actionTitle: permissions.hasScreenRecording ? "Open Settings" : "Grant",
                    action: permissions.handleScreenRecording
                )
                PermissionRow(
                    title: "Microphone",
                    subtitle: "Only needed to record your voice with the screen.",
                    state: permissions.microphoneState,
                    actionTitle: permissions.microphoneActionTitle,
                    action: permissions.handleMicrophone
                )
                PermissionRow(
                    title: "Launch at Login",
                    subtitle: "Keep Capture + running whenever you log in.",
                    state: permissions.launchAtLoginState,
                    actionTitle: permissions.launchAtLogin ? "Turn Off" : "Turn On",
                    action: permissions.toggleLaunchAtLogin
                )
            }

            Section("Clipboard History") {
                HStack {
                    Text("Keep items for")
                    Spacer()
                    TextField("", value: $settings.retentionHours, format: .number)
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Text("h")
                    Stepper("", value: $settings.retentionHours, in: 1...24)
                        .labelsHidden()
                }
                HStack {
                    Text("Max items")
                    Spacer()
                    TextField("", value: $settings.maxClipItems, format: .number)
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: $settings.maxClipItems, in: 10...1000, step: 10)
                        .labelsHidden()
                }
            }

            Section("Recording") {
                Toggle("Capture system audio", isOn: $settings.recordSystemAudio)
                Toggle("Enable microphone during Screen recording", isOn: $settings.recordMicrophoneByDefault)
                if settings.recordMicrophoneByDefault {
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("Microphone", selection: $settings.microphoneDeviceID) {
                            Text("Automatic (built-in mic)").tag("")
                            ForEach(microphones, id: \.id) { mic in
                                Text(mic.name).tag(mic.id)
                            }
                        }
                        Text("Recording from a Bluetooth mic (like AirPods) drops ALL Mac "
                           + "audio to call quality while recording. Automatic uses the "
                           + "built-in mic so your headphones keep full quality.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Microphone volume")
                            Spacer()
                            Slider(
                                value: Binding(
                                    get: { Double(settings.microphoneGainPercent) },
                                    set: { settings.microphoneGainPercent = Int($0.rounded()) }
                                ),
                                in: 0...200, step: 5
                            )
                            .frame(width: 150)
                            .accessibilityLabel("Microphone volume")
                            Text("\(settings.microphoneGainPercent)%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        Text("100% is the mic's normal level. Applies from the next recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Countdown before recording", selection: $settings.recordingCountdownSeconds) {
                    Text("Off").tag(0)
                    Text("1 s").tag(1)
                    Text("3 s").tag(3)
                    Text("5 s").tag(5)
                }
                Picker("Resolution", selection: $settings.recordingResolutionHeight) {
                    Text(nativeResolutionLabel).tag(0)
                    Text("1080p (1920 × 1080) · ~60 MB/min").tag(1080)
                    Text("720p (1280 × 720) · ~30 MB/min").tag(720)
                }
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Filename format") {
                        HStack(spacing: 8) {
                            TextField("", text: $settings.recordingFilenameTemplate)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 240)
                                .disabled(!isEditingFilename)
                            Button(isEditingFilename ? "Done" : "Edit") {
                                isEditingFilename.toggle()
                            }
                        }
                    }
                    Text("Example: \(filenameExample(settings.recordingFilenameTemplate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Ask where to save each recording", isOn: $settings.askWhereToSaveRecordings)
                LabeledContent("Default location") {
                    HStack(spacing: 8) {
                        Text(settings.saveDirectoryPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…", action: chooseSaveDirectory)
                    }
                }
            }

            Section("Screenshots") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Keep captured screenshots", isOn: $settings.screenshotKeepEnabled)
                    Text("Off: screenshots are copy-only and never saved to disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if settings.screenshotKeepEnabled {
                    Stepper(value: $settings.screenshotRetentionDays, in: 1...365) {
                        LabeledContent("Keep files for", value: "\(settings.screenshotRetentionDays) d")
                    }
                }
                LabeledContent("Default location") {
                    HStack(spacing: 8) {
                        Text(settings.screenshotDirectoryPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…", action: chooseScreenshotDirectory)
                    }
                }
            }

            Section("Mouse") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Windows-style scrolling for mice", isOn: $settings.reverseMouseScrolling)
                        .onChange(of: settings.reverseMouseScrolling) { _, enabled in
                            axTrusted = ScrollReverser.hasPermission
                            if enabled && !axTrusted { ScrollReverser.promptForPermission() }
                        }
                    Text("Reverses scroll direction only when scrolling with a mouse — "
                       + "the trackpad keeps natural scrolling. Applies automatically "
                       + "whenever a mouse is used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.reverseMouseScrolling && !axTrusted {
                    HStack {
                        Label("Needs Accessibility permission to adjust scrolling.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Grant…") {
                            ScrollReverser.promptForPermission()
                        }
                    }
                }
            }

            Section("Shortcuts") {
                Text("Click a shortcut, then press your key combination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                KeyboardShortcuts.Recorder("Capture region", name: .captureRegion)
                KeyboardShortcuts.Recorder("Toggle recording", name: .toggleRecording)
                KeyboardShortcuts.Recorder("Clipboard history", name: .showClipboardHistory)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Derived labels

    /// The main display's native pixel size plus a rough storage estimate.
    private var nativeResolutionLabel: String {
        guard let screen = NSScreen.main else { return "Native · ~90 MB/min" }
        let scale = screen.backingScaleFactor
        let w = Int((screen.frame.size.width * scale).rounded())
        let h = Int((screen.frame.size.height * scale).rounded())
        return "Native (\(w) × \(h)) · ~90 MB/min"
    }

    /// Expand the filename template's tokens against the current date/time and
    /// append the recording extension, so the user sees a real example live.
    private func filenameExample(_ template: String) -> String {
        let now = Date()
        func formatted(_ format: String) -> String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = format
            return df.string(from: now)
        }
        var name = template
        name = name.replacingOccurrences(of: "{datetime}", with: formatted("yyyy-MM-dd 'at' HH.mm.ss"))
        name = name.replacingOccurrences(of: "{date}", with: formatted("yyyy-MM-dd"))
        name = name.replacingOccurrences(of: "{time}", with: formatted("HH.mm.ss"))
        return name + ".mp4"
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Capture + saves recordings"
        panel.directoryURL = settings.saveDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectoryPath = url.path
        }
    }

    private func chooseScreenshotDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Capture + saves screenshots"
        panel.directoryURL = settings.screenshotDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.screenshotDirectoryPath = url.path
        }
    }
}

// MARK: - App Permissions

/// A single permission/status row: status icon + title + subtitle + action button.
/// Modeled on `OnboardingRow`, minus the numbered index.
private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let state: OnboardingItemState
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol)
                .font(.system(size: 18))
                .foregroundStyle(state.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(actionTitle, action: action)
        }
        .padding(.vertical, 2)
    }
}

/// Bridges the settings permission rows to `PermissionsManager` + login-item
/// state. `@MainActor` because it touches AppKit/TCC APIs. This replaces the old
/// separate onboarding window — the same live status, inline in Settings.
@MainActor
final class SettingsPermissionsModel: ObservableObject {
    private let permissions = PermissionsManager()

    @Published private(set) var hasScreenRecording = false
    @Published private(set) var micStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var launchAtLogin = false

    init() { refresh() }

    /// Re-read all OS-owned state.
    func refresh() {
        hasScreenRecording = permissions.hasScreenRecordingPermission
        micStatus = permissions.microphoneStatus
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: Derived UI state

    var screenRecordingState: OnboardingItemState {
        hasScreenRecording ? .granted : .notGranted
    }

    var microphoneState: OnboardingItemState {
        switch micStatus {
        case .authorized:    return .granted
        case .notDetermined: return .optional
        default:             return .notGranted   // denied/restricted
        }
    }

    var microphoneActionTitle: String {
        switch micStatus {
        case .authorized:    return "Open Settings"
        case .notDetermined: return "Grant"
        default:             return "Open Settings"   // denied → must use Settings
        }
    }

    var launchAtLoginState: OnboardingItemState {
        launchAtLogin ? .granted : .optional
    }

    // MARK: Actions

    func handleScreenRecording() {
        if hasScreenRecording {
            permissions.openScreenRecordingSettings()
        } else {
            permissions.requestScreenRecording()
            permissions.openScreenRecordingSettings()
        }
        refresh()
    }

    func handleMicrophone() {
        if micStatus == .notDetermined {
            permissions.requestMicrophone { [weak self] _ in
                self?.refresh()
            }
        } else if micStatus != .authorized {
            permissions.openMicrophoneSettings()
        }
        refresh()
    }

    func toggleLaunchAtLogin() {
        AppSettings.shared.launchAtLogin.toggle()
        refresh()
    }
}

/// Hosts `SettingsView` in a normal titled window. Call `show()` to present it,
/// which also activates the app (needed since this is an accessory/menu-bar app).
@MainActor
final class SettingsWindowController: NSWindowController {

    /// Fixed content width; matches the SwiftUI `SettingsView` frame.
    private static let contentWidth: CGFloat = 460
    /// Margin kept between the window and the edges of the usable screen area.
    private static let screenMargin: CGFloat = 40

    convenience init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Capture + Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false

        // Natural content height the SwiftUI form wants, clamped so the window
        // never runs under the Dock or menu bar (which caused the cut-off bug).
        let desiredHeight = hosting.view.fittingSize.height
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let maxHeight = (visible?.height ?? 800) - Self.screenMargin
        let height = max(360, min(desiredHeight, maxHeight))

        window.setContentSize(NSSize(width: Self.contentWidth, height: height))
        window.contentMinSize = NSSize(width: Self.contentWidth, height: 360)
        window.contentMaxSize = NSSize(width: Self.contentWidth, height: .greatestFiniteMagnitude)

        self.init(window: window)
        positionWithinVisibleFrame()
    }

    /// Bring the settings window to front, activating the app first so it can
    /// receive focus from a background/accessory state. Reuses the existing
    /// window rather than spawning a duplicate.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window, !window.isVisible {
            clampHeightToVisibleFrame()
            positionWithinVisibleFrame()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Shrink the window height if the usable screen area got smaller (e.g. the
    /// Dock appeared, or it moved to a shorter display) so it stays fully on-screen.
    private func clampHeightToVisibleFrame() {
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        guard let maxHeight = visible.map({ $0.height - Self.screenMargin }) else { return }
        if window.frame.height > maxHeight {
            var frame = window.frame
            // Grow downward from the top edge so the title bar stays put.
            let top = frame.maxY
            frame.size.height = maxHeight
            frame.origin.y = top - maxHeight
            window.setFrame(frame, display: true)
        }
    }

    /// Center the window horizontally and place it near the top of the usable
    /// screen area, guaranteeing it sits entirely inside `visibleFrame`.
    private func positionWithinVisibleFrame() {
        guard let window else { return }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - (Self.screenMargin / 2)
        window.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, y)))
    }
}
