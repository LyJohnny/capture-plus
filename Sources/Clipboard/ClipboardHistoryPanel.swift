import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Filter

/// Which kinds of clipboard items the list shows.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", text = "Text", images = "Images"
    var id: String { rawValue }
}

// MARK: - View model

/// Backing store for the history view: the current items, selection, filter, and the
/// callbacks the controller wires up.
@MainActor
final class ClipboardHistoryModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var filter: HistoryFilter = .all
    @Published var selection: Int = 0
    /// True briefly after a pick, to show the "✓ Copied to clipboard" confirmation before
    /// the panel auto-dismisses.
    @Published var copiedBanner = false

    /// Called when the user commits a pick (click, or Return on a selection).
    var onPick: ((ClipItem) -> Void)?
    /// Called when the panel should dismiss without a pick (Escape).
    var onDismiss: (() -> Void)?
    /// Called to delete a single item (trash button, or Delete on a selection).
    var onDelete: ((ClipItem) -> Void)?
    /// Called to clear the entire history ("Clear All").
    var onClearAll: (() -> Void)?

    /// Items after applying the current filter — what the list actually shows.
    var filteredItems: [ClipItem] {
        switch filter {
        case .all: return items
        case .text: return items.filter { if case .text = $0.kind { return true }; return false }
        case .images: return items.filter { $0.isImage }
        }
    }

    func pickSelected() {
        let shown = filteredItems
        guard shown.indices.contains(selection) else { return }
        onPick?(shown[selection])
    }

    func moveSelection(_ delta: Int) {
        let shown = filteredItems
        guard !shown.isEmpty else { return }
        selection = max(0, min(shown.count - 1, selection + delta))
    }

    func deleteSelected() {
        let shown = filteredItems
        guard shown.indices.contains(selection) else { return }
        onDelete?(shown[selection])
    }
}

// MARK: - List view

