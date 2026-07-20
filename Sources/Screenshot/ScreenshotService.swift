import AppKit
import Foundation

/// Thin wrapper around `/usr/sbin/screencapture` for interactive region/window capture.
///
/// Everything runs off the main thread (Foundation `Process` on a background queue) and
/// completions are always delivered back on the main thread. The user cancelling the
/// crosshair (Esc) is treated as a normal, non-error `nil` result.
final class ScreenshotService {

    /// Absolute path to Apple's capture tool. It has lived here on every macOS release.
    private let toolPath = "/usr/sbin/screencapture"

    /// Serializes launches so two overlapping hotkey presses don't fight over the crosshair.
    private let queue = DispatchQueue(label: "com.captureplus.screenshot", qos: .userInitiated)

    public init() {}

    /// Interactive region/window capture that produces BOTH a file and a clipboard image.
    ///
    /// Shells out to `screencapture -i <tempfile.png>` (no `-c`; we own the clipboard step).
    /// On a successful capture we read the `NSImage` back out of the temp file, write it to
    /// `NSPasteboard.general` ourselves (so copy-to-clipboard still happens), and hand the
    /// caller both the file URL and the image. The caller is responsible for moving the temp
    /// file to its final home (e.g. via `ScreenshotStore`); it lives under the system temp
    /// directory until then.
    /// - Parameter completion: called on the main thread with `(fileURL, image)` on success,
    ///   or `(nil, nil)` if the user cancelled (no file produced) or the read failed.
    public func captureRegion(completion: @escaping (URL?, NSImage?) -> Void) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.makeFileName())

        run(arguments: ["-i", tempURL.path]) { _ in
            // On cancel, screencapture exits without creating the file, so existence
            // (not exit status) is the reliable success signal.
            guard FileManager.default.fileExists(atPath: tempURL.path),
                  let image = NSImage(contentsOf: tempURL) else {
                Self.onMain { completion(nil, nil) }
                return
            }

            // Mirror `screencapture -c`: put the shot on the clipboard ourselves so the
            // copy-to-clipboard behaviour survives the switch to a file-based capture.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])

            Self.onMain { completion(tempURL, image) }
        }
    }

    /// Interactive region/window capture straight to the clipboard (`screencapture -i -c`).
    ///
    /// Nothing is written to disk. After the tool exits we read the image back out of
    /// `NSPasteboard.general` so the caller can also push it into clipboard history.
    /// - Parameter completion: called on the main thread with the captured `NSImage`,
    ///   or `nil` if the user cancelled (or no image landed on the pasteboard).
    @available(*, deprecated, message: "Use captureRegion(completion:) which also produces a file.")
    public func captureRegionToClipboard(completion: ((NSImage?) -> Void)? = nil) {
        // Snapshot the pasteboard state up front: `screencapture -c` only mutates the
        // pasteboard on a successful capture, so an unchanged changeCount == cancelled.
        let pasteboard = NSPasteboard.general
        let priorChangeCount = pasteboard.changeCount

        run(arguments: ["-i", "-c"]) { success in
            var image: NSImage? = nil
            if success, pasteboard.changeCount != priorChangeCount {
                image = Self.readImage(from: pasteboard)
            }
            Self.onMain { completion?(image) }
        }
    }

    /// Interactive capture written to a file inside `directory` (`screencapture -i <path>`).
    ///
    /// - Parameters:
    ///   - directory: destination folder; created if it doesn't exist.
    ///   - completion: called on the main thread with the written file URL, or `nil`
    ///     if the user cancelled (no file produced) or the write failed.
    public func captureRegionToFile(directory: URL, completion: ((URL?) -> Void)? = nil) {
        let fileURL = directory.appendingPathComponent(Self.makeFileName())

        // Ensure the destination exists; if we can't create it, fail gracefully.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.onMain { completion?(nil) }
            return
        }

        run(arguments: ["-i", fileURL.path]) { _ in
            // On cancel, screencapture exits without creating the file, so existence
            // (not exit status) is the reliable success signal.
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            Self.onMain { completion?(exists ? fileURL : nil) }
        }
    }

    // MARK: - Process plumbing

    /// Launches `screencapture` off the main thread and calls back (off-main) with whether
    /// it exited cleanly (status 0). Never blocks the caller's thread.
    private func run(arguments: [String], completion: @escaping (Bool) -> Void) {
        queue.async { [toolPath] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: toolPath)
            process.arguments = arguments

            do {
                try process.run()
            } catch {
                completion(false)
                return
            }

            // Blocks only this background thread until the interactive session ends.
            process.waitUntilExit()
            completion(process.terminationStatus == 0)
        }
    }

    // MARK: - Helpers

    /// Reads an image off the pasteboard, tolerating either TIFF or PNG representations.
    private static func readImage(from pasteboard: NSPasteboard) -> NSImage? {
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first {
            return first
        }
        // Fallback: build directly from raw TIFF/PNG data if object reading failed.
        for type in [NSPasteboard.PasteboardType.tiff, NSPasteboard.PasteboardType.png] {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    /// "Screenshot YYYY-MM-DD at HH.mm.ss.png" — mirrors macOS's own naming style.
    private static func makeFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: Date())).png"
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
