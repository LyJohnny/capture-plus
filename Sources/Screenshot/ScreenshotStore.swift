import AppKit
import Foundation

/// Manages the on-disk folder of region screenshots: naming, collision-safe placement,
/// timed retention (purge files older than `retentionDays`), and listing recent shots.
///
/// Loosely coupled: takes its directory + retention in the initializer and otherwise derives
/// sensible defaults. No dependencies on other Capture + modules — the caller (integrator) wires
/// values from `AppSettings`.
final class ScreenshotStore {

    /// Folder screenshots are stored in. Defaults to `~/Pictures/Capture + Screenshots`.
    /// Reassign to redirect saves (e.g. from settings).
    var directory: URL

    /// Files older than this many days are removed by `purgeExpired()`.
    var retentionDays: Int

    private let fileManager: FileManager

    /// Formats the timestamped file name, e.g. `2026-07-17 at 14.32.05`.
    private let nameFormatter: DateFormatter

    init(directory: URL? = nil, retentionDays: Int = 5) {
        let fm = FileManager.default
        self.fileManager = fm
        if let directory {
            self.directory = directory
        } else {
            // ~/Pictures/Capture + Screenshots
            let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
            self.directory = pictures.appendingPathComponent("Capture + Screenshots", isDirectory: true)
        }
        self.retentionDays = retentionDays

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        self.nameFormatter = f
    }

    // MARK: - Storing

    /// Moves the temp capture at `fileURL` into `directory` under a timestamped, collision-safe
    /// name (e.g. `Screenshot 2026-07-17 at 14.32.05.png`). Returns the final URL, or `nil` on
    /// failure. Falls back to copy + remove if a cross-volume move fails.
    @discardableResult
    func store(fileURL: URL, date: Date) -> URL? {
        guard ensureDirectoryExists() else { return nil }
        let ext = fileURL.pathExtension.isEmpty ? "png" : fileURL.pathExtension
        let destination = destinationURL(for: date, ext: ext)
        do {
            try fileManager.moveItem(at: fileURL, to: destination)
        } catch {
            // Cross-volume moves (and some other failures) can't be done atomically; copy then remove.
            do {
                try fileManager.copyItem(at: fileURL, to: destination)
                try? fileManager.removeItem(at: fileURL)
            } catch {
                NSLog("Capture +: failed to store screenshot at \(destination.path): \(error.localizedDescription)")
                return nil
            }
        }
        return destination
    }

    /// Writes `image` into `directory` as a PNG under a timestamped, collision-safe name.
    /// Returns the final URL, or `nil` on failure.
    @discardableResult
    func store(image: NSImage, date: Date) -> URL? {
        guard ensureDirectoryExists(), let data = Self.pngData(from: image) else { return nil }
        let destination = destinationURL(for: date, ext: "png")
        do {
            try data.write(to: destination)
        } catch {
            NSLog("Capture +: failed to write screenshot at \(destination.path): \(error.localizedDescription)")
            return nil
        }
        return destination
    }

    // MARK: - Retention

    /// Deletes files in `directory` last-modified more than `retentionDays` ago.
    /// A non-positive `retentionDays` is treated as "keep forever" (no-op).
    func purgeExpired() {
        guard retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        for url in contents() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - Listing

    /// Returns up to `limit` most-recent screenshot URLs (newest first), by modification date.
    func recent(limit: Int) -> [URL] {
        guard limit > 0 else { return [] }
        let dated = contents().map { url -> (URL, Date) in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, modified)
        }
        return dated
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    // MARK: - Helpers

    /// Collision-free destination URL for a shot captured at `date`. Appends " (2)", " (3)", …
    /// if a file already exists at the computed path.
    private func destinationURL(for date: Date, ext: String) -> URL {
        let baseName = "Screenshot \(nameFormatter.string(from: date))"
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName) (\(counter))")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    /// Shallow list of regular files directly inside `directory` (empty if it doesn't exist).
    private func contents() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    @discardableResult
    private func ensureDirectoryExists() -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("Capture +: failed to create screenshot directory at \(directory.path): \(error.localizedDescription)")
            return false
        }
    }

    /// PNG-encodes an `NSImage` via its TIFF representation.
    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
