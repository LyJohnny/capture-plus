import AppKit
import AVFoundation
import CoreGraphics

/// Central helper for the OS permissions Capture + needs: Screen Recording (TCC),
/// Microphone, and macOS 26 (Tahoe) pasteboard "Always Allow" guidance.
///
/// Pure helper — owns no state beyond what the OS already tracks. UI code
/// (OnboardingView) reads the status vars and calls the request/open helpers.
@MainActor
final class PermissionsManager {

    init() {}

    // MARK: - Screen Recording (TCC)

    /// True if Capture + already has Screen Recording permission. Does NOT prompt.
    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system Screen Recording permission prompt (first call only;
    /// subsequently the user must toggle it in System Settings). Returns the
    /// immediate result — usually `false` on the very first call because the
    /// grant takes effect after the app is relaunched.
    @discardableResult
    func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Opens System Settings → Privacy & Security → Screen Recording.
    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    // MARK: - Microphone

    /// Current microphone authorization status (`.audio`).
    var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// True if microphone access is already authorized.
    var hasMicrophonePermission: Bool {
        microphoneStatus == .authorized
    }

    /// Requests microphone access. If the status is not `.notDetermined` the
    /// completion fires immediately with the effective grant. Completion is
    /// delivered on the main actor.
    func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch microphoneStatus {
        case .authorized:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        @unknown default:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    /// Opens System Settings → Privacy & Security → Microphone.
    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: - Pasteboard access ("Paste from Other Apps", macOS 15.4+)

    /// How the OS currently gates Capture +'s programmatic pasteboard reads.
    /// Backed by `NSPasteboard.accessBehavior` (macOS 15.4+).
    ///
    /// Important: the per-read privacy *prompt* is a developer preview that is
    /// OFF by default through macOS 26 (Tahoe), so on a normal setup `.ask`
    /// means "no prompts in practice" — clipboard history just works. Only
    /// `.deny` (the user explicitly chose Always Deny) actually blocks it.
    enum PasteboardAccess {
        /// Explicitly "Always Allow", or pre-15.4 (unrestricted).
        case allow
        /// Default. Not prompted unless the OS preview is enabled.
        case ask
        /// "Always Deny" — clipboard history is blocked.
        case deny
        /// Could not determine.
        case unknown
    }

    /// Reads the real access behavior on macOS 15.4+; unrestricted below that.
    var pasteboardAccess: PasteboardAccess {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return .allow
            case .alwaysDeny:  return .deny
            case .ask:         return .ask
            @unknown default:  return .unknown
            }
        } else {
            // Pre-15.4: no per-app pasteboard gating, reads are unrestricted.
            return .allow
        }
    }

    /// Clipboard history works unless the user explicitly set Always Deny.
    var pasteboardOK: Bool {
        pasteboardAccess != .deny
    }

    /// Human-readable guidance for the onboarding row.
    var pasteboardGuidance: String {
        switch pasteboardAccess {
        case .allow:
            return "Clipboard access is allowed \u{2014} nothing to do."
        case .ask, .unknown:
            return "No action needed. macOS normally won\u{2019}t prompt for this. "
                + "If you ever see repeated \u{201C}Allow Paste\u{201D} prompts, set Capture + to "
                + "Allow in Privacy & Security \u{2192} Paste from Other Apps."
        case .deny:
            return "Clipboard history is blocked. Open Privacy & Security \u{2192} "
                + "Paste from Other Apps and set Capture + to Allow."
        }
    }

    /// Opens System Settings → Privacy & Security → Paste from Other Apps.
    func openPasteboardSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
    }

    // MARK: - Helpers

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