/// A SwiftUI list of clipboard items, newest first. Click a row (or press Return on
/// the highlighted row) to pick; arrow keys move the selection; Escape dismisses.
struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardHistoryModel

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider()
            if model.filteredItems.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 320, minHeight: 300)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottom) { copiedBannerView }
        // Key handling lives on the whole view so it works before any row is focused.
        .focusable()
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.return) { model.pickSelected(); return .handled }
        .onKeyPress(.escape) { model.onDismiss?(); return .handled }
        .onKeyPress(.delete) { model.deleteSelected(); return .handled }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Clipboard History")
                .font(.headline)
            Spacer()
            Text("\(model.filteredItems.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if !model.items.isEmpty {
                Button { model.onClearAll?() } label: {
                    Text("Clear All").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove all clipboard history")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 30)   // leave room for the window's traffic-light buttons
        .padding(.bottom, 4)
    }

    /// Transient "✓ Copied to clipboard" banner shown when the user picks an item, before
    /// the panel auto-dismisses.
    @ViewBuilder private var copiedBannerView: some View {
        if model.copiedBanner {
            Text("✓ Copied to clipboard")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.green))
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 22)   // bottom toast, so it never covers list items
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var filterBar: some View {
        Picker("", selection: $model.filter) {
            ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: model.filter) { _, _ in model.selection = 0 }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clipboard")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Nothing here yet")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index)
                            .id(index)
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { _, newValue in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    /// A leading thumbnail: the actual image for image items, else a type glyph.
    private func thumb(_ item: ClipItem, selected: Bool) -> some View {
        Group {
            if let img = item.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: item.glyphName)
                    .frame(width: 46, height: 34)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
            }
        }
    }

    private func row(_ item: ClipItem, index: Int) -> some View {
        let selected = index == model.selection
        return HStack(spacing: 10) {
            // Content area — tapping it copies. Kept SEPARATE from the trash button so a
            // delete never also fires a copy (which was re-adding the item you deleted).
            HStack(spacing: 10) {
                thumb(item, selected: selected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                    if let dim = item.dimensionsText {
                        Text(dim)
                            .font(.caption2)
                            .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(Self.relativeFormatter.localizedString(for: item.date, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.onPick?(item) }

            Button { model.onDelete?(item) } label: {
                Image(systemName: "trash")
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        // Drag an item out of the panel into another app (Finder, Mail, chat, …).
        .onDrag { Self.itemProvider(for: item) }
        // Right-click actions (also make it discoverable that clicking copies).
        .contextMenu {
            Button {
                model.onPick?(item)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if item.isImage {
                Button {
                    Self.openInPreview(item)
                } label: {
                    Label("Open in Preview", systemImage: "eye")
                }
            }
            Divider()
            Button(role: .destructive) {
                model.onDelete?(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Drag & context-menu helpers

    /// Builds an `NSItemProvider` that drops the item's payload in a form the target app
    /// understands: an image for image items, a string for text, a file URL for files.
    private static func itemProvider(for item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .image(let png, _):
            // Drop as an image; also register the raw PNG bytes so file targets get a .png.
            let provider = NSImage(data: png).map { NSItemProvider(object: $0) } ?? NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.png.identifier,
                visibility: .all
            ) { completion in
                completion(png, nil)
                return nil
            }
            return provider
        case .text(let string):
            return NSItemProvider(object: string as NSString)
        case .file(let urls):
            if let first = urls.first {
                return NSItemProvider(contentsOf: first) ?? NSItemProvider(object: first as NSURL)
            }
            return NSItemProvider()
        }
    }

    /// Writes an image item's PNG to a temp file and opens it in the default image
    /// viewer (Preview). No-op for non-image items.
    private static func openInPreview(_ item: ClipItem) {
        guard case .image(let png, _) = item.kind else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        do {
            try png.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: - Panel

/// Nonactivating floating panel that can still become key (so it receives arrow /
/// Return / Escape key events) without stealing focus from the frontmost app.
final class ClipboardHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Owns the history panel and toggles it near the menu-bar corner.
@MainActor
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    private var panel: ClipboardHistoryPanel?
    private let model = ClipboardHistoryModel()
    private var escapeMonitor: Any?
    /// Live subscription to the manager's history while the panel is open.
    private var itemsCancellable: AnyCancellable?
    /// Pending auto-dismiss after a pick, so the "Copied" banner shows for ~2s first.
    private var autoCloseWork: DispatchWorkItem?

    override init() { super.init() }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Called when the window's red close button (or any close) fires — clean up.
    func windowWillClose(_ notification: Notification) { close() }

    /// Shows the panel (bound live to `manager`) if hidden, or hides it if already
    /// visible. While open, the list re-renders on every history change — a new copy or a
    /// screenshot ingest appears at the top immediately. `onPick` fires when the user
    /// chooses an item; the panel then closes.
    func toggle(manager: ClipboardManager, onPick: @escaping (ClipItem) -> Void) {
        if isVisible {
            close()
            return
        }
        show(manager: manager, onPick: onPick)
    }

    func show(manager: ClipboardManager, onPick: @escaping (ClipItem) -> Void) {
        model.items = manager.items
        model.selection = 0

        // Re-render live: mirror the manager's published history into the view model and
        // keep the selection in range as items are inserted/removed underneath it.
        itemsCancellable = manager.$items.sink { [weak self] newItems in
            guard let self else { return }
            self.model.items = newItems
            if newItems.isEmpty {
                self.model.selection = 0
            } else {
                self.model.selection = max(0, min(newItems.count - 1, self.model.selection))
            }
        }

        model.copiedBanner = false
        autoCloseWork?.cancel()
        model.onPick = { [weak self] item in
            guard let self else { return }
            onPick(item)                    // copies the picked item to the pasteboard
            // Show a "✓ Copied to clipboard" confirmation, keep the panel up ~2s, then
            // auto-dismiss — so it's clear the click actually copied it.
            withAnimation(.easeOut(duration: 0.15)) { self.model.copiedBanner = true }
            self.scheduleAutoClose(after: 2.0)
        }
        model.onDismiss = { [weak self] in self?.close() }
        model.onDelete = { item in manager.delete(id: item.id) }
        model.onClearAll = { manager.clear() }

        let panel = existingOrNewPanel()
        positionNearMenuBar(panel)
        panel.makeKeyAndOrderFront(nil)

        // Backstop Escape handling in case SwiftUI key handling isn't focused yet.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.close()
                return nil
            }
            return event
        }
    }

    func close() {
        autoCloseWork?.cancel()
        autoCloseWork = nil
        itemsCancellable = nil
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        model.copiedBanner = false
        panel?.orderOut(nil)
    }

    /// Dismiss the panel after `seconds` (used to keep the "Copied" banner up briefly).
    private func scheduleAutoClose(after seconds: TimeInterval) {
        autoCloseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        autoCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Panel construction

    private func existingOrNewPanel() -> ClipboardHistoryPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: ClipboardHistoryView(model: model))
        let panel = ClipboardHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
            // Standard window controls: close (red), minimize, zoom/resize (green).
            styleMask: [.nonactivatingPanel, .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false        // red close just hides; the panel is reused
        panel.delegate = self                     // so the red close routes through our cleanup
        panel.contentMinSize = NSSize(width: 320, height: 300)
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.panel = panel
        return panel
    }

    /// Places the panel just below the menu bar in the top-right of the main screen,
    /// falling back to screen-center if geometry is unavailable.
    private func positionNearMenuBar(_ panel: NSPanel) {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 8
        let x = visible.maxX - size.width - margin
        let y = visible.maxY - size.height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
