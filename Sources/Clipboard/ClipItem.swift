import AppKit
import ImageIO

/// One captured pasteboard entry. Owned by the Clipboard module; shared across the app.
///
/// Stores just enough to re-copy the entry to `NSPasteboard` later. Three kinds are
/// supported: plain text, an image (kept as PNG data), and one-or-more file URLs.
struct ClipItem: Identifiable, Equatable {
    /// The concrete payload plus enough metadata to render and restore it.
    enum Kind: Equatable {
        case text(String)
        /// PNG-encoded image bytes plus the pixel dimensions (for the title).
        case image(png: Data, pixelSize: CGSize)
        case file(urls: [URL])
    }

    let id: UUID
    let date: Date
    let kind: Kind
    /// A small, pre-rendered thumbnail for image items (nil for text / file items).
    /// Decoded ONCE here at construction — list rows must never re-decode the full-res PNG.
    let thumbnailImage: NSImage?

    init(id: UUID = UUID(), date: Date = Date(), kind: Kind) {
        self.id = id
        self.date = date
        self.kind = kind
        self.thumbnailImage = Self.makeThumbnail(for: kind)
    }

    // Custom equality: derived `thumbnailImage` is a function of `kind`, and `NSImage`
    // isn't `Equatable`, so compare the underlying identity/payload instead.
    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        lhs.id == rhs.id && lhs.date == rhs.date && lhs.kind == rhs.kind
    }

    // MARK: - Restore

    /// Writes this item back onto `pb`, clearing it first. After this the pasteboard
    /// holds the same content it had when the item was captured.
    func write(to pb: NSPasteboard) {
        pb.clearContents()
        switch kind {
        case .text(let string):
            pb.setString(string, forType: .string)
        case .image(let png, _):
            // Write PNG and a TIFF fallback so any consumer can read it.
            pb.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        case .file(let urls):
            pb.writeObjects(urls.map { $0 as NSURL })
        }
    }

    // MARK: - Presentation

    /// A thumbnail for image items (nil for text / file items). Returns the cached,
    /// pre-downsampled image built at construction — no per-call full-res PNG decode.
    var thumbnail: NSImage? { thumbnailImage }

    /// Longest-side pixel size for the cached row thumbnail — enough for the ~46×34pt
    /// row rendered @2x, with a little headroom.
    private static let thumbnailMaxPixelSize = 192

    /// Builds a small downsampled thumbnail for image kinds via ImageIO, so list rows
    /// never decode the full-resolution PNG. Returns nil for non-image kinds.
    private static func makeThumbnail(for kind: Kind) -> NSImage? {
        guard case .image(let png, _) = kind,
              let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }

    /// True for image items (used by the history panel's Images filter).
    var isImage: Bool { if case .image = kind { return true }; return false }

    /// Pixel dimensions for image items, as a "W×H" string (nil otherwise).
    var dimensionsText: String? {
        guard case .image(_, let size) = kind else { return nil }
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        return (w > 0 && h > 0) ? "\(w)×\(h)" : nil
    }

    private static let titleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM.dd.yyyy_HH:mm:ss"
        return f
    }()

    /// A short, single-line preview suitable for a list row.
    var displayTitle: String {
        switch kind {
        case .text(let string):
            let collapsed = string
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
            let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "(empty text)" }
            return String(trimmed.prefix(120))
        case .image:
            // Name images by capture time (dimensions live in a subtitle instead).
            return "Screenshot \(Self.titleDateFormatter.string(from: date))"
        case .file(let urls):
            if urls.count == 1 {
                return urls[0].lastPathComponent
            }
            let first = urls.first?.lastPathComponent ?? "files"
            return "\(first) +\(urls.count - 1) more"
        }
    }

    /// SF Symbol name for a small type glyph.
    var glyphName: String {
        switch kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    /// Approximate in-memory footprint in bytes, used to enforce the per-item size cap.
    var byteSize: Int {
        switch kind {
        case .text(let string):
            return string.utf8.count
        case .image(let png, _):
            return png.count
        case .file(let urls):
            return urls.reduce(0) { $0 + $1.absoluteString.utf8.count }
        }
    }

    // MARK: - Factories

    /// Builds an image item from an `NSImage`, encoding to PNG. Returns nil if the
    /// image can't be rasterised.
    static func image(from image: NSImage) -> ClipItem? {
        guard let png = pngData(from: image), let size = pixelSize(from: image) else {
            return nil
        }
        return ClipItem(kind: .image(png: png, pixelSize: size))
    }

    /// Encodes an `NSImage` to PNG data.
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Pixel dimensions of an `NSImage` (not point size).
    static func pixelSize(from image: NSImage) -> CGSize? {
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size == .zero ? nil : image.size
    }
}
