import AppKit
import UniformTypeIdentifiers

/// A Markup-parity image editor for a single screenshot.
///
/// Presents a titled, resizable window with a top toolbar over an `AnnotationCanvas`,
/// laid out like Apple's native Markup toolbar: the tool picker on the left (Select,
/// Draw, Highlighter, a "Shapes" fly-out grouping line/arrow/rectangle/rounded-rect/
/// oval/speech-bubble/star/hexagon, and Text), then compact inline style
/// controls always visible to its right (line thickness pop-up, stroke colour well,
/// fill colour well + on/off, and an "Aa" button opening a small transient text-style
/// popover with font family, size, bold/italic/underline, and paragraph alignment),
/// and the action group on the right (undo, redo, clear, rotate, crop, Share, Copy,
/// Save, Delete). The caller hands in an image, distinct `onCopy` / `onSave` closures,
/// and an optional `onDelete` closure; both style-callback closures receive a
/// flattened, full-resolution `NSImage`.
///
/// Loosely coupled: no dependencies on other Capture + modules.
///
/// Usage:
/// ```
/// let editor = AnnotationWindowController()
/// editor.present(image: shot, suggestedName: "Screenshot", defaultSaveDirectory: dir) { flattened in
///     // Copy: put `flattened` on the pasteboard, then the editor closes.
/// } onSave: { flattened, url in
///     // Save: write `flattened` to the user-chosen `url`, then the editor closes.
/// } onDelete: {
///     // user confirmed deletion of the underlying screenshot file.
/// }
/// ```
///
/// Callback semantics: **Copy** flattens, calls `onCopy(flattened)`, and closes the
/// window (so the caller can minimize it back to the corner thumbnail). **Save**
/// flattens, then presents an `NSSavePanel` as a sheet on the editor window; on OK it
/// calls `onSave(flattened, url)` and closes, on cancel the window stays open. The
/// destructive **Delete** button prompts and, if confirmed, fires `onDelete()` and
/// closes. Closing the window with unsaved annotations prompts to confirm; a plain
/// discard/close fires none of the callbacks.
@MainActor
final class AnnotationWindowController: NSWindowController {

    // MARK: - Live-instance retention
    // present() is typically called on a freshly created controller the caller does
    // not retain; keep ourselves alive for the window's lifetime.
    private static var liveControllers: Set<AnnotationWindowController> = []

    // MARK: - State
    private var canvas: AnnotationCanvas?
    private var onCopy: ((NSImage) -> Void)?
    private var onSave: ((NSImage, URL) -> Void)?
    private var onDelete: (() -> Void)?
    private var didClose = false
    /// `canvas.changeCount` as of the last Copy/Save. Used to detect unsaved edits.
    private var lastSavedChangeCount = 0

    /// Name suggested by the caller; used for the window title and the save panel's
    /// default filename.
    private var suggestedName = ""
    /// Directory the save panel opens to (if it still exists).
    private var defaultSaveDirectory: URL?

    // Controls kept for wiring / selection sync.
    private var toolSegments: NSSegmentedControl?
    /// Index of the "Shapes" segment in `toolSegments` (the fly-out dropdown).
    private var shapesSegmentIndex = 0
    /// The shape most recently chosen from the Shapes fly-out; what the Shapes segment
    /// activates when tapped, and whose icon the segment displays.
    private var currentShapeTool: AnnotationCanvas.Tool = .rect
    private var strokeWell: NSColorWell?
    private var fillWell: NSColorWell?
    private var fillCheck: NSButton?
    private var thicknessButton: NSButton?
    private var currentThicknessIndex: Int = 1
    private var textStyleButton: NSButton?
    private var cropApplyButton: NSButton?
    private var cropCancelButton: NSButton?
    private let textStyleVC = TextStyleViewController()
    private var textPopover: NSPopover?

    /// One entry per segment of the tool picker (index == segment). The `.shapes`
    /// entry is the fly-out dropdown; every other entry maps 1:1 to a `Tool`.
    private enum ToolSegment: Hashable {
        case tool(AnnotationCanvas.Tool)
        case shapes
    }
    /// Top-level tool picker, Apple-Markup style: Select, Draw, Highlighter, Shapes▾, Text.
    private let segmentModel: [ToolSegment] =
        [.tool(.select), .tool(.pen), .tool(.highlighter), .shapes, .tool(.text)]

