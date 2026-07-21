import AppKit
import SwiftUI

// MARK: - Actions

/// The closures the HUD invokes for its action buttons. The controller supplies these
/// per-capture; each fires on the main thread when the matching control is clicked.
struct ScreenshotHUDActions {
    var onCopy: () -> Void
    var onAnnotate: () -> Void
    var onSaveAs: () -> Void
    /// Right-click menu: write the current capture's PNG to ~/Desktop.
    var onSaveToDesktop: () -> Void
    /// Right-click menu: write the current capture's PNG to ~/Documents.
    var onSaveToDocuments: () -> Void
    /// Right-click menu: open the capture in Preview.app.
    var onOpenInPreview: () -> Void
    /// Right-click menu: reveal the capture in Finder.
    var onShowInFinder: () -> Void
    /// Right-click menu: delete the current (temp/stored) capture and dismiss the HUD.
    var onDelete: () -> Void
    /// Right-click menu: dismiss the HUD without side effects.
    var onClose: () -> Void
    /// Resting caption for the HUD. Empty → a neutral "Copy · Annotate · Save" hint
    /// (the default, since a copy-only shot isn't saved anywhere); otherwise e.g.
    /// "Kept in <folder>" when the keep-screenshots setting is on.
    var saveLocationName: String
    /// User-defined quick-save folders listed under the "Save to ▸" menu.
    var presets: [ScreenshotPreset]
    /// Called when the user picks one of `presets` from the "Save to ▸" menu.
    var onSaveToPreset: (ScreenshotPreset) -> Void
    /// Optional: called when the HUD dismisses itself (timeout, Escape, or ✕).
    var onDismiss: (() -> Void)?
}

// MARK: - View model

/// Backing store for the HUD view: the thumbnail plus the wired-up callbacks. The
/// controller owns this and updates it in place when a new capture arrives.
@MainActor
final class ScreenshotHUDModel: ObservableObject {
    @Published var image: NSImage
    /// The label of the control the pointer is currently over, shown in the caption
    /// row so the icons are self-explanatory. nil = show the default hint.
    @Published var hoveredLabel: String?

    /// True briefly after a Copy tap, to show a "✓ Copied" confirmation.
    @Published var copied = false

    var actions: ScreenshotHUDActions
    /// Called by the view whenever the pointer enters/leaves the card, so the controller
    /// can pause/resume the auto-dismiss timer.
    var onHoverChange: ((Bool) -> Void)?
    /// Called when the ✕ button is pressed.
    var onClose: (() -> Void)?
    /// Called after a Copy tap so the controller can auto-dismiss quickly.
    var onCopied: (() -> Void)?

    init(image: NSImage, actions: ScreenshotHUDActions) {
        self.image = image
        self.actions = actions
    }

    /// Perform the copy, flag the "✓ Copied" state, and let the controller dismiss soon.
    func performCopy() {
        actions.onCopy()
        copied = true
        onCopied?()
    }
}

// MARK: - Card view

/// A compact card: the thumbnail (aspect-fit, ~200pt wide) over a single row of small
/// action buttons. Clicking the thumbnail is treated as "Open". Hovering the card pauses
/// the controller's dismiss timer.
struct ScreenshotHUDView: View {
    @ObservedObject var model: ScreenshotHUDModel

    /// Upper bound for the thumbnail; the image is scaled to fit this box while
    /// preserving its aspect ratio, so it fills the card instead of floating small.
    private let maxThumb = CGSize(width: 288, height: 208)

    var body: some View {
        VStack(spacing: 0) {
            thumbnail
            Divider()
            actionRow
            caption
        }
        .frame(width: max(thumbnailSize.width + 20, 240))
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(closeButton, alignment: .topTrailing)
        .onHover { model.onHoverChange?($0) }
    }

