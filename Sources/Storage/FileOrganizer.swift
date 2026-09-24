import AVFoundation
import Foundation
import AppKit

/// Organizes saved recordings into `~/Movies/Capture +/<YYYY-MM>/Recording <YYYY-MM-DD> at <HH.mm.ss>.<ext>`.
///
/// Loosely coupled: takes an optional base directory in its initializer and otherwise
/// derives the default from `FileManager`. No dependencies on other Capture + modules.
final class FileOrganizer {

    /// Root directory under which month subfolders and recordings are created.
    /// Defaults to `~/Movies/Capture +`. Reassign to redirect saves (e.g. from settings).
    var baseDirectory: URL

    private let fileManager: FileManager

    /// Formats the month subfolder name, e.g. `2026-07`.
    private let monthFormatter: DateFormatter
    /// Formats the date portion of the file name, e.g. `2026-07-17`.
    private let dayFormatter: DateFormatter
    /// Formats the time portion of the file name, e.g. `14.09.03`.
    private let timeFormatter: DateFormatter

    init(baseDirectory: URL? = nil) {
        let fm = FileManager.default
        self.fileManager = fm
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            // ~/Movies/Capture +
            let movies = fm.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
            self.baseDirectory = movies.appendingPathComponent("Capture +", isDirectory: true)
        }

        func makeFormatter(_ format: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }
        self.monthFormatter = makeFormatter("yyyy-MM")
        self.dayFormatter = makeFormatter("yyyy-MM-dd")
        self.timeFormatter = makeFormatter("HH.mm.ss")
    }

    /// Returns a collision-free destination URL for a recording captured at `date` with file
    /// extension `ext` (no leading dot). Creates the month subdirectory if it does not exist.
    /// If a file already exists at the computed path, appends " (2)", " (3)", … until free.
    func destinationURL(for date: Date, ext: String) -> URL {
        let monthDir = baseDirectory.appendingPathComponent(monthFormatter.string(from: date), isDirectory: true)
        try? fileManager.createDirectory(at: monthDir, withIntermediateDirectories: true)

        let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        let baseName = "Recording \(dayFormatter.string(from: date)) at \(timeFormatter.string(from: date))"

        var candidate = monthDir.appendingPathComponent(baseName).appendingPathExtension(cleanExt)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = monthDir
                .appendingPathComponent("\(baseName) (\(counter))")
                .appendingPathExtension(cleanExt)
            counter += 1
        }
        return candidate
    }

    /// Moves `tempURL` to its organized destination and returns the final URL.
    /// Falls back to copy + remove if a cross-volume move fails.
    @discardableResult
    func save(tempURL: URL, date: Date, ext: String) throws -> URL {
        let destination = destinationURL(for: date, ext: ext)
        do {
            try fileManager.moveItem(at: tempURL, to: destination)
        } catch {
            // Cross-volume moves (and some other failures) can't be done atomically; copy then remove.
            try fileManager.copyItem(at: tempURL, to: destination)
            try? fileManager.removeItem(at: tempURL)
        }
        return destination
    }

    // MARK: - Template-based naming

    /// Characters that are illegal (or troublesome) in macOS file names.
    /// `/` and `:` are reserved by the filesystem/Finder; the rest are stripped
    /// defensively so a user template can't produce a broken path.
    private static let illegalNameCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        set.formUnion(.controlCharacters)
        return set
    }()

    /// Expands a filename template against `date` and appends `.ext`.
    ///
    /// Tokens: `{date}` → `YYYY-MM-DD`, `{time}` → `HH.mm.ss`,
    /// `{datetime}` → `YYYY-MM-DD at HH.mm.ss` (all `en_US_POSIX`). Illegal path
    /// characters are stripped and leading dots removed so the result is a safe
    /// single path component. Returns the name **including** the extension.
    /// Falls back to `Recording <datetime>` if the template expands to empty.
    func fileName(template: String, date: Date, ext: String) -> String {
        let day = dayFormatter.string(from: date)
        let time = timeFormatter.string(from: date)
        let datetime = "\(day) at \(time)"

        // Replace {datetime} first so it can't be clobbered by {date}/{time}.
        var name = template
            .replacingOccurrences(of: "{datetime}", with: datetime)
            .replacingOccurrences(of: "{date}", with: day)
            .replacingOccurrences(of: "{time}", with: time)

        name = name.components(separatedBy: FileOrganizer.illegalNameCharacters).joined()
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Recording \(datetime)" }

        let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        return cleanExt.isEmpty ? name : "\(name).\(cleanExt)"
    }

    /// Moves `tempURL` into `directory` under `fileName`, creating `directory`
    /// if needed and appending " (2)", " (3)", … before the extension until the
    /// path is free. Returns the final URL. Falls back to copy + remove if a
    /// cross-volume move fails.
    @discardableResult
    func save(tempURL: URL, directory: URL, fileName: String) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        func compose(_ name: String) -> URL {
            let url = directory.appendingPathComponent(name)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }

        var candidate = compose(base)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = compose("\(base) (\(counter))")
            counter += 1
        }

        do {
            try fileManager.moveItem(at: tempURL, to: candidate)
        } catch {
            try fileManager.copyItem(at: tempURL, to: candidate)
            try? fileManager.removeItem(at: tempURL)
        }
        return candidate
    }

    /// Reveals `url` in Finder, selecting it in its containing folder.
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Stranded-recording recovery

    /// Recordings sitting in the in-progress folder. Called at launch — before any
    /// recording can start — so every file listed belongs to a session that never
    /// got a Save/Delete (the app quit, crashed, or the Mac lost power while it
    /// waited). Snapshot synchronously; a new session's file is never included.
    static func strandedRecordings(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "mp4" }
    }

    /// File stranded recordings into `directory`, named from each file's creation
    /// date via the user's template. Only PLAYABLE files are moved — a session that
    /// never captured anything is left where it is rather than filed as garbage —
    /// and nothing is ever deleted. Returns the saved URLs.
    func recoverRecordings(_ urls: [URL], into directory: URL, template: String) async -> [URL] {
        var saved: [URL] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let seconds = ((try? await asset.load(.duration)) ?? .zero).seconds
            guard playable, seconds > 0.5 else { continue }

            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? Date()
            let name = fileName(template: template, date: created, ext: "mp4")
            if let result = try? save(tempURL: url, directory: directory, fileName: name) {
                saved.append(result)
            }
        }
        return saved
    }
}
