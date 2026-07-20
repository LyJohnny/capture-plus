import AppKit
import KeyboardShortcuts

// MARK: - Shortcut names

// These are referenced both here (to wire actions) and by the Settings module,
// which uses `KeyboardShortcuts.Recorder(for:)` to let the user rebind them.
// Defaults deliberately avoid the macOS system screenshot shortcuts
// (Cmd-Shift-3/4/5) and other well-known system bindings.
extension KeyboardShortcuts.Name {
    /// Region screenshot to clipboard. Default: Cmd-Shift-2.
    static let captureRegion = Self(
        "captureRegion",
        default: .init(.two, modifiers: [.command, .shift])
    )

    /// Start/stop screen recording. Default: Cmd-Shift-1.
    static let toggleRecording = Self(
        "toggleRecording",
        default: .init(.one, modifiers: [.command, .shift])
    )

    /// Show the clipboard-history popup. Default: Cmd-Shift-V.
    static let showClipboardHistory = Self(
        "showClipboardHistory",
        default: .init(.v, modifiers: [.command, .shift])
    )
}

// MARK: - HotkeyManager

/// Wires the three global shortcuts to caller-supplied closures.
///
/// Loosely coupled: the owner passes in what each hotkey should do; this class
/// knows nothing about recording, clipboard, or screenshots. All callbacks are
/// delivered on the main queue.
@MainActor
final class HotkeyManager {
    /// Retained so callers don't have to; nil until `register` is called.
    private var onCaptureRegion: (() -> Void)?
    private var onToggleRecording: (() -> Void)?
    private var onShowHistory: (() -> Void)?

    init() {}

    /// Register handlers for all three global shortcuts. Call once at launch.
    /// Calling again replaces the previously registered handlers.
    func register(
        onCaptureRegion: @escaping () -> Void,
        onToggleRecording: @escaping () -> Void,
        onShowHistory: @escaping () -> Void
    ) {
        self.onCaptureRegion = onCaptureRegion
        self.onToggleRecording = onToggleRecording
        self.onShowHistory = onShowHistory

        KeyboardShortcuts.onKeyUp(for: .captureRegion) { [weak self] in
            self?.dispatch { $0.onCaptureRegion }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.dispatch { $0.onToggleRecording }
        }
        KeyboardShortcuts.onKeyUp(for: .showClipboardHistory) { [weak self] in
            self?.dispatch { $0.onShowHistory }
        }
    }

    /// Temporarily disable all shortcuts (e.g. while a Recorder is capturing,
    /// or during a modal capture flow). Handlers stay registered.
    func setEnabled(_ enabled: Bool) {
        KeyboardShortcuts.isEnabled = enabled
    }

    // KeyboardShortcuts already delivers on the main thread, but we hop
    // explicitly so callers can rely on it regardless of package internals.
    private func dispatch(_ pick: (HotkeyManager) -> (() -> Void)?) {
        let action = pick(self)
        if Thread.isMainThread {
            action?()
        } else {
            DispatchQueue.main.async { action?() }
        }
    }
}
