//
//  RecordingTargetPicker.swift
//  Capture + — Feature 3: Screen recording
//
//  Window chooser. Given a list of shareable `SCWindow`s (gathered by the
//  integrator), presents a titled window with a scrollable SwiftUI list so the
//  user can pick one specific window to record. Display selection and the
//  "all displays" option live in the menu-bar menu; this module is only the
//  window picker.
//
//  SCWindow property names below were verified against the macOS 26.5 SDK
//  headers (ScreenCaptureKit.framework: SCShareableContent.h):
//  `SCWindow.title` (String?), `SCWindow.owningApplication`
//  (SCRunningApplication?), `SCRunningApplication.applicationName`,
//  `SCRunningApplication.processID`.
//

import AppKit
import SwiftUI
import ScreenCaptureKit

// MARK: - Row model

/// A flattened, display-ready view of one `SCWindow`.
private struct WindowRow: Identifiable {
    let id: CGWindowID
    let window: SCWindow
    let appName: String
    let title: String
    let icon: NSImage?

    init(_ window: SCWindow) {
        self.id = window.windowID
        self.window = window
        self.appName = window.owningApplication?.applicationName ?? "Unknown App"
        let raw = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = raw.isEmpty ? "Untitled" : raw
        // App icon from the owning process, if it's still running.
        if let pid = window.owningApplication?.processID,
           let running = NSRunningApplication(processIdentifier: pid) {
            self.icon = running.icon
        } else {
            self.icon = nil
        }
    }
}

// MARK: - View model

@MainActor
private final class WindowPickerModel: ObservableObject {
    @Published var rows: [WindowRow] = []
    @Published var selection: Int = 0

    /// Called with the chosen window's row on commit, or `nil` on cancel.
    var onPick: ((SCWindow?) -> Void)?

    func pickSelected() {
        guard rows.indices.contains(selection) else { onPick?(nil); return }
        onPick?(rows[selection].window)
    }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = max(0, min(rows.count - 1, selection + delta))
    }
}

// MARK: - List view

/// A SwiftUI list of capturable windows. Click a row (or press Return on the
/// highlighted row) to pick; arrow keys move the selection; Escape cancels.
private struct WindowPickerView: View {
    @ObservedObject var model: WindowPickerModel
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.rows.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 420, height: 460)
        .focusable()
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.return) { model.pickSelected(); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private var header: some View {
        HStack {
            Text("Choose a Window to Record")
                .font(.headline)
            Spacer()
            Text("\(model.rows.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "macwindow")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No windows available")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        self.row(row, index: index)
                            .id(index)
                            .onTapGesture {
                                model.selection = index
                                model.onPick?(row.window)
                            }
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

    private func row(_ row: WindowRow, index: Int) -> some View {
        let selected = index == model.selection
        return HStack(spacing: 10) {
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "macwindow")
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.appName)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(row.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Record") { model.pickSelected() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.rows.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Controller

/// Presents a modal-ish window that lets the user pick one `SCWindow` to record.
///
/// Usage:
/// ```
/// let picker = RecordingTargetPickerController()
/// picker.pickWindow(windows) { chosen in
///     guard let chosen else { return } // nil == cancelled
///     // start recording that window…
/// }
/// ```
///
/// The controller retains itself for the lifetime of the window, so callers can
/// create it inline without holding a reference.
@MainActor
final class RecordingTargetPickerController: NSWindowController {

    // MARK: - Live-instance retention
    // pickWindow() is typically called on a freshly created controller the
    // caller doesn't otherwise retain; keep ourselves alive until the pick
    // resolves.
    private static var liveControllers: Set<RecordingTargetPickerController> = []

    private let model = WindowPickerModel()
    private var onPick: ((SCWindow?) -> Void)?
    private var didFinish = false

    // MARK: - Init
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Record Window"
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

    /// Present the window chooser for `windows`. Calls `onPick` exactly once
    /// with the chosen `SCWindow`, or `nil` if the user cancelled / closed the
    /// window. Rows are sorted by owning-application name, then window title.
    func pickWindow(_ windows: [SCWindow], onPick: @escaping (SCWindow?) -> Void) {
        self.onPick = onPick
        self.didFinish = false

        RecordingTargetPickerController.liveControllers.insert(self)

        let rows = windows
            .map(WindowRow.init)
            .sorted {
                if $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
        model.rows = rows
        model.selection = 0
        model.onPick = { [weak self] window in self?.finish(with: window) }

        guard let window = self.window else {
            finish(with: nil)
            return
        }

        let hosting = NSHostingView(
            rootView: WindowPickerView(model: model, onCancel: { [weak self] in self?.finish(with: nil) })
        )
        window.contentView = hosting

        // Accessory/menu-bar app: bring this window forward so it's usable.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Teardown

    /// Deliver the result exactly once, then close and release.
    private func finish(with window: SCWindow?) {
        guard !didFinish else { return }
        didFinish = true

        let onPick = self.onPick
        self.onPick = nil

        onPick?(window)

        self.window?.orderOut(nil)
        RecordingTargetPickerController.liveControllers.remove(self)
    }
}

// MARK: - NSWindowDelegate

extension RecordingTargetPickerController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Closing via the red button counts as a cancel if we haven't finished.
        if !didFinish {
            finish(with: nil)
        }
    }
}
