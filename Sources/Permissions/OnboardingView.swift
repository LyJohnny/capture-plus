import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement

// MARK: - Onboarding checklist view

/// First-launch checklist that walks the user through the four things Capture +
/// needs per Mac: Screen Recording, Microphone (optional), Clipboard
/// "Always Allow" (Tahoe), and Launch at Login.
///
/// Purely self-contained: it owns a `PermissionsManager` and re-reads live
/// status each time the window becomes key (the OS grants happen out-of-process,
/// so we can't observe them directly — we poll on appear + on a manual refresh).
struct OnboardingView: View {
    /// Called when the user taps "Done" / closes onboarding.
    var onFinish: () -> Void

    @StateObject private var model = OnboardingModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                OnboardingRow(
                    index: 1,
                    title: "Screen Recording",
                    subtitle: "Required for recordings and region screenshots.",
                    state: model.screenRecordingState,
                    actionTitle: model.hasScreenRecording ? "Open Settings" : "Grant Access",
                    action: model.handleScreenRecording
                )

                OnboardingRow(
                    index: 2,
                    title: "Microphone",
                    subtitle: "Optional — only needed to record your voice with the screen.",
                    state: model.microphoneState,
                    actionTitle: model.microphoneActionTitle,
                    action: model.handleMicrophone
                )

                OnboardingRow(
                    index: 3,
                    title: "Clipboard Access",
                    subtitle: model.pasteboardGuidance,
                    state: model.pasteboardState,
                    actionTitle: "Open Settings",
                    action: model.handlePasteboard
                )

                OnboardingRow(
                    index: 4,
                    title: "Launch at Login",
                    subtitle: "Keep clipboard history running whenever you log in.",
                    state: model.launchAtLoginState,
                    actionTitle: model.launchAtLogin ? "Turn Off" : "Turn On",
                    action: model.toggleLaunchAtLogin
                )
            }
            .padding(20)

            Divider()

            HStack {
                Button("Refresh Status") { model.refresh() }
                Spacer()
                Button("Done") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Capture +")
                    .font(.title2).bold()
                Text("Grant a few permissions and you\u{2019}re set.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }
}

// MARK: - Row

/// Visual status of a single checklist item.
enum OnboardingItemState {
    case granted
    case notGranted
    case optional      // not granted, but the user can safely skip it
    case unknown       // can't determine (e.g. Tahoe pasteboard detection)

    var symbol: String {
        switch self {
        case .granted:    return "checkmark.circle.fill"
        case .notGranted: return "exclamationmark.circle.fill"
        case .optional:   return "circle.dashed"
        case .unknown:    return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .granted:    return .green
        case .notGranted: return .orange
        case .optional:   return .secondary
        case .unknown:    return .yellow
        }
    }
}

private struct OnboardingRow: View {
    let index: Int
    let title: String
    let subtitle: String
    let state: OnboardingItemState
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol)
                .font(.system(size: 20))
                .foregroundStyle(state.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(index). \(title)")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if state != .granted {
                Button(actionTitle, action: action)
            }
        }
    }
}

extension OnboardingItemState: Equatable {}

// MARK: - View model

/// Bridges the SwiftUI view to `PermissionsManager` + login-item state, and
/// republishes live status. `@MainActor` because it touches AppKit/TCC APIs.
@MainActor
final class OnboardingModel: ObservableObject {
    private let permissions = PermissionsManager()

    @Published private(set) var hasScreenRecording = false
    @Published private(set) var micStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var pasteboardAccess: PermissionsManager.PasteboardAccess = .unknown
    @Published private(set) var launchAtLogin = false

    init() { refresh() }

    /// Re-read all OS-owned state.
    func refresh() {
        hasScreenRecording = permissions.hasScreenRecordingPermission
        micStatus = permissions.microphoneStatus
        pasteboardAccess = permissions.pasteboardAccess
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: Derived UI state

    var screenRecordingState: OnboardingItemState {
        hasScreenRecording ? .granted : .notGranted
    }

    var microphoneState: OnboardingItemState {
        switch micStatus {
        case .authorized:   return .granted
        case .notDetermined: return .optional
        default:            return .notGranted   // denied/restricted
        }
    }

    var microphoneActionTitle: String {
        switch micStatus {
        case .notDetermined: return "Grant Access"
        default:             return "Open Settings"   // denied → must use Settings
        }
    }

    var pasteboardState: OnboardingItemState {
        switch pasteboardAccess {
        case .allow:   return .granted
        case .ask:     return .optional   // fine on stock macOS; no prompts
        case .deny:    return .notGranted // explicitly blocked → needs fixing
        case .unknown: return .optional
        }
    }

    var pasteboardGuidance: String { permissions.pasteboardGuidance }

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
        } else if micStatus == .authorized {
            // already granted; nothing to do
        } else {
            permissions.openMicrophoneSettings()
        }
        refresh()
    }

    func handlePasteboard() {
        permissions.openPasteboardSettings()
        refresh()
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Capture +: launch-at-login toggle failed: \(error)")
        }
        refresh()
    }
}

// MARK: - Window controller

/// Hosts `OnboardingView` in a standard window and gates first-run display via
/// a UserDefaults flag.
@MainActor
final class OnboardingWindowController {
    private static let didOnboardKey = "didOnboard"

    private var window: NSWindow?

    init() {}

    /// Shows onboarding only on the first launch (until the user finishes it).
    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didOnboardKey) else { return }
        show()
    }

    /// Always shows the onboarding window (used by a "Show Onboarding" menu item).
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = OnboardingView { [weak self] in
            self?.finish()
        }
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Capture + Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.didOnboardKey)
        window?.close()
    }
}