    /// The shapes offered by the Shapes fly-out (order == menu order). Each carries an
    /// SF Symbol shown both in the menu and, when active, on the Shapes segment itself.
    private let shapeMenu: [(tool: AnnotationCanvas.Tool, symbol: String, title: String)] = [
        (.line, "line.diagonal", "Line"),
        (.arrow, "arrow.up.right", "Arrow"),
        (.rect, "rectangle", "Rectangle"),
        (.roundedRect, "app", "Rounded Rectangle"),
        (.oval, "oval", "Oval"),
        (.speechBubble, "bubble.left", "Speech Bubble"),
        (.star, "star", "Star"),
        (.hexagon, "hexagon", "Hexagon"),
    ]
    /// Neutral icon shown on the Shapes segment before any shape has been picked.
    private let shapesDefaultSymbol = "square.on.circle"
    /// Line-thickness presets (view points) for the thickness pop-up.
    private let thicknessPresets: [(name: String, width: CGFloat)] = [
        ("Thin", 2), ("Medium", 4), ("Thick", 8), ("Extra", 14),
    ]
    private let defaultFontFamily = NSFont.systemFont(ofSize: 12).familyName ?? "Helvetica Neue"

    // MARK: - Init
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Annotate"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// Present the editor for `image`. **Copy** calls `onCopy(flattened)` then closes;
    /// **Save** presents a save-panel sheet and, on OK, calls `onSave(flattened, url)`
    /// then closes. `onDelete`, if supplied, fires when the user confirms the
    /// destructive Delete action. `defaultSaveDirectory`, if set, is where the save
    /// panel opens.
    func present(image: NSImage,
                 suggestedName: String,
                 defaultSaveDirectory: URL?,
                 onCopy: @escaping (NSImage) -> Void,
                 onSave: @escaping (NSImage, URL) -> Void,
                 onDelete: (() -> Void)? = nil) {
        self.onCopy = onCopy
        self.onSave = onSave
        self.onDelete = onDelete
        self.suggestedName = suggestedName
        self.defaultSaveDirectory = defaultSaveDirectory
        self.didClose = false
        self.lastSavedChangeCount = 0
        AnnotationWindowController.liveControllers.insert(self)

        guard let window = self.window else { return }
        window.title = suggestedName.isEmpty ? "Annotate" : "Annotate \(suggestedName)"

        let canvas = AnnotationCanvas(image: image)
        canvas.tool = .pen
        canvas.setStrokeColor(.systemRed)
        canvas.setFillColor(nil)
        canvas.setLineWidth(thicknessPresets[1].width)
        canvas.setTextColor(.systemRed)
        canvas.setTextFont(name: defaultFontFamily, size: 24)
        canvas.onSelectionChanged = { [weak self] info in self?.syncControls(to: info) }
        canvas.onToolChanged = { [weak self] tool in self?.reactToToolChange(tool) }
        canvas.onCropModeChanged = { [weak self] active in active ? self?.enterCropUI() : self?.exitCropUI() }
        self.canvas = canvas

        buildContent(canvas: canvas, in: window)
        // Sync the tool picker to the initial tool.
        reactToToolChange(canvas.tool)
        sizeWindow(to: canvas.pixelSize, window: window)

        // Menu-bar/accessory app: bring the window forward so it's usable.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// Debug / render-harness only.
    func debugPopulateShapes() { canvas?.debugPopulateShapes() }
    func debugTextCommitSelfTest() -> String { canvas?.debugTextCommitSelfTest() ?? "no canvas" }

    // MARK: - Window sizing

    private func sizeWindow(to pixelSize: NSSize, window: NSWindow) {
        let barH: CGFloat = 52
        let minW: CGFloat = 1040
        let maxW: CGFloat = 1280, maxH: CGFloat = 760
        let scale = min(1, min(maxW / max(1, pixelSize.width), (maxH - barH) / max(1, pixelSize.height)))
        let cw = max(minW, pixelSize.width * scale)
        let ch = max(240, pixelSize.height * scale)
        window.contentMinSize = NSSize(width: minW, height: 240 + barH)
        window.setContentSize(NSSize(width: cw, height: ch + barH))
        window.center()
    }

    // MARK: - UI construction

    private func buildContent(canvas: AnnotationCanvas, in window: NSWindow) {
        let container = NSView()
        let barHeight: CGFloat = 52

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(canvas)
        container.addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: barHeight),

            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        buildToolbar(in: bar)
        window.contentView = container
    }

