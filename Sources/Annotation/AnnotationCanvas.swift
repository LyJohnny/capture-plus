import AppKit

/// A custom view that draws a working image scaled-to-fit plus an ordered list of
/// styled vector annotations on top, supports selecting/moving/resizing/restyling
/// them, can crop and rotate the working image, and flattens everything back into a
/// full-resolution `NSImage`.
///
/// Coordinate model: every annotation is stored in **image-pixel space** (origin
/// bottom-left, matching AppKit's default non-flipped drawing). Mouse points are
/// converted view→image on the way in; drawing maps image→view (or image→native
/// pixels, for export). This keeps annotations correct across window resizes and
/// lands them at full resolution on export for free. Stroke widths and font sizes
/// are likewise stored in image space so they scale with the image.
///
/// Undo: every committed mutation (create, delete, move, resize, restyle, clear,
/// crop, rotate) registers its own inverse on the window's undo manager, so
/// multi-level Cmd-Z/Cmd-Shift-Z walks the whole history.
///
/// Loosely coupled: no dependencies on other Capture + modules. The owning window
/// controller sets the tool + current style via `tool`/`setStrokeColor(_:)` etc.,
/// and calls `undo()`, `redo()`, `clearAll()`, `beginCrop()`, `rotateLeft()`,
/// `flattenedImage()`, and so on.
@MainActor
final class AnnotationCanvas: NSView, NSTextFieldDelegate {

    // MARK: - Tools
    enum Tool {
        case select
        case pen
        case highlighter
        case line
        case arrow
        case rect
        case roundedRect
        case oval
        case speechBubble
        case star
        case hexagon
        case text

        /// True for the drag-a-bounding-box shape tools (stroke + optional fill).
        var isShape: Bool {
            switch self {
            case .line, .arrow, .rect, .roundedRect, .oval, .speechBubble, .star, .hexagon:
                return true
            default:
                return false
            }
        }
    }

    /// Snapshot of an object's style, in *view* units, handed to the controller so
    /// the toolbar can reflect the current selection.
    struct StyleInfo {
        let stroke: NSColor
        let fill: NSColor?
        let lineWidth: CGFloat   // view points
        let fontName: String
        let fontSize: CGFloat    // view points
        let isText: Bool
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let alignment: NSTextAlignment
    }

    // MARK: - Annotation model (all geometry in image-pixel space)
    private enum Kind {
        case pen(points: [CGPoint])
        case highlighter(points: [CGPoint])
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        case rect(CGRect)
        case roundedRect(CGRect)
        case oval(CGRect)
        case speechBubble(CGRect)
        case star(CGRect)
        case hexagon(CGRect)
        case text(String, at: CGPoint)

        var isText: Bool { if case .text = self { return true }; return false }
        /// Closed (fillable) shapes defined by a bounding box.
        var isClosed: Bool {
            switch self {
            case .rect, .roundedRect, .oval, .speechBubble, .star, .hexagon: return true
            default: return false
            }
        }
        /// The defining bounding box for box-based shapes, else nil.
        var boxRect: CGRect? {
            switch self {
            case .rect(let r), .roundedRect(let r), .oval(let r),
                 .speechBubble(let r), .star(let r), .hexagon(let r):
                return r
            default: return nil
            }
        }
    }

    private struct Annotation {
        // Stable identity so undo/redo and selection can target a specific object
        // regardless of its current position in the stack.
        var id = UUID()
        var kind: Kind
        var stroke: NSColor      // border / stroke / text colour
        var fill: NSColor?       // closed shapes only; nil == no fill
        var lineWidth: CGFloat   // image-space
        var fontName: String     // text only (family name)
        var fontSize: CGFloat    // image-space (text only)
        // Text traits (text only). Bold/italic are applied to the family font via
        // NSFontManager at render time; underline and alignment are honoured directly.
        var bold: Bool = false
        var italic: Bool = false
        var underline: Bool = false
        var alignment: NSTextAlignment = .left
    }

    /// A grab handle on the current selection.
    private enum Handle { case none, move, topLeft, topRight, bottomLeft, bottomRight, p1, p2 }

    // MARK: - Public drawing settings (the "current style" for new objects)
    var tool: Tool = .pen {
        didSet { onToolChanged?(tool); refreshCursor() }
    }
    private(set) var strokeColor: NSColor = .systemRed
    private(set) var fillColor: NSColor? = nil
    /// Current stroke width in *view* points; converted to image space per shape.
    private(set) var strokeWidth: CGFloat = 4
    private(set) var textFontName: String = NSFont.systemFont(ofSize: 12).familyName ?? "Helvetica"
    /// Current text size in *view* points.
    private(set) var textFontSize: CGFloat = 24
    private(set) var textColor: NSColor = .systemRed
    // Current text traits for new text objects.
    private(set) var textBold = false
    private(set) var textItalic = false
    private(set) var textUnderline = false
    private(set) var textAlignment: NSTextAlignment = .left

    // MARK: - State
    private var workingImage: NSImage
    /// Native pixel dimensions of the working image (export resolution). Changes on
    /// crop and rotate.
    private(set) var pixelSize: NSSize

    private var annotations: [Annotation] = []
    private var current: Annotation?          // shape being drawn
    private var shapeDragStart: CGPoint = .zero

    private var selection: UUID?
    private var drag: (id: UUID, original: Annotation, handle: Handle, start: CGPoint)?
    private var dragMoved = false

    private(set) var isCropping = false
    private var cropRect: CGRect?
    private var cropDragStart: CGPoint = .zero

    private var activeTextField: NSTextField?
    /// Style captured when a text field opens, applied when it commits.
    private var pendingTextStyle: (name: String, viewSize: CGFloat, color: NSColor,
                                   bold: Bool, italic: Bool, underline: Bool, alignment: NSTextAlignment)?
    /// The existing annotation currently being edited in place (nil when the field is
    /// for brand-new text). Kept in the annotation stack but hidden while the field is
    /// open, so committing can update it in place (single undoable step, same z-order).
    private var editingAnnotation: Annotation?

    /// Fired when the selection changes (or its style changes via a control), so the
    /// controller can sync the toolbar. `nil` == nothing selected.
    var onSelectionChanged: ((StyleInfo?) -> Void)?
    /// Fired when crop mode toggles (e.g. cancelled via Esc), so the controller can
    /// update its contextual crop UI.
    var onCropModeChanged: ((Bool) -> Void)?
    /// Fired whenever `tool` changes, so the controller can show/hide contextual
    /// style controls for the active tool.
    var onToolChanged: ((Tool) -> Void)?

