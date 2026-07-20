import AppKit
import UniformTypeIdentifiers

/// Presents an `NSSavePanel` and remembers the last-used directory, so callers
/// get "remember last location" for free for both `.png` screenshots and
/// `.mp4` recordings.
///
/// Generic and dependency-free: it does not import `AppSettings`. Callers either
/// pass a `defaultDirectory` and persist the chosen directory themselves, or use
/// the `lastDirectory` get/set closure convenience which reads the start
/// directory and writes it back on confirm.
@MainActor
enum SavePanelHelper {

    /// Present a save panel and invoke `onComplete` with the chosen URL (or `nil`
    /// on cancel). The CALLER is responsible for persisting the directory of the
    /// returned URL (`url.deletingLastPathComponent()`).
    ///
    /// - Parameters:
    ///   - suggestedName: pre-filled file name (with extension, e.g. `Capture + 2026-07-17.png`).
    ///   - allowedType: restricts the panel's content types (e.g. `.png`, `.mpeg4Movie`); `nil` allows any.
    ///   - defaultDirectory: directory the panel opens in; falls back to the system default if `nil` or missing.
    ///   - window: if provided, the panel is shown as a sheet on that window; otherwise it runs app-modal.
    ///   - onComplete: called with the chosen URL, or `nil` if the user cancelled.
    static func presentSavePanel(
        suggestedName: String,
        allowedType: UTType?,
        defaultDirectory: URL?,
        window: NSWindow? = nil,
        onComplete: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let allowedType {
            panel.allowedContentTypes = [allowedType]
        }
        if let defaultDirectory,
           FileManager.default.fileExists(atPath: defaultDirectory.path) {
            panel.directoryURL = defaultDirectory
        }

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                onComplete(nil)
                return
            }
            onComplete(url)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            // Menu-bar accessory app: without activation the app-modal panel can
            // open behind other apps' windows. Activate so the panel comes forward
            // (it becomes key on runModal; activation ensures it's frontmost).
            NSApp.activate(ignoringOtherApps: true)
            handler(panel.runModal())
        }
    }

    /// Convenience over `presentSavePanel` that reads the starting directory via
    /// `getLastDirectory` and, on confirm, writes the chosen directory back via
    /// `setLastDirectory` before calling `onComplete`. Callers get remembered
    /// last location without touching directory persistence themselves.
    ///
    /// Typical wiring against `AppSettings`:
    /// ```
    /// SavePanelHelper.presentSavePanel(
    ///     suggestedName: name, allowedType: .png,
    ///     getLastDirectory: { settings.lastScreenshotSaveDirectoryURL },
    ///     setLastDirectory: { settings.lastScreenshotSaveDirectoryPath = $0.path },
    ///     onComplete: { url in ... })
    /// ```
    static func presentSavePanel(
        suggestedName: String,
        allowedType: UTType?,
        getLastDirectory: () -> URL?,
        setLastDirectory: @escaping (URL) -> Void,
        window: NSWindow? = nil,
        onComplete: @escaping (URL?) -> Void
    ) {
        presentSavePanel(
            suggestedName: suggestedName,
            allowedType: allowedType,
            defaultDirectory: getLastDirectory(),
            window: window
        ) { url in
            if let url {
                setLastDirectory(url.deletingLastPathComponent())
            }
            onComplete(url)
        }
    }
}