    private var thumbnail: some View {
        Image(nsImage: model.image)
            .resizable()
            .interpolation(.medium)
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(10)
            .contentShape(Rectangle())
            // Clicking the thumbnail opens the full-size annotate/preview editor,
            // mirroring the macOS screenshot thumbnail → Markup behavior.
            .onTapGesture { model.actions.onAnnotate() }
            .onHover { model.hoveredLabel = $0 ? "Click to enlarge & annotate" : nil }
            .help("Click to enlarge & annotate")
            // Right-click menu mirroring Apple's native screenshot thumbnail menu.
            .contextMenu {
                Button("Save to Desktop") { model.actions.onSaveToDesktop() }
                Button("Save to Documents") { model.actions.onSaveToDocuments() }
                Button("Copy to Clipboard") { model.actions.onCopy() }
                Divider()
                Button("Open in Preview") { model.actions.onOpenInPreview() }
                Button("Show in Finder") { model.actions.onShowInFinder() }
                Divider()
                Button("Delete") { model.actions.onDelete() }
                Divider()
                Button("Markup") { model.actions.onAnnotate() }
                Button("Close") { model.actions.onClose() }
            }
    }

    /// The image scaled to fit `maxThumb` while preserving aspect ratio. Framing the
    /// image to exactly this size (rather than fitting inside a fixed landscape box)
    /// means it fills the card with no wasted letterbox space.
    private var thumbnailSize: CGSize {
        let s = model.image.size
        guard s.width > 0, s.height > 0 else {
            return CGSize(width: maxThumb.width, height: maxThumb.height * 0.62)
        }
        let scale = min(maxThumb.width / s.width, maxThumb.height / s.height)
        return CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            button("Copy", systemImage: model.copied ? "checkmark.circle.fill" : "doc.on.doc",
                   action: model.performCopy)
            button("Annotate", systemImage: "pencil.tip.crop.circle", action: model.actions.onAnnotate)
            saveToMenu
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// A pull-down menu of the user's quick-save folders. Each preset saves the current
    /// capture into that folder; "Other Folder…" falls back to the Save As… panel. Shown
    /// even with no presets (menu then holds only "Other Folder…").
    private var saveToMenu: some View {
        Menu {
            ForEach(model.actions.presets) { preset in
                Button(preset.name) { model.actions.onSaveToPreset(preset) }
            }
            if !model.actions.presets.isEmpty {
                Divider()
            }
            Button("Other Folder…", action: model.actions.onSaveAs)
        } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 15))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        // VERIFY: `.menuStyle(.borderlessButton)` (BorderlessButtonMenuStyle) — available
        // macOS 10.15+; renders the Menu as a plain icon matching the sibling buttons.
        // `.menuIndicator(.hidden)` hides the disclosure chevron (macOS 12+).
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { model.hoveredLabel = $0 ? "Save to…" : nil }
        .help("Save to…")
        .accessibilityLabel("Save to…")
    }

    /// Always-visible label: names the hovered control (icons alone aren't obvious), or
    /// when nothing is hovered, tells the user where this capture was saved.
    private var caption: some View {
        // Hovering a button → show that button's name (grey). Otherwise show the
        // "copied to clipboard" confirmation (green), so it's clear the shot is already
        // safe and dismissing loses nothing.
        let hoveringButton = (model.hoveredLabel != nil) && !model.copied
        return Text(model.copied ? "✓ Copied" : (model.hoveredLabel ?? restingCaption))
            .font(.caption2)
            .foregroundStyle(hoveringButton ? Color.secondary : Color.green)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
    }

    /// When nothing is hovered: a neutral hint for a copy-only shot, or "Kept in …"
    /// when the keep-screenshots setting stored it somewhere.
    private var restingCaption: String {
        model.actions.saveLocationName.isEmpty
            ? "✓ Copied to clipboard"
            : "✓ Copied · kept in \(model.actions.saveLocationName)"
    }

    private func button(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { model.hoveredLabel = $0 ? label : nil }
        .help(label)
        // Icon-only control: give VoiceOver a spoken label (tooltips aren't read out).
        .accessibilityLabel(label)
    }

    private var closeButton: some View {
        Button(action: { model.onClose?() }) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .buttonStyle(.plain)
        .help("Close — it's already on your clipboard")
        .accessibilityLabel("Close")
    }
}

// MARK: - Panel

/// Nonactivating floating panel that never becomes key or main, so showing the HUD
/// never steals focus from the frontmost app.
final class ScreenshotHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Owns the screenshot thumbnail HUD: a bottom-right floating card shown right after a
/// capture. Auto-dismisses after a few seconds unless the pointer is hovering it.
@MainActor
final class ScreenshotHUDController {
    private var panel: ScreenshotHUDPanel?
    private var model: ScreenshotHUDModel?