    /// Monotonic counter bumped on every committed mutation. The controller compares
    /// it against the value at the last export to know whether there are unsaved edits.
    private(set) var changeCount = 0

    /// Debug / render-harness only: drop one of every shape onto the canvas so shape
    /// geometry can be visually verified. Not used in normal operation.
    func debugPopulateShapes() {
        func mk(_ k: Kind) -> Annotation {
            Annotation(kind: k, stroke: .systemRed, fill: nil, lineWidth: 6,
                       fontName: textFontName, fontSize: textFontSize)
        }
        func box(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: 190, height: 120) }
        annotations.append(contentsOf: [
            mk(.line(from: CGPoint(x: 70, y: 520), to: CGPoint(x: 250, y: 580))),
            mk(.arrow(from: CGPoint(x: 320, y: 520), to: CGPoint(x: 500, y: 580))),
            mk(.rect(box(70, 330))),
            mk(.roundedRect(box(320, 330))),
            mk(.oval(box(570, 330))),
            mk(.speechBubble(box(70, 120))),
            mk(.star(box(320, 120))),
            mk(.hexagon(box(570, 120))),
        ])
        needsDisplay = true
    }

    /// Product-shot sample: one arrow and a short caption, like a real markup.
    func debugPopulateSample(arrowFrom: CGPoint, arrowTo: CGPoint, caption: String, at: CGPoint) {
        annotations.append(contentsOf: [
            Annotation(kind: .arrow(from: arrowFrom, to: arrowTo), stroke: .systemRed, fill: nil,
                       lineWidth: 10, fontName: textFontName, fontSize: textFontSize),
            Annotation(kind: .text(caption, at: at), stroke: .systemRed, fill: nil,
                       lineWidth: 10, fontName: textFontName, fontSize: 52, bold: true),
        ])
        needsDisplay = true
    }

    /// Debug / self-test only: drives the real text-place → type → commit path and returns
    /// PASS/FAIL, verifying the fix for "clicking outside a text box spawns another box"
    /// (after commit the tool must be .select, so the dismissing click can't make a box).
    func debugTextCommitSelfTest() -> String {
        annotations.removeAll()
        selection = nil
        tool = .text
        beginTextEntry(atViewPoint: CGPoint(x: 120, y: 120))
        activeTextField?.stringValue = "hello"
        commitTextEntry()
        let switched = (tool == .select)
        let textCount = annotations.filter { $0.kind.isText }.count
        return "toolAfterCommit=\(tool) [\(switched ? "PASS→select" : "FAIL")]; "
             + "textBoxes=\(textCount) [\(textCount == 1 ? "PASS" : "FAIL")]"
    }

    /// True when there is at least one committed annotation on the canvas.
    var hasAnnotations: Bool { !annotations.isEmpty }
    /// True when an object is currently selected.
    var hasSelection: Bool { selection != nil }

    // MARK: - Init
    init(image: NSImage) {
        self.workingImage = image
        self.pixelSize = Self.pixelSize(of: image)
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // A non-flipped view keeps us in the same bottom-left space as NSImage/bitmap
    // export, so a single mapping serves both on-screen and flattened rendering.
    override var isFlipped: Bool { false }

    // MARK: - First responder / undo plumbing

    override var acceptsFirstResponder: Bool { true }

    // Route all undo registration/lookup through the window's undo manager — the same
    // manager the Edit menu drives — so toolbar Undo, Cmd-Z, and the menu share one stack.
    override var undoManager: UndoManager? { window?.undoManager }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Bound the undo stack. Crop/rotate each register an undo closure that retains a
        // previous FULL-resolution NSImage, so an unbounded history can grow without limit
        // across a long session. Capping keeps undo useful while letting the oldest
        // snapshots (and their images) be released.
        undoManager?.levelsOfUndo = 25
        refreshCursor()
    }

    override func keyDown(with event: NSEvent) {
        // Direct Cmd-Z / Cmd-Shift-Z fallback. While a text field is editing it is
        // first responder, so this never intercepts typing.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
            return
        }
        switch event.keyCode {
        case 53: // Esc — cancel crop, else deselect.
            if isCropping { cancelCrop() } else if selection != nil { clearSelection() }
            return
        case 51, 117: // Delete / Forward-delete — remove the selection.
            if selection != nil { deleteSelection(); return }
        default: break
        }
        super.keyDown(with: event)
    }

    // MARK: - Public API — actions

    func undo() { commitTextEntry(); undoManager?.undo() }
    func redo() { commitTextEntry(); undoManager?.redo() }

    func clearAll() {
        commitTextEntry()
        clearSelection()
        guard !annotations.isEmpty else { return }
        let removed = annotations
        annotations.removeAll()
        changeCount += 1
        needsDisplay = true
        undoManager?.registerUndo(withTarget: self) { $0.restoreAll(removed) }
    }

    /// Delete the currently selected object (undoable).
    func deleteSelection() {
        guard let id = selection else { return }
        clearSelection()
        removeAnnotation(id: id)
    }

    func rotateLeft() { rotate(left: true) }
    func rotateRight() { rotate(left: false) }

    // MARK: - Public API — current style
    //
    // Each setter updates the "current style" used for new objects and, when an
    // object is selected and the property is relevant, restyles it (undoable).

    func setStrokeColor(_ c: NSColor) {
        strokeColor = c
        mutateSelection(where: { !$0.isText }) { $0.stroke = c }
    }

    func setFillColor(_ c: NSColor?) {
        fillColor = c
        mutateSelection(where: { $0.isClosed }) { $0.fill = c }
    }

    func setLineWidth(_ points: CGFloat) {
        strokeWidth = points
        guard let s = nonZeroScale() else { return }
        mutateSelection(where: { !$0.isText }) { $0.lineWidth = points / s }
    }

    func setTextColor(_ c: NSColor) {
        textColor = c
        mutateSelection(where: { $0.isText }) { $0.stroke = c }
    }

    func setTextFont(name: String, size: CGFloat) {
        textFontName = name
        textFontSize = size
        guard let s = nonZeroScale() else { return }
        mutateSelection(where: { $0.isText }) { $0.fontName = name; $0.fontSize = size / s }
    }

    func setTextBold(_ on: Bool) {
        textBold = on
        mutateSelection(where: { $0.isText }) { $0.bold = on }
    }

    func setTextItalic(_ on: Bool) {
        textItalic = on
        mutateSelection(where: { $0.isText }) { $0.italic = on }
    }

    func setTextUnderline(_ on: Bool) {
        textUnderline = on
        mutateSelection(where: { $0.isText }) { $0.underline = on }
    }

    func setTextAlignment(_ alignment: NSTextAlignment) {
        textAlignment = alignment
        mutateSelection(where: { $0.isText }) { $0.alignment = alignment }
    }

    /// Apply `transform` to the selected annotation if it satisfies `predicate`.
    private func mutateSelection(where predicate: (Kind) -> Bool, _ transform: (inout Annotation) -> Void) {
        guard let id = selection,
              let a = annotation(id: id), predicate(a.kind) else { return }
        var updated = a
        transform(&updated)
        replaceAnnotation(id: id, with: updated)
        onSelectionChanged?(styleInfo(for: updated))
    }

    // MARK: - Undoable primitives
    //
    // Each registers its own inverse, so the undo manager flips them between the undo
    // and redo stacks automatically.

    private func insertAnnotation(_ a: Annotation, at index: Int) {
        let idx = min(max(0, index), annotations.count)
        annotations.insert(a, at: idx)
        changeCount += 1
        needsDisplay = true
        undoManager?.registerUndo(withTarget: self) { $0.removeAnnotation(id: a.id) }
    }

    private func removeAnnotation(id: UUID) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        let a = annotations.remove(at: idx)
        if selection == id { clearSelection() }
        changeCount += 1
        needsDisplay = true
        undoManager?.registerUndo(withTarget: self) { $0.insertAnnotation(a, at: idx) }
    }

    private func replaceAnnotation(id: UUID, with new: Annotation) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        let old = annotations[idx]
        annotations[idx] = new
        changeCount += 1
        needsDisplay = true
        undoManager?.registerUndo(withTarget: self) { $0.replaceAnnotation(id: id, with: old) }
    }

    private func restoreAll(_ arr: [Annotation]) {
        let previous = annotations
        annotations = arr
        clearSelection()
        changeCount += 1
        needsDisplay = true
        undoManager?.registerUndo(withTarget: self) { $0.restoreAll(previous) }
    }

    /// Wholesale swap of image + size + annotations (crop / rotate), undoable as one step.
    private func applyTransform(image: NSImage, pixelSize newSize: NSSize, annotations newAnns: [Annotation]) {
        let oldImage = workingImage, oldSize = pixelSize, oldAnns = annotations
        workingImage = image
        pixelSize = newSize
        annotations = newAnns
        clearSelection()
        changeCount += 1
        needsDisplay = true
        undoManager?.registerUndo(withTarget: self) {
            $0.applyTransform(image: oldImage, pixelSize: oldSize, annotations: oldAnns)
        }
    }

    private func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        needsDisplay = true
        onSelectionChanged?(nil)
    }

    // MARK: - Export

    /// Renders the working image at its native pixel size with every annotation
    /// composited on top. Returns `nil` only if a bitmap context can't be made.
    func flattenedImage() -> NSImage? {
        commitTextEntry()
        let w = Int(pixelSize.width.rounded()), h = Int(pixelSize.height.rounded())
        guard let rep = Self.makeBitmap(w: w, h: h) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx

        let full = NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        workingImage.draw(in: full, from: .zero, operation: .copy, fraction: 1)
        // scale == 1: image space maps 1:1 to native pixels.
        for a in annotations { drawAnnotation(a, in: full, scale: 1) }
        ctx.flushGraphics()

        let out = NSImage(size: NSSize(width: w, height: h))
        out.addRepresentation(rep)
        return out
    }

    // MARK: - Coordinate mapping

    /// The aspect-fit rect the image occupies in view space, and the image→view scale.
    private func imageLayout() -> (rect: NSRect, scale: CGFloat) {
        let b = bounds
        guard pixelSize.width > 0, pixelSize.height > 0 else { return (b, 1) }
        let scale = min(b.width / pixelSize.width, b.height / pixelSize.height)
        let w = pixelSize.width * scale, h = pixelSize.height * scale
        let x = (b.width - w) / 2, y = (b.height - h) / 2
        return (NSRect(x: x, y: y, width: w, height: h), scale)
    }

    private func nonZeroScale() -> CGFloat? {
        let s = imageLayout().scale
        return s > 0 ? s : nil
    }

    private func imagePoint(from event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        let (rect, scale) = imageLayout()
        guard scale > 0 else { return .zero }
        let x = (v.x - rect.minX) / scale, y = (v.y - rect.minY) / scale
        return CGPoint(x: min(max(0, x), pixelSize.width), y: min(max(0, y), pixelSize.height))
    }

    // MARK: - Cursor feedback

    /// Cursor over the image area follows the active tool: crosshair for drawing/shape
    /// tools (and while cropping), I-beam for text, plain arrow for select. Outside the
    /// image the default arrow applies.
    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = imageLayout().rect
        guard rect.width > 0, rect.height > 0 else { return }
        let cursor: NSCursor
        if isCropping {
            cursor = .crosshair
        } else {
            switch tool {
            case .select: cursor = .arrow
            case .text: cursor = .iBeam
            default: cursor = .crosshair   // pen, highlighter, and every shape tool
            }
        }
        addCursorRect(rect, cursor: cursor)
    }

    /// Ask AppKit to rebuild our cursor rects after the tool or crop state changes.
    private func refreshCursor() { window?.invalidateCursorRects(for: self) }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let (rect, scale) = imageLayout()
        workingImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        // Skip the annotation being edited: the text field stands in for it meanwhile.
        for a in annotations where a.id != editingAnnotation?.id { drawAnnotation(a, in: rect, scale: scale) }
        if let current { drawAnnotation(current, in: rect, scale: scale) }

        if isCropping {
            drawCropOverlay(in: rect, scale: scale)
        } else if tool == .select, let id = selection, let a = annotation(id: id) {
            drawSelection(a, in: rect, scale: scale)
        }
    }

    private func drawAnnotation(_ a: Annotation, in rect: NSRect, scale: CGFloat) {
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale) }
        func mapRect(_ r: CGRect) -> NSRect {
            NSRect(x: rect.minX + r.minX * scale, y: rect.minY + r.minY * scale,
                   width: r.width * scale, height: r.height * scale)
        }
        let lw = max(0.5, a.lineWidth * scale)

        switch a.kind {
        case .pen(let pts):
            strokePolyline(pts.map(map), width: lw, color: a.stroke)
        case .highlighter(let pts):
            strokePolyline(pts.map(map), width: lw, color: a.stroke.withAlphaComponent(0.35))
        case .line(let from, let to):
            let path = NSBezierPath()
            path.lineWidth = lw
            path.lineCapStyle = .round
            path.move(to: map(from)); path.line(to: map(to))
            a.stroke.setStroke(); path.stroke()
        case .arrow(let from, let to):
            drawArrow(from: map(from), to: map(to), width: lw, color: a.stroke)
        case .rect(let r):
            drawClosed(NSBezierPath(rect: mapRect(r)), fill: a.fill, stroke: a.stroke, width: lw)
        case .roundedRect(let r):
            let vr = mapRect(r)
            let rad = min(vr.width, vr.height) * 0.18
            drawClosed(NSBezierPath(roundedRect: vr, xRadius: rad, yRadius: rad),
                       fill: a.fill, stroke: a.stroke, width: lw)
        case .oval(let r):
            drawClosed(NSBezierPath(ovalIn: mapRect(r)), fill: a.fill, stroke: a.stroke, width: lw)
        case .speechBubble(let r):
            drawClosed(Self.speechBubblePath(in: mapRect(r)), fill: a.fill, stroke: a.stroke, width: lw)
        case .star(let r):
            drawClosed(Self.starPath(in: mapRect(r)), fill: a.fill, stroke: a.stroke, width: lw)
        case .hexagon(let r):
            drawClosed(Self.hexagonPath(in: mapRect(r)), fill: a.fill, stroke: a.stroke, width: lw)
        case .text(let s, let at):
            // +2,+2 nudge approximates the text field's internal inset at commit time.
            let attrs = textAttributes(for: a, scale: scale)
            NSString(string: s).draw(at: NSPoint(x: map(at).x + 2, y: map(at).y + 2), withAttributes: attrs)
        }
    }

    private func drawClosed(_ path: NSBezierPath, fill: NSColor?, stroke: NSColor, width: CGFloat) {
        if let fill { fill.setFill(); path.fill() }
        path.lineWidth = width
        path.lineJoinStyle = .round
        stroke.setStroke()
        path.stroke()
    }

    private func strokePolyline(_ points: [CGPoint], width: CGFloat, color: NSColor) {
        guard let first = points.first else { return }
        color.setStroke()
        if points.count == 1 {
            let r = width / 2
            let dot = NSBezierPath(ovalIn: NSRect(x: first.x - r, y: first.y - r, width: width, height: width))
            color.setFill(); dot.fill()
            return
        }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        for p in points.dropFirst() { path.line(to: p) }
        path.stroke()
    }

    private func drawArrow(from: CGPoint, to: CGPoint, width: CGFloat, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: from); path.line(to: to)

        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = max(8, width * 3)
        let spread = CGFloat.pi * 0.82
        for a in [angle + spread, angle - spread] {
            path.move(to: to)
            path.line(to: CGPoint(x: to.x + cos(a) * head, y: to.y + sin(a) * head))
        }
        path.stroke()
    }

    private func drawSelection(_ a: Annotation, in rect: NSRect, scale: CGFloat) {
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale) }
        let b = imageBounds(of: a)
        let vr = NSRect(x: rect.minX + b.minX * scale, y: rect.minY + b.minY * scale,
                        width: b.width * scale, height: b.height * scale).insetBy(dx: -3, dy: -3)

        let box = NSBezierPath(rect: vr)
        box.lineWidth = 1
        box.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        box.stroke()

        for c in handleCenters(of: a, map: map) { drawHandle(at: c) }
    }

    private func drawHandle(at c: CGPoint) {
        let r = NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
        let path = NSBezierPath(ovalIn: r)
        NSColor.white.setFill(); path.fill()
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5; path.stroke()
    }

    private func drawCropOverlay(in rect: NSRect, scale: CGFloat) {
        guard let cr = cropRect else { return }
        let vr = NSRect(x: rect.minX + cr.minX * scale, y: rect.minY + cr.minY * scale,
                        width: cr.width * scale, height: cr.height * scale)
        // Dim everything outside the crop rect (four bands around it).
        NSColor(white: 0, alpha: 0.5).setFill()
        for band in [
            NSRect(x: rect.minX, y: vr.maxY, width: rect.width, height: rect.maxY - vr.maxY),
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: vr.minY - rect.minY),
            NSRect(x: rect.minX, y: vr.minY, width: vr.minX - rect.minX, height: vr.height),
            NSRect(x: vr.maxX, y: vr.minY, width: rect.maxX - vr.maxX, height: vr.height),
        ] where band.width > 0 && band.height > 0 {
            band.fill()
        }
        let border = NSBezierPath(rect: vr)
        border.lineWidth = 1
        NSColor.white.setStroke(); border.stroke()
    }

    // MARK: - Geometry helpers

    private func annotation(id: UUID) -> Annotation? { annotations.first { $0.id == id } }

    /// Bounding rect of an annotation in image space.
    private func imageBounds(of a: Annotation) -> CGRect {
        switch a.kind {
        case .pen(let pts), .highlighter(let pts):
            return Self.bbox(pts).insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2)
        case .line(let f, let t), .arrow(let f, let t):
            return Self.bbox([f, t]).insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2)
        case .rect(let r), .roundedRect(let r), .oval(let r),
             .speechBubble(let r), .star(let r), .hexagon(let r):
            return r
        case .text(let s, let at):
            let sz = textSize(s, name: a.fontName, size: a.fontSize, bold: a.bold, italic: a.italic)
            return CGRect(x: at.x, y: at.y, width: sz.width, height: sz.height)
        }
    }

    /// The corner/endpoint handle centres for `a`, in view space.
    private func handleCenters(of a: Annotation, map: (CGPoint) -> CGPoint) -> [CGPoint] {
        switch a.kind {
        case .rect(let r), .roundedRect(let r), .oval(let r),
             .speechBubble(let r), .star(let r), .hexagon(let r):
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].map(map)
        case .line(let f, let t), .arrow(let f, let t):
            return [map(f), map(t)]
        default:
            return []
        }
    }

    private func handle(at viewPoint: CGPoint, for a: Annotation) -> Handle {
        let (rect, scale) = imageLayout()
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale) }
        let tol: CGFloat = 9
        func near(_ c: CGPoint) -> Bool { abs(viewPoint.x - c.x) <= tol && abs(viewPoint.y - c.y) <= tol }

        switch a.kind {
        case .rect(let r), .roundedRect(let r), .oval(let r),
             .speechBubble(let r), .star(let r), .hexagon(let r):
            if near(map(CGPoint(x: r.minX, y: r.minY))) { return .bottomLeft }
            if near(map(CGPoint(x: r.maxX, y: r.minY))) { return .bottomRight }
            if near(map(CGPoint(x: r.minX, y: r.maxY))) { return .topLeft }
            if near(map(CGPoint(x: r.maxX, y: r.maxY))) { return .topRight }
        case .line(let f, let t), .arrow(let f, let t):
            if near(map(f)) { return .p1 }
            if near(map(t)) { return .p2 }
        default:
            break
        }
        return .none
    }

    /// Top-most annotation under an image-space point, or `nil`.
    private func annotationHit(at p: CGPoint) -> Annotation? {
        let tol = (8 / (nonZeroScale() ?? 1))
        for a in annotations.reversed() where hitTest(a, at: p, tol: tol) { return a }
        return nil
    }

    private func hitTest(_ a: Annotation, at p: CGPoint, tol: CGFloat) -> Bool {
        switch a.kind {
        case .pen(let pts), .highlighter(let pts):
            return Self.distanceToPolyline(p, pts) <= max(tol, a.lineWidth)
        case .line(let f, let t), .arrow(let f, let t):
            return Self.distanceToSegment(p, f, t) <= max(tol, a.lineWidth)
        case .rect(let r), .roundedRect(let r), .oval(let r),
             .speechBubble(let r), .star(let r), .hexagon(let r):
            return Self.ringHit(p, r, tol: tol, filled: a.fill != nil)
        case .text:
            return imageBounds(of: a).insetBy(dx: -tol / 2, dy: -tol / 2).contains(p)
        }
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        // Committing any active text field switches the tool back to .select (see
        // commitTextEntry), so the click that dismisses a text box lands in the .select
        // branch below — a normal select, NOT a new text box.
        window?.makeFirstResponder(self)
        if isCropping { cropMouseDown(event); return }

        // Double-clicking a text label edits it in place, regardless of the active tool.
        if event.clickCount == 2 {
            let p = imagePoint(from: event)
            if let hit = annotationHit(at: p), hit.kind.isText {
                beginTextEntry(atViewPoint: convert(event.locationInWindow, from: nil), editing: hit)
                return
            }
        }

        switch tool {
        case .select:
            selectMouseDown(event)
        case .text:
            // Click an existing label to edit it; only empty space creates a new one.
            let p = imagePoint(from: event)
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let hit = annotationHit(at: p), hit.kind.isText {
                beginTextEntry(atViewPoint: viewPoint, editing: hit)
            } else {
                beginTextEntry(atViewPoint: viewPoint)
            }
        case .pen, .highlighter, .line, .arrow, .rect, .roundedRect, .oval,
             .speechBubble, .star, .hexagon:
            let p = imagePoint(from: event)
            current = makeAnnotation(startingAt: p)
            shapeDragStart = p
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isCropping { cropRect = Self.normalizedRect(cropDragStart, imagePoint(from: event)); needsDisplay = true; return }
        if drag != nil { updateDrag(to: imagePoint(from: event)); return }

        guard var cur = current else { return }
        let p = imagePoint(from: event)
        switch cur.kind {
        case .pen(var pts): pts.append(p); cur.kind = .pen(points: pts)
        case .highlighter(var pts): pts.append(p); cur.kind = .highlighter(points: pts)
        case .line(let f, _): cur.kind = .line(from: f, to: p)
        case .arrow(let f, _): cur.kind = .arrow(from: f, to: p)
        case .rect: cur.kind = .rect(Self.normalizedRect(shapeDragStart, p))
        case .roundedRect: cur.kind = .roundedRect(Self.normalizedRect(shapeDragStart, p))
        case .oval: cur.kind = .oval(Self.normalizedRect(shapeDragStart, p))
        case .speechBubble: cur.kind = .speechBubble(Self.normalizedRect(shapeDragStart, p))
        case .star: cur.kind = .star(Self.normalizedRect(shapeDragStart, p))
        case .hexagon: cur.kind = .hexagon(Self.normalizedRect(shapeDragStart, p))
        case .text: break
        }
        current = cur
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isCropping {
            // A stray click (no real drag) must not shrink the crop to nothing.
            if let r = cropRect, r.width < 8 || r.height < 8 {
                cropRect = CGRect(origin: .zero, size: pixelSize)
            }
            needsDisplay = true
            return
        }
        if drag != nil { endDrag(); return }

        guard let cur = current else { return }
        current = nil
        if isMeaningful(cur) { insertAnnotation(cur, at: annotations.count) } else { needsDisplay = true }
    }

    // MARK: - Select-tool interaction

    private func selectMouseDown(_ event: NSEvent) {
        commitTextEntry()
        let viewPoint = convert(event.locationInWindow, from: nil)
        let p = imagePoint(from: event)

        // Grab a resize handle on the existing selection first.
        if let id = selection, let a = annotation(id: id) {
            let h = handle(at: viewPoint, for: a)
            if h != .none { drag = (id, a, h, p); dragMoved = false; return }
        }

        // Otherwise hit-test for a (possibly new) selection to move. (Double-click on a
        // text label is intercepted earlier in mouseDown, so here it only selects/moves.)
        if let hit = annotationHit(at: p) {
            if selection != hit.id {
                selection = hit.id
                onSelectionChanged?(styleInfo(for: hit))
            }
            drag = (hit.id, hit, .move, p)
            dragMoved = false
            needsDisplay = true
        } else {
            clearSelection()
        }
    }

    private func updateDrag(to p: CGPoint) {
        guard let d = drag, let idx = annotations.firstIndex(where: { $0.id == d.id }) else { return }
        let delta = CGPoint(x: p.x - d.start.x, y: p.y - d.start.y)
        if abs(delta.x) + abs(delta.y) > 0.5 { dragMoved = true }

        var a = d.original
        switch d.handle {
        case .move:
            a = Self.translated(d.original, by: delta)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            switch d.original.kind {
            case .rect(let r): a.kind = .rect(Self.resized(r, d.handle, delta))
            case .roundedRect(let r): a.kind = .roundedRect(Self.resized(r, d.handle, delta))
            case .oval(let r): a.kind = .oval(Self.resized(r, d.handle, delta))
            case .speechBubble(let r): a.kind = .speechBubble(Self.resized(r, d.handle, delta))
            case .star(let r): a.kind = .star(Self.resized(r, d.handle, delta))
            case .hexagon(let r): a.kind = .hexagon(Self.resized(r, d.handle, delta))
            default: break
            }
        case .p1, .p2:
            switch d.original.kind {
            case .line(let f, let t):
                a.kind = .line(from: d.handle == .p1 ? f + delta : f, to: d.handle == .p2 ? t + delta : t)
            case .arrow(let f, let t):
                a.kind = .arrow(from: d.handle == .p1 ? f + delta : f, to: d.handle == .p2 ? t + delta : t)
            default: break
            }
        case .none: break
        }
        annotations[idx] = a
        needsDisplay = true
    }

    private func endDrag() {
        guard let d = drag, let idx = annotations.firstIndex(where: { $0.id == d.id }) else { drag = nil; return }
        let final = annotations[idx]
        drag = nil
        if dragMoved {
            changeCount += 1
            undoManager?.registerUndo(withTarget: self) { $0.replaceAnnotation(id: d.id, with: d.original) }
            onSelectionChanged?(styleInfo(for: final))
        }
        needsDisplay = true
    }

    // MARK: - Shape creation

    private func makeAnnotation(startingAt p: CGPoint) -> Annotation? {
        guard let scale = nonZeroScale() else { return nil }
        let w = strokeWidth / scale   // view points → image space
        func shape(_ k: Kind, width: CGFloat) -> Annotation {
            Annotation(kind: k, stroke: strokeColor, fill: nil, lineWidth: width, fontName: textFontName, fontSize: 0)
        }
        func box(_ k: Kind) -> Annotation {
            Annotation(kind: k, stroke: strokeColor, fill: fillColor, lineWidth: w,
                       fontName: textFontName, fontSize: 0)
        }
        let z = CGRect(origin: p, size: .zero)
        switch tool {
        case .pen: return shape(.pen(points: [p]), width: w)
        case .highlighter: return shape(.highlighter(points: [p]), width: w * 4)
        case .line: return shape(.line(from: p, to: p), width: w)
        case .arrow: return shape(.arrow(from: p, to: p), width: w)
        case .rect: return box(.rect(z))
        case .roundedRect: return box(.roundedRect(z))
        case .oval: return box(.oval(z))
        case .speechBubble: return box(.speechBubble(z))
        case .star: return box(.star(z))
        case .hexagon: return box(.hexagon(z))
        case .select, .text:
            return nil
        }
    }

    private func isMeaningful(_ a: Annotation) -> Bool {
        switch a.kind {
        case .pen(let pts), .highlighter(let pts): return !pts.isEmpty
        case .line(let f, let t), .arrow(let f, let t): return hypot(t.x - f.x, t.y - f.y) > 2
        case .rect(let r), .roundedRect(let r), .oval(let r),
             .speechBubble(let r), .star(let r), .hexagon(let r): return r.width > 2 && r.height > 2
        case .text(let s, _): return !s.isEmpty
        }
    }

    // MARK: - Text entry (NSTextField overlay committed into a .text annotation)

    private func beginTextEntry(atViewPoint p: CGPoint, editing existing: Annotation? = nil) {
        commitTextEntry()

        // Editing an existing label: seed the field from it and hide the original while
        // the field is open. The original stays in the stack so commit can update it in
        // place (single undoable step, preserved z-order/identity).
        var origin = p
        var seedString = ""
        editingAnnotation = existing
        if let existing, case let .text(s, at) = existing.kind {
            let (rect, scale) = imageLayout()
            origin = CGPoint(x: rect.minX + at.x * scale, y: rect.minY + at.y * scale)
            seedString = s
            pendingTextStyle = (existing.fontName, existing.fontSize * scale, existing.stroke,
                                existing.bold, existing.italic, existing.underline, existing.alignment)
            needsDisplay = true
        } else {
            pendingTextStyle = (textFontName, textFontSize, textColor,
                                textBold, textItalic, textUnderline, textAlignment)
        }
        let style = pendingTextStyle!

        let field = NSTextField(frame: NSRect(x: origin.x, y: origin.y, width: 220, height: style.viewSize + 10))
        field.font = makeFont(name: style.name, size: style.viewSize, bold: style.bold, italic: style.italic)
        field.textColor = style.color
        field.alignment = style.alignment
        field.stringValue = seedString
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .none
        field.placeholderString = "Type…"
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        activeTextField = field
    }

    /// Commit the active text field (if any) into a stored text annotation.
    func commitTextEntry() {
        guard let field = activeTextField, let style = pendingTextStyle else { return }
        activeTextField = nil
        pendingTextStyle = nil
        let editing = editingAnnotation
        editingAnnotation = nil

        let s = field.stringValue
        let origin = field.frame.origin
        field.removeFromSuperview()
        window?.makeFirstResponder(self)

        // Finished a text box: drop back to the Select tool. This is what stops the
        // "click outside → another box appears" bug — the click that dismisses the field
        // now does a normal select (so you can move the box you just placed), and you tap
        // the Text tool again to add the next one. (When switching to another tool via the
        // toolbar, that tool is set right after this, so it wins.)
        if tool == .text { tool = .select }

        // Editing an existing label: update it in place (one undoable step), or delete it
        // outright when left empty — no invisible stuck box.
        if let editing, case let .text(oldString, at) = editing.kind {
            if s.isEmpty {
                removeAnnotation(id: editing.id)
            } else if s != oldString {
                var updated = editing
                updated.kind = .text(s, at: at)
                replaceAnnotation(id: editing.id, with: updated)
            }
            needsDisplay = true
            return
        }

        // Brand-new text: only store it if the user actually typed something.
        guard !s.isEmpty, let scale = nonZeroScale() else { needsDisplay = true; return }
        let (rect, _) = imageLayout()
        let at = CGPoint(x: (origin.x - rect.minX) / scale, y: (origin.y - rect.minY) / scale)
        insertAnnotation(Annotation(
            kind: .text(s, at: at),
            stroke: style.color, fill: nil, lineWidth: 0,
            fontName: style.name, fontSize: style.viewSize / scale,
            bold: style.bold, italic: style.italic, underline: style.underline, alignment: style.alignment
        ), at: annotations.count)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextEntry() }

    // MARK: - Crop

    func beginCrop() {
        commitTextEntry()
        clearSelection()
        isCropping = true
        cropRect = CGRect(origin: .zero, size: pixelSize)
        needsDisplay = true
        refreshCursor()
        onCropModeChanged?(true)
    }

    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        cropRect = nil
        needsDisplay = true
        refreshCursor()
        onCropModeChanged?(false)
    }

    func applyCrop() {
        guard isCropping else { return }
        isCropping = false
        defer { cropRect = nil; needsDisplay = true; refreshCursor(); onCropModeChanged?(false) }
        guard var r = cropRect else { return }
        r = r.intersection(CGRect(origin: .zero, size: pixelSize))
        guard r.width >= 8, r.height >= 8 else { return }

        let img = croppedImage(r)
        let shift = CGPoint(x: -r.minX, y: -r.minY)
        let newAnns = annotations.map { Self.translated($0, by: shift) }
        applyTransform(image: img, pixelSize: r.size, annotations: newAnns)
    }

    private func cropMouseDown(_ event: NSEvent) {
        cropDragStart = imagePoint(from: event)
        cropRect = CGRect(origin: cropDragStart, size: .zero)
        needsDisplay = true
    }

    private func croppedImage(_ r: CGRect) -> NSImage {
        let w = Int(r.width.rounded()), h = Int(r.height.rounded())
        guard let rep = Self.makeBitmap(w: w, h: h) else { return workingImage }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return workingImage }
        NSGraphicsContext.current = ctx
        // Draw the working image shifted so the crop origin lands at (0,0).
        workingImage.draw(in: NSRect(x: -r.minX, y: -r.minY, width: pixelSize.width, height: pixelSize.height),
                          from: .zero, operation: .copy, fraction: 1)
        ctx.flushGraphics()
        let out = NSImage(size: NSSize(width: w, height: h))
        out.addRepresentation(rep)
        return out
    }

    // MARK: - Rotate

    private func rotate(left: Bool) {
        commitTextEntry()
        let W = pixelSize.width, H = pixelSize.height
        // Point map for a 90° turn (bottom-left origin). Left == counter-clockwise.
        // VERIFY: rotation direction (left == CCW) — visual check in the running app.
        let map: (CGPoint) -> CGPoint = left
            ? { CGPoint(x: H - $0.y, y: $0.x) }
            : { CGPoint(x: $0.y, y: W - $0.x) }
        let newImg = Self.rotatedImage(workingImage, pixelSize: pixelSize, left: left)
        let newAnns = annotations.map { Self.rotated($0, map: map) }
        applyTransform(image: newImg, pixelSize: NSSize(width: H, height: W), annotations: newAnns)
    }

    // MARK: - Font

    private func makeFont(name: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let s = max(2, size)
        // VERIFY: NSFontManager.font(withFamily:traits:weight:size:) — family lookup; weight 5 == regular.
        let fm = NSFontManager.shared
        var font = fm.font(withFamily: name, traits: [], weight: 5, size: s)
            ?? NSFont(name: name, size: s) ?? NSFont.systemFont(ofSize: s)
        // Bold/italic via NSFontManager traits, keeping the chosen family + size.
        font = bold ? fm.convert(font, toHaveTrait: .boldFontMask) : fm.convert(font, toNotHaveTrait: .boldFontMask)
        font = italic ? fm.convert(font, toHaveTrait: .italicFontMask) : fm.convert(font, toNotHaveTrait: .italicFontMask)
        return font
    }

    /// Attributed-string attributes for a text annotation at the given draw scale,
    /// honouring bold/italic, underline, colour and paragraph alignment.
    private func textAttributes(for a: Annotation, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = a.alignment
        var attrs: [NSAttributedString.Key: Any] = [
            .font: makeFont(name: a.fontName, size: max(6, a.fontSize * scale), bold: a.bold, italic: a.italic),
            .foregroundColor: a.stroke,
            .paragraphStyle: para,
        ]
        if a.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    private func textSize(_ s: String, name: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSSize {
        NSString(string: s.isEmpty ? " " : s)
            .size(withAttributes: [.font: makeFont(name: name, size: size, bold: bold, italic: italic)])
    }

    private func styleInfo(for a: Annotation) -> StyleInfo {
        let scale = nonZeroScale() ?? 1
        return StyleInfo(stroke: a.stroke, fill: a.fill, lineWidth: a.lineWidth * scale,
                         fontName: a.fontName, fontSize: a.fontSize * scale, isText: a.kind.isText,
                         bold: a.bold, italic: a.italic, underline: a.underline, alignment: a.alignment)
    }

    // MARK: - Static geometry / imaging helpers

    private static func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Shape path builders (view-space rects)

    /// A 5-point star inscribed in `r` (outer points on the box's inscribed ellipse,
    /// inner radius ≈ 0.382 of the outer — the classic pentagram ratio).
    private static func starPath(in r: NSRect, points n: Int = 5) -> NSBezierPath {
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        let innerRatio: CGFloat = 0.382
        let path = NSBezierPath()
        for i in 0..<(n * 2) {
            let ratio: CGFloat = (i % 2 == 0) ? 1 : innerRatio
            let angle = CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / CGFloat(n)  // start at top
            let pt = CGPoint(x: cx + cos(angle) * rx * ratio, y: cy + sin(angle) * ry * ratio)
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        path.close()
        return path
    }

    /// A regular hexagon inscribed in `r`, with vertices at top and bottom centre.
    private static func hexagonPath(in r: NSRect) -> NSBezierPath {
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        let path = NSBezierPath()
        for i in 0..<6 {
            let angle = CGFloat.pi / 6 + CGFloat(i) * CGFloat.pi / 3  // 30° step start
            let pt = CGPoint(x: cx + cos(angle) * rx, y: cy + sin(angle) * ry)
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        path.close()
        return path
    }

    /// A rounded-rect speech bubble whose body fills `r` above a small tail that hangs
    /// off the bottom-left. Single continuous outline so stroke/fill read cleanly.
    private static func speechBubblePath(in r: NSRect) -> NSBezierPath {
        let w = r.width, h = r.height
        let tailH = min(h * 0.22, w * 0.30)              // vertical extent of the tail
        let by0 = r.minY + tailH                         // body bottom edge
        let by1 = r.maxY                                 // body top edge
        let bx0 = r.minX, bx1 = r.maxX
        let rad = max(1, min(w, by1 - by0) * 0.22)
        // Tail base points on the body's bottom edge, tip below-left.
        let baseL = max(bx0 + rad, r.minX + w * 0.20)
        let baseR = min(bx1 - rad, r.minX + w * 0.34)
        let tipX = r.minX + w * 0.10

        let path = NSBezierPath()
        path.move(to: CGPoint(x: bx0 + rad, y: by0))     // after bottom-left corner arc
        path.line(to: CGPoint(x: baseL, y: by0))         // bottom edge → tail base (left)
        path.line(to: CGPoint(x: tipX, y: r.minY))       // down-left to the tail tip
        path.line(to: CGPoint(x: baseR, y: by0))         // back up to tail base (right)
        path.line(to: CGPoint(x: bx1 - rad, y: by0))     // continue along bottom edge
        path.appendArc(withCenter: CGPoint(x: bx1 - rad, y: by0 + rad), radius: rad,
                       startAngle: 270, endAngle: 360, clockwise: false)  // bottom-right
        path.line(to: CGPoint(x: bx1, y: by1 - rad))     // right edge
        path.appendArc(withCenter: CGPoint(x: bx1 - rad, y: by1 - rad), radius: rad,
                       startAngle: 0, endAngle: 90, clockwise: false)     // top-right
        path.line(to: CGPoint(x: bx0 + rad, y: by1))     // top edge
        path.appendArc(withCenter: CGPoint(x: bx0 + rad, y: by1 - rad), radius: rad,
                       startAngle: 90, endAngle: 180, clockwise: false)   // top-left
        path.line(to: CGPoint(x: bx0, y: by0 + rad))     // left edge
        path.appendArc(withCenter: CGPoint(x: bx0 + rad, y: by0 + rad), radius: rad,
                       startAngle: 180, endAngle: 270, clockwise: false)  // bottom-left
        path.close()
        return path
    }

    private static func bbox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in pts.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func resized(_ r: CGRect, _ handle: Handle, _ d: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .bottomLeft: minX += d.x; minY += d.y
        case .bottomRight: maxX += d.x; minY += d.y
        case .topLeft: minX += d.x; maxY += d.y
        case .topRight: maxX += d.x; maxY += d.y
        default: break
        }
        return normalizedRect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }

    private static func translated(_ a: Annotation, by d: CGPoint) -> Annotation {
        var a = a
        switch a.kind {
        case .pen(let p): a.kind = .pen(points: p.map { $0 + d })
        case .highlighter(let p): a.kind = .highlighter(points: p.map { $0 + d })
        case .line(let f, let t): a.kind = .line(from: f + d, to: t + d)
        case .arrow(let f, let t): a.kind = .arrow(from: f + d, to: t + d)
        case .rect(let r): a.kind = .rect(r.offsetBy(dx: d.x, dy: d.y))
        case .roundedRect(let r): a.kind = .roundedRect(r.offsetBy(dx: d.x, dy: d.y))
        case .oval(let r): a.kind = .oval(r.offsetBy(dx: d.x, dy: d.y))
        case .speechBubble(let r): a.kind = .speechBubble(r.offsetBy(dx: d.x, dy: d.y))
        case .star(let r): a.kind = .star(r.offsetBy(dx: d.x, dy: d.y))
        case .hexagon(let r): a.kind = .hexagon(r.offsetBy(dx: d.x, dy: d.y))
        case .text(let s, let at): a.kind = .text(s, at: at + d)
        }
        return a
    }

    private static func rotated(_ a: Annotation, map f: (CGPoint) -> CGPoint) -> Annotation {
        func rr(_ r: CGRect) -> CGRect { normalizedRect(f(CGPoint(x: r.minX, y: r.minY)), f(CGPoint(x: r.maxX, y: r.maxY))) }
        var a = a
        switch a.kind {
        case .pen(let p): a.kind = .pen(points: p.map(f))
        case .highlighter(let p): a.kind = .highlighter(points: p.map(f))
        case .line(let from, let to): a.kind = .line(from: f(from), to: f(to))
        case .arrow(let from, let to): a.kind = .arrow(from: f(from), to: f(to))
        case .rect(let r): a.kind = .rect(rr(r))
        case .roundedRect(let r): a.kind = .roundedRect(rr(r))
        case .oval(let r): a.kind = .oval(rr(r))
        case .speechBubble(let r): a.kind = .speechBubble(rr(r))
        case .star(let r): a.kind = .star(rr(r))
        case .hexagon(let r): a.kind = .hexagon(rr(r))
        case .text(let s, let at): a.kind = .text(s, at: f(at))  // glyphs stay upright
        }
        return a
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = min(max(t, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private static func distanceToPolyline(_ p: CGPoint, _ pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .greatestFiniteMagnitude }
        if pts.count == 1 { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 1..<pts.count { best = min(best, distanceToSegment(p, pts[i - 1], pts[i])) }
        return best
    }

    /// Hit inside a rect ring: filled shapes hit anywhere inside; unfilled hit only
    /// near the border (within `tol`).
    private static func ringHit(_ p: CGPoint, _ r: CGRect, tol: CGFloat, filled: Bool) -> Bool {
        let outer = r.insetBy(dx: -tol, dy: -tol)
        guard outer.contains(p) else { return false }
        if filled { return true }
        let inner = r.insetBy(dx: tol, dy: tol)
        if inner.width <= 0 || inner.height <= 0 { return true }
        return !inner.contains(p)
    }

    private static func makeBitmap(w: Int, h: Int) -> NSBitmapImageRep? {
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        rep.size = NSSize(width: w, height: h)  // 1 point == 1 pixel: no retina surprises.
        return rep
    }

    private static func rotatedImage(_ image: NSImage, pixelSize ps: NSSize, left: Bool) -> NSImage {
        let w = Int(ps.width.rounded()), h = Int(ps.height.rounded())
        guard let rep = makeBitmap(w: h, h: w) else { return image }  // dimensions swap
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let nsctx = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.current = nsctx
        let cg = nsctx.cgContext
        let W = CGFloat(w), H = CGFloat(h)
        // CGContext applies the most-recent transform first to points, so these build
        // (translate ∘ rotate) — the inverse of the annotation point map above.
        if left { cg.translateBy(x: H, y: 0); cg.rotate(by: .pi / 2) }
        else { cg.translateBy(x: 0, y: W); cg.rotate(by: -.pi / 2) }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nsctx, hints: nil) {
            cg.draw(cgImage, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        nsctx.flushGraphics()
        let out = NSImage(size: NSSize(width: h, height: w))
        out.addRepresentation(rep)
        return out
    }

    private static func pixelSize(of image: NSImage) -> NSSize {
        var w = 0, h = 0
        for rep in image.representations { w = max(w, rep.pixelsWide); h = max(h, rep.pixelsHigh) }
        if w == 0 || h == 0 { return image.size }
        return NSSize(width: w, height: h)
    }
}

// MARK: - CGPoint arithmetic

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
}