    private func buildToolbar(in bar: NSView) {
        // Apple-Markup layout: the tool picker plus compact, always-visible inline
        // style controls on the left; the action group on the right.
        let leftViews: [NSView] = [buildToolControl(), makeSeparator()] + buildStyleControls()
        let leftStack = NSStackView(views: leftViews)
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 8
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: buildActionControls())
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 6
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(leftStack)
        bar.addSubview(rightStack)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            leftStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rightStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            rightStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
        ])
    }

    /// Left group: the top-level tool picker. Shapes are collapsed under one "Shapes"
    /// segment that flies out a menu of individual shapes (Apple-Markup style); the
    /// Text tool uses a distinct glyph so it isn't confused with the "Aa" style button.
    private func buildToolControl() -> NSView {
        // Per-segment icon + tooltip. The Shapes segment shows a neutral shapes glyph
        // until a specific shape is chosen (then it reflects that shape).
        let icons: [ToolSegment: (symbol: String, label: String)] = [
            .tool(.select): ("cursorarrow", "Select"),
            .tool(.pen): ("pencil.tip", "Draw"),
            .tool(.highlighter): ("highlighter", "Highlighter"),
            .shapes: (shapesDefaultSymbol, "Shapes"),
            .tool(.text): ("character.textbox", "Text"),
        ]

        let seg = NSSegmentedControl()
        seg.segmentCount = segmentModel.count
        seg.trackingMode = .selectOne
        for (i, entry) in segmentModel.enumerated() {
            let icon = icons[entry] ?? ("questionmark", "?")
            // The Shapes segment is a dropdown, so it carries a trailing chevron.
            let img = (entry == .shapes)
                ? iconWithChevron(icon.symbol)
                : NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.label)
            if let img {
                seg.setImage(img, forSegment: i)
            } else {
                seg.setLabel(icon.label, forSegment: i)
            }
            seg.setToolTip(entry == .shapes ? "Shapes" : icon.label, forSegment: i)
            seg.setWidth(entry == .shapes ? 50 : 32, forSegment: i)
            if entry == .shapes { shapesSegmentIndex = i }
        }
        // Select "Draw" initially (matches the canvas's initial .pen tool).
        seg.selectedSegment = segmentModel.firstIndex(of: .tool(.pen)) ?? 1
        seg.target = self
        seg.action = #selector(toolChanged(_:))
        self.toolSegments = seg
        return seg
    }

    /// Compose an SF Symbol with a small trailing `chevron.down`, so a control reads as a
    /// dropdown — matching Apple's Markup toolbar, where every menu/popover control has a ⌄.
    private func iconWithChevron(_ symbol: String, pointSize: CGFloat = 15) -> NSImage? {
        let baseCfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let chevCfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(baseCfg),
              let chev = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(chevCfg) else {
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        let gap: CGFloat = 3
        let w = base.size.width + gap + chev.size.width
        let h = max(base.size.height, chev.size.height)
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        base.draw(at: NSPoint(x: 0, y: (h - base.size.height) / 2),
                  from: .zero, operation: .sourceOver, fraction: 1)
        chev.draw(at: NSPoint(x: base.size.width + gap, y: (h - chev.size.height) / 2),
                  from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        out.isTemplate = true
        return out
    }

    /// Build the compact, always-visible inline style controls (Apple-Markup style):
    /// a line-thickness pop-up, a stroke colour well, a fill colour well + on/off
    /// checkbox, and an "Aa" button that opens the small transient text-style popover.
    private func buildStyleControls() -> [NSView] {
        // Shape style (line weight): an ICON dropdown, like Apple's ≡ control — not a
        // text pop-up. Tapping it pops a menu of weights.
        let thickness = NSButton()
        thickness.bezelStyle = .texturedRounded
        thickness.setButtonType(.momentaryPushIn)
        thickness.image = iconWithChevron("lineweight")   // ≡ with a dropdown ⌄
        thickness.imagePosition = .imageOnly
        thickness.toolTip = "Shape style"
        thickness.target = self
        thickness.action = #selector(thicknessMenuTapped(_:))
        thickness.translatesAutoresizingMaskIntoConstraints = false
        thickness.widthAnchor.constraint(equalToConstant: 46).isActive = true
        self.thicknessButton = thickness

        // Border colour: a compact swatch (opens the colour picker).
        let stroke = makeWell(color: .systemRed, tooltip: "Border colour", action: #selector(strokeColorChanged(_:)))
        self.strokeWell = stroke

        // Fill: an ICON toggle (slashed-square = off, filled-square = on) + a swatch,
        // instead of an empty checkbox.
        let fillToggle = NSButton()
        fillToggle.bezelStyle = .texturedRounded
        fillToggle.setButtonType(.toggle)
        fillToggle.image = NSImage(systemSymbolName: "square.slash", accessibilityDescription: "No fill")
        fillToggle.alternateImage = NSImage(systemSymbolName: "square.fill", accessibilityDescription: "Fill on")
        fillToggle.imagePosition = .imageOnly
        fillToggle.state = .off
        fillToggle.toolTip = "Fill on/off"
        fillToggle.target = self
        fillToggle.action = #selector(fillToggled(_:))
        fillToggle.translatesAutoresizingMaskIntoConstraints = false
        fillToggle.widthAnchor.constraint(equalToConstant: 30).isActive = true
        self.fillCheck = fillToggle
        let fill = makeWell(color: .systemYellow, tooltip: "Fill colour", action: #selector(fillColorChanged(_:)))
        self.fillWell = fill

        // Text-style button (opens the transient "Aa" popover).
        let textButton = NSButton(title: "Aa", target: self, action: #selector(textStyleTapped(_:)))
        textButton.bezelStyle = .texturedRounded
        textButton.setButtonType(.momentaryPushIn)
        textButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        textButton.image?.isTemplate = true
        textButton.imagePosition = .imageTrailing   // "Aa ⌄"
        textButton.toolTip = "Text style"
        textButton.translatesAutoresizingMaskIntoConstraints = false
        textButton.widthAnchor.constraint(equalToConstant: 54).isActive = true
        self.textStyleButton = textButton

        // Wire the text-style popover's controls to the canvas.
        textStyleVC.configure(family: defaultFontFamily, size: 24, color: .systemRed,
                              bold: false, italic: false, underline: false, alignment: .left)
        textStyleVC.onFontChange = { [weak self] name, size in self?.canvas?.setTextFont(name: name, size: size) }
        textStyleVC.onColorChange = { [weak self] color in self?.canvas?.setTextColor(color) }
        textStyleVC.onBoldChange = { [weak self] on in self?.canvas?.setTextBold(on) }
        textStyleVC.onItalicChange = { [weak self] on in self?.canvas?.setTextItalic(on) }
        textStyleVC.onUnderlineChange = { [weak self] on in self?.canvas?.setTextUnderline(on) }
        textStyleVC.onAlignmentChange = { [weak self] a in self?.canvas?.setTextAlignment(a) }

        return [thickness, stroke, fillToggle, fill, makeSeparator(), textButton]
    }

    /// Right group: undo/redo/clear, rotate/crop, then Copy/Save/Delete.
    private func buildActionControls() -> [NSView] {
        let undo = makeIconButton("arrow.uturn.backward", tooltip: "Undo", action: #selector(undoTapped))
        let redo = makeIconButton("arrow.uturn.forward", tooltip: "Redo", action: #selector(redoTapped))
        let clear = makeIconButton("trash", tooltip: "Clear all", action: #selector(clearTapped))
        let rotateL = makeIconButton("rotate.left", tooltip: "Rotate left", action: #selector(rotateLeftTapped))
        let rotateR = makeIconButton("rotate.right", tooltip: "Rotate right", action: #selector(rotateRightTapped))
        let crop = makeIconButton("crop", tooltip: "Crop", action: #selector(cropTapped))

        let cropApply = makeButton(title: "Apply", action: #selector(cropApplyTapped))
        cropApply.bezelColor = NSColor.controlAccentColor
        cropApply.isHidden = true
        self.cropApplyButton = cropApply
        let cropCancel = makeButton(title: "Cancel", action: #selector(cropCancelTapped))
        cropCancel.isHidden = true
        self.cropCancelButton = cropCancel

        let share = makeIconButton("square.and.arrow.up", tooltip: "Share", action: #selector(shareTapped(_:)))
        let copy = makeButton(title: "Copy", action: #selector(copyTapped))
        let save = makeButton(title: "Save", action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        save.bezelColor = NSColor.controlAccentColor
        let delete = makeButton(title: "Delete", action: #selector(deleteTapped))
        delete.hasDestructiveAction = true
        delete.bezelColor = NSColor.systemRed

        return [undo, redo, clear, makeSeparator(), rotateL, rotateR, crop,
                cropApply, cropCancel, makeSeparator(), share, copy, save, delete]
    }

    // MARK: - Control factories

    private func makeWell(color: NSColor, tooltip: String, action: Selector) -> NSColorWell {
        let well = NSColorWell()
        // Minimal style keeps the swatch compact so it fits inline in the toolbar.
        well.colorWellStyle = .minimal
        well.color = color
        well.toolTip = tooltip
        well.target = self
        well.action = action
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 30).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return well
    }

    private func makeIconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return box
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        return button
    }

    // MARK: - Toolbar actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        let i = sender.selectedSegment
        guard segmentModel.indices.contains(i) else { return }
        canvas?.cancelCrop()   // no-op unless a crop was in progress
        canvas?.commitTextEntry()

        switch segmentModel[i] {
        case .tool(let tool):
            canvas?.tool = tool
            reactToToolChange(tool)
        case .shapes:
            // Tapping Shapes activates the last-used shape and pops the fly-out so the
            // user can switch shapes (re-opens the menu even if a shape is already active).
            canvas?.tool = currentShapeTool
            reactToToolChange(currentShapeTool)
            showShapesMenu(from: sender)
        }
    }

    /// Pop the Shapes fly-out beneath the Shapes segment.
    private func showShapesMenu(from seg: NSSegmentedControl) {
        let menu = NSMenu()
        for entry in shapeMenu {
            let item = NSMenuItem(title: entry.title, action: #selector(shapeMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.title   // resolve back to the tool on selection
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.title)
            item.state = (entry.tool == currentShapeTool && canvas?.tool.isShape == true) ? .on : .off
            menu.addItem(item)
        }
        // Position the menu just below the Shapes segment. Segment frames aren't exposed,
        // so approximate the segment's x-origin from its index and per-segment widths.
        var x: CGFloat = 0
        for i in 0..<shapesSegmentIndex { x += seg.width(forSegment: i) }
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: seg.bounds.maxY + 2), in: seg)
    }

    @objc private func shapeMenuItem(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String,
              let entry = shapeMenu.first(where: { $0.title == title }) else { return }
        currentShapeTool = entry.tool
        canvas?.cancelCrop()
        canvas?.commitTextEntry()
        canvas?.tool = entry.tool
        reactToToolChange(entry.tool)
    }

    // MARK: - Tool selection

    /// Reflect a tool change in the toolbar. A plain tool selects its own segment; any
    /// shape tool selects the Shapes segment instead and stamps that shape's icon onto
    /// it (so the toolbar mirrors the active shape, like Apple). The always-visible
    /// style controls need no show/hide here.
    private func reactToToolChange(_ tool: AnnotationCanvas.Tool) {
        if tool.isShape {
            currentShapeTool = tool
            updateShapesSegmentIcon(for: tool)
            if toolSegments?.selectedSegment != shapesSegmentIndex {
                toolSegments?.selectedSegment = shapesSegmentIndex
            }
        } else if let i = segmentModel.firstIndex(of: .tool(tool)),
                  toolSegments?.selectedSegment != i {
            toolSegments?.selectedSegment = i
        }
    }

    /// Stamp the active shape's SF Symbol onto the Shapes segment.
    private func updateShapesSegmentIcon(for tool: AnnotationCanvas.Tool) {
        guard let entry = shapeMenu.first(where: { $0.tool == tool }),
              let img = iconWithChevron(entry.symbol) else { return }
        toolSegments?.setImage(img, forSegment: shapesSegmentIndex)
        toolSegments?.setToolTip(entry.title, forSegment: shapesSegmentIndex)
    }

    @objc private func strokeColorChanged(_ sender: NSColorWell) {
        canvas?.setStrokeColor(sender.color)
    }

    @objc private func fillColorChanged(_ sender: NSColorWell) {
        // Picking a fill colour implies turning fill on.
        fillCheck?.state = .on
        canvas?.setFillColor(sender.color)
    }

    @objc private func fillToggled(_ sender: NSButton) {
        canvas?.setFillColor(sender.state == .on ? (fillWell?.color ?? .systemYellow) : nil)
    }

    @objc private func thicknessMenuTapped(_ sender: NSButton) {
        let menu = NSMenu()
        for (i, preset) in thicknessPresets.enumerated() {
            let mi = NSMenuItem(title: preset.name, action: #selector(thicknessMenuItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = (i == currentThicknessIndex) ? .on : .off
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func thicknessMenuItem(_ sender: NSMenuItem) {
        guard thicknessPresets.indices.contains(sender.tag) else { return }
        currentThicknessIndex = sender.tag
        canvas?.setLineWidth(thicknessPresets[sender.tag].width)
    }

    @objc private func textStyleTapped(_ sender: NSButton) {
        let popover: NSPopover
        if let existing = textPopover {
            popover = existing
        } else {
            let p = NSPopover()
            p.behavior = .transient
            p.contentViewController = textStyleVC
            textPopover = p
            popover = p
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        }
    }

    @objc private func undoTapped() { canvas?.undo() }
    @objc private func redoTapped() { canvas?.redo() }
    @objc private func clearTapped() { canvas?.clearAll() }
    @objc private func rotateLeftTapped() { canvas?.rotateLeft() }
    @objc private func rotateRightTapped() { canvas?.rotateRight() }

    // MARK: - Crop UI

    @objc private func cropTapped() { canvas?.beginCrop() }
    @objc private func cropApplyTapped() { canvas?.applyCrop() }
    @objc private func cropCancelTapped() { canvas?.cancelCrop() }

    private func enterCropUI() {
        cropApplyButton?.isHidden = false
        cropCancelButton?.isHidden = false
        toolSegments?.isEnabled = false
        textPopover?.performClose(nil)   // stay out of the way while cropping
    }

    private func exitCropUI() {
        cropApplyButton?.isHidden = true
        cropCancelButton?.isHidden = true
        toolSegments?.isEnabled = true
    }

    // MARK: - Selection → toolbar sync

    private func syncControls(to info: AnnotationCanvas.StyleInfo?) {
        guard let info else { return }  // deselection keeps the current defaults
        if info.isText {
            textStyleVC.configure(family: info.fontName, size: info.fontSize, color: info.stroke,
                                  bold: info.bold, italic: info.italic,
                                  underline: info.underline, alignment: info.alignment)
        } else {
            strokeWell?.color = info.stroke
            if let fill = info.fill {
                fillCheck?.state = .on
                fillWell?.color = fill
            } else {
                fillCheck?.state = .off
            }
            currentThicknessIndex = nearestThicknessIndex(info.lineWidth)
        }
    }

    private func nearestThicknessIndex(_ width: CGFloat) -> Int {
        var best = 0
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for (i, preset) in thicknessPresets.enumerated() {
            let d = abs(preset.width - width)
            if d < bestDelta { bestDelta = d; best = i }
        }
        return best
    }

    // MARK: - Export actions

    @objc private func shareTapped(_ sender: NSButton) {
        canvas?.commitTextEntry()
        guard let image = canvas?.flattenedImage() else { return }
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func copyTapped() {
        canvas?.commitTextEntry()
        guard let image = canvas?.flattenedImage() else { return }
        markSaved()
        onCopy?(image)     // caller puts it on the pasteboard
        closeEditor()      // then close so the caller can minimize to the corner thumbnail
    }

    @objc private func saveTapped() {
        canvas?.commitTextEntry()
        guard let window, let image = canvas?.flattenedImage() else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = (suggestedName.isEmpty ? "Screenshot" : suggestedName) + ".png"
        panel.allowedContentTypes = [.png]
        if let dir = defaultSaveDirectory,
           (try? dir.checkResourceIsReachable()) == true {
            panel.directoryURL = dir
        }
        // A real, visible directory dialog attached to the editor window.
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }  // cancel: keep editing
            self.markSaved()
            self.onSave?(image, url)
            self.closeEditor()
        }
    }

    // MARK: - Delete

    @objc private func deleteTapped() {
        let alert = NSAlert()
        alert.messageText = "Delete this screenshot?"
        alert.informativeText = "It will be removed from your screenshots folder."
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let onDelete = self.onDelete
        onDelete?()
        closeEditor()
    }

    // MARK: - Teardown

    /// Record that the current annotation state has been exported (copied/saved),
    /// so the close confirmation won't treat it as unsaved.
    private func markSaved() {
        lastSavedChangeCount = canvas?.changeCount ?? 0
    }

    /// True if there are committed annotations that haven't been copied or saved.
    private var hasUnsavedAnnotations: Bool {
        guard let canvas else { return false }
        return canvas.hasAnnotations && canvas.changeCount != lastSavedChangeCount
    }

    /// Close the editor and drop our callbacks and self-retention. Any callback the
    /// caller should receive (`onCopy`/`onSave`/`onDelete`) must be fired *before*
    /// this is called; a plain close fires none of them. `didClose` is set first so
    /// the window's close delegate is a no-op.
    private func closeEditor() {
        guard !didClose else { return }
        didClose = true

        self.onCopy = nil
        self.onSave = nil
        self.onDelete = nil

        textPopover?.performClose(nil)
        textPopover = nil
        window?.orderOut(nil)
        AnnotationWindowController.liveControllers.remove(self)
    }
}

// MARK: - NSWindowDelegate

extension AnnotationWindowController: NSWindowDelegate {
    // Guard the red close button (and any user-initiated close): if there are
    // annotations that were never copied or saved, confirm before losing them.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if didClose { return true }
        guard let window else { return true }
        canvas?.commitTextEntry()

        // ALWAYS confirm on the red close button so the user knows what's happening. Use
        // a SHEET (async, non-blocking) rather than a blocking runModal — better UX and it
        // can actually be verified. windowShouldClose returns false; the sheet decides.
        let unsaved = hasUnsavedAnnotations
        let alert = NSAlert()
        alert.alertStyle = .warning
        if unsaved {
            alert.messageText = "Save your annotations before closing?"
            alert.informativeText = "Your marked-up image hasn't been saved yet. The original "
                + "screenshot is still on your clipboard, so nothing is lost either way."
            alert.addButton(withTitle: "Save…")                  // first
            let discard = alert.addButton(withTitle: "Discard")  // second
            discard.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")                 // third
        } else {
            alert.messageText = "Close this screenshot?"
            alert.informativeText = "It's already on your clipboard — nothing was saved to disk. "
                + "Closing just dismisses this window."
            alert.addButton(withTitle: "Close")                  // first
            alert.addButton(withTitle: "Cancel")                 // second
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if unsaved {
                switch response {
                case .alertFirstButtonReturn: self.saveTapped()   // Save…
                case .alertSecondButtonReturn: self.closeEditor() // Discard
                default: break                                    // Cancel: keep editing
                }
            } else if response == .alertFirstButtonReturn {
                self.closeEditor()                                // Close
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // A user-initiated close that reaches here (past windowShouldClose) is a plain
        // discard: fire none of the callbacks, just tear down.
        closeEditor()
    }
}

// MARK: - Text-style popover

/// The content of the "Aa" text-style popover, arranged like Apple's Markup one: a
/// font-family pop-up, a size field + stepper, a Bold/Italic/Underline row, a colour
/// well, and a 4-way paragraph-alignment row. Reports changes through its `on…`
/// callbacks.
@MainActor
private final class TextStyleViewController: NSViewController {

    var onFontChange: ((String, CGFloat) -> Void)?
    var onColorChange: ((NSColor) -> Void)?
    var onBoldChange: ((Bool) -> Void)?
    var onItalicChange: ((Bool) -> Void)?
    var onUnderlineChange: ((Bool) -> Void)?
    var onAlignmentChange: ((NSTextAlignment) -> Void)?

    private let familyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let colorWell = NSColorWell()
    private let traitSegments = NSSegmentedControl()
    private let alignSegments = NSSegmentedControl()
    private var currentSize: CGFloat = 24

    /// Alignment order for the 4-segment control (index == segment).
    private let alignments: [NSTextAlignment] = [.left, .center, .right, .justified]

    init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        familyPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        familyPopup.target = self
        familyPopup.action = #selector(fontChanged)

        sizeField.stringValue = "24"
        sizeField.alignment = .right
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged)
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.widthAnchor.constraint(equalToConstant: 52).isActive = true

        sizeStepper.minValue = 6
        sizeStepper.maxValue = 288
        sizeStepper.increment = 1
        sizeStepper.integerValue = 24
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(stepperChanged)

        // Bold / Italic / Underline — independent toggles (.selectAny).
        traitSegments.segmentCount = 3
        traitSegments.trackingMode = .selectAny
        for (i, title) in ["B", "I", "U"].enumerated() {
            traitSegments.setLabel(title, forSegment: i)
            traitSegments.setWidth(30, forSegment: i)
            traitSegments.setSelected(false, forSegment: i)
        }
        traitSegments.target = self
        traitSegments.action = #selector(traitsChanged)

        // Paragraph alignment — mutually exclusive (.selectOne).
        alignSegments.segmentCount = 4
        alignSegments.trackingMode = .selectOne
        let alignIcons = ["text.alignleft", "text.aligncenter", "text.alignright", "text.justify"]
        for (i, symbol) in alignIcons.enumerated() {
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                alignSegments.setImage(img, forSegment: i)
            } else {
                alignSegments.setLabel(["L", "C", "R", "J"][i], forSegment: i)
            }
            alignSegments.setWidth(30, forSegment: i)
        }
        alignSegments.selectedSegment = 0
        alignSegments.target = self
        alignSegments.action = #selector(alignmentChanged)

        colorWell.colorWellStyle = .minimal
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let rows = NSStackView(views: [
            row("Font", familyPopup),
            row("Size", sizeField, sizeStepper),
            row("Style", traitSegments),
            row("Align", alignSegments),
            row("Colour", colorWell),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        container.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            rows.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        self.view = container
        self.preferredContentSize = NSSize(width: 300, height: 200)
    }

    /// Set the popover's controls without emitting change callbacks (setting control
    /// values programmatically does not fire their target/action).
    func configure(family: String, size: CGFloat, color: NSColor,
                   bold: Bool, italic: Bool, underline: Bool, alignment: NSTextAlignment) {
        _ = view  // ensure controls exist
        if familyPopup.itemTitles.contains(family) {
            familyPopup.selectItem(withTitle: family)
        }
        currentSize = size
        sizeField.stringValue = String(Int(size.rounded()))
        sizeStepper.integerValue = Int(size.rounded())
        colorWell.color = color
        traitSegments.setSelected(bold, forSegment: 0)
        traitSegments.setSelected(italic, forSegment: 1)
        traitSegments.setSelected(underline, forSegment: 2)
        alignSegments.selectedSegment = alignments.firstIndex(of: alignment) ?? 0
    }

    private func row(_ label: String, _ controls: NSView...) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.font = NSFont.systemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let stack = NSStackView(views: [title] + controls)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func emitFont() {
        onFontChange?(familyPopup.titleOfSelectedItem ?? familyPopup.itemTitle(at: 0), currentSize)
    }

    @objc private func fontChanged() { emitFont() }

    @objc private func sizeFieldChanged() {
        let v = max(6, min(288, CGFloat(sizeField.doubleValue == 0 ? 24 : sizeField.doubleValue)))
        currentSize = v
        sizeStepper.integerValue = Int(v)
        sizeField.stringValue = String(Int(v))
        emitFont()
    }

    @objc private func stepperChanged() {
        currentSize = CGFloat(sizeStepper.integerValue)
        sizeField.stringValue = String(sizeStepper.integerValue)
        emitFont()
    }

    @objc private func traitsChanged() {
        onBoldChange?(traitSegments.isSelected(forSegment: 0))
        onItalicChange?(traitSegments.isSelected(forSegment: 1))
        onUnderlineChange?(traitSegments.isSelected(forSegment: 2))
    }

    @objc private func alignmentChanged() {
        let i = alignSegments.selectedSegment
        guard alignments.indices.contains(i) else { return }
        onAlignmentChange?(alignments[i])
    }

    @objc private func colorChanged() { onColorChange?(colorWell.color) }
}