    private var dismissTimer: Timer?
    private var escapeMonitor: Any?
    private var isHovering = false
    /// Set after a Copy tap: the 2s dismiss then proceeds regardless of hover.
    private var quickDismissing = false
    private var pendingDismiss: (() -> Void)?

    private let panelSize = NSSize(width: 324, height: 300)
    private let screenMargin: CGFloat = 12

    public init() {}

    /// Shows the HUD for a fresh capture. Replaces any HUD already on screen. `actions`
    /// wires the buttons; `image` is the thumbnail and `fileURL` is the saved capture
    /// (kept only so callers can reason about it — the closures do the actual work).
    func show(image: NSImage, fileURL: URL, actions: ScreenshotHUDActions) {
        // Clean up any previous, still-showing capture's temp file before replacing it.
        firePendingDismiss()
        pendingDismiss = actions.onDismiss

        let model = existingOrNewModel(image: image, actions: actions)
        model.image = image
        model.actions = actions
        model.copied = false
        quickDismissing = false
        model.onCopied = { [weak self] in self?.scheduleQuickDismiss() }
        model.onHoverChange = { [weak self] hovering in
            // No general auto-dismiss — the thumbnail persists until Copy (2s), ✕, or Escape.
            self?.isHovering = hovering
        }
        model.onClose = { [weak self] in self?.dismiss() }

        let panel = existingOrNewPanel(model: model)
        positionBottomRight(panel)
        showWithAnimation(panel)

        installEscapeMonitor()
        isHovering = false
    }

    /// Dismisses the HUD (if visible), tearing down its timer and event monitor and
    /// firing the caller's `onDismiss`. Safe to call when nothing is showing.
    func dismiss() {
        cancelDismissTimer()
        removeEscapeMonitor()

        guard let panel, panel.isVisible else {
            firePendingDismiss()
            return
        }

        let finish: () -> Void = { [weak self] in
            panel.orderOut(nil)
            // Release the retained full-resolution bitmap. The panel and model are kept
            // alive and reused between captures, so without this the last screenshot
            // (potentially several MB) stays pinned in memory until the next capture
            // overwrites it. show() re-assigns a fresh image before the HUD reappears.
            self?.model?.image = NSImage(size: .zero)
            self?.firePendingDismiss()
        }

        // Respect Reduce Motion: skip the fade and hide instantly.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: finish)
    }

    // MARK: - Dismiss timer

    private func cancelDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    /// After a Copy tap, keep the "✓ Copied" confirmation up briefly, then dismiss —
    /// regardless of hover, since the user is done with a copy-only snippet.
    private func scheduleQuickDismiss() {
        quickDismissing = true
        cancelDismissTimer()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func firePendingDismiss() {
        let cb = pendingDismiss
        pendingDismiss = nil
        cb?()
    }

    // MARK: - Escape handling

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        // Local monitor: the panel never becomes key, so a global-ish local monitor is
        // what catches Escape while the frontmost app keeps focus.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismiss()
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    // MARK: - Panel / model construction

    private func existingOrNewModel(image: NSImage, actions: ScreenshotHUDActions) -> ScreenshotHUDModel {
        if let model { return model }
        let model = ScreenshotHUDModel(image: image, actions: actions)
        self.model = model
        return model
    }

    private func existingOrNewPanel(model: ScreenshotHUDModel) -> ScreenshotHUDPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: ScreenshotHUDView(model: model))
        let panel = ScreenshotHUDPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        self.panel = panel
        return panel
    }

    /// Places the panel flush in the bottom-right of the MAIN screen (the one with the menu
    /// bar), then re-reads the hosting view's fitting size so the card is snugly framed.
    /// We deliberately use `NSScreen.main` rather than the screen under the pointer: after a
    /// region selection the mouse can end up on any display, but the HUD should land on the
    /// primary screen every time.
    private func positionBottomRight(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            panel.center()
            return
        }

        // Let the SwiftUI content settle its intrinsic height, then size the panel to it.
        panel.layoutIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? panelSize
        let size = NSSize(width: max(fitting.width, panelSize.width),
                          height: max(fitting.height, 1))
        panel.setContentSize(size)

        let visible = screen.visibleFrame
        let x = visible.maxX - size.width - screenMargin
        let y = visible.minY + screenMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func showWithAnimation(_ panel: NSPanel) {
        // Respect Reduce Motion: show at full opacity immediately, no fade-in.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }
}
