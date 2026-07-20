import AppKit
import SwiftUI

/// Debug-only UI render harness. Activated by the `CAPTUREPLUS_RENDER` env var; never runs in
/// normal use. It builds a piece of UI, renders it to a PNG (via `cacheDisplay`, which
/// needs no Screen Recording permission), and exits — so UI changes can be inspected
/// without a human at the screen.
///
/// Usage: `CAPTUREPLUS_RENDER=annotation /Applications/Capture +.app/Contents/MacOS/Capture +`
@MainActor
enum UITestHarness {
    static func run(_ mode: String) {
        switch mode {
        case "annotation": renderAnnotation()
        case "texttest": runTextCommitTest()
        case "closetest": runCloseConfirmTest()
        case "cliptest": runClipboardTest()
        case "cliprender": renderClipboard()
        default:
            NSApp.terminate(nil)
        }
    }

    private static func runClipboardTest() {
        var result = ClipboardManager().debugSelfTest() + "\n"
        // Classification on a NON-general test pasteboard, so it can't clobber the clipboard.
        let testPB = NSPasteboard(name: NSPasteboard.Name("com.joh.captureplus.test"))
        result += ClipboardManager(pasteboard: testPB).debugClassifyTest() + "\n"
        try? result.write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func renderClipboard() {
        let model = ClipboardHistoryModel()
        var items: [ClipItem] = []
        if let shot = ClipItem.image(from: testImage()) { items.append(shot) }
        items.append(ClipItem(kind: .text("Some copied text — hello world")))
        model.items = items
        model.copiedBanner = true   // show the "Copied" banner for the render
        let hosting = NSHostingView(rootView: ClipboardHistoryView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            writePNG(hosting, to: "/tmp/captureplus-clipboard.png")
            exit(0)
        }
    }

    /// Verifies that clicking the annotation window's red close button (simulated via
    /// performClose) shows a confirmation sheet, even with NO annotations drawn — the
    /// exact scenario the user hit (just previewing, then closing).
    private static func runCloseConfirmTest() {
        let c = AnnotationWindowController()
        c.present(image: testImage(), suggestedName: "Test", defaultSaveDirectory: nil,
                  onCopy: { _ in }, onSave: { _, _ in }, onDelete: {})
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            c.window?.performClose(nil)   // simulate the red close button
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let hasSheet = (c.window?.attachedSheet != nil)
                // Write to a file (stdout buffers) and hard-exit (an attached sheet blocks
                // NSApp.terminate, which is itself a hint the sheet is up).
                let result = "closeShowsConfirmation=\(hasSheet ? "PASS" : "FAIL")\n"
                try? result.write(toFile: "/tmp/captureplus-selftest.txt", atomically: true, encoding: .utf8)
                if let sheet = c.window?.attachedSheet, let content = sheet.contentView {
                    writePNG(content, to: "/tmp/captureplus-closesheet.png")
                    c.window?.endSheet(sheet)
                }
                exit(0)
            }
        }
    }

    private static func runTextCommitTest() {
        let controller = AnnotationWindowController()
        controller.present(image: testImage(), suggestedName: "Test",
                           defaultSaveDirectory: nil,
                           onCopy: { _ in }, onSave: { _, _ in }, onDelete: {})
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            print("SELFTEST: \(controller.debugTextCommitSelfTest())")
            NSApp.terminate(nil)
        }
    }

    private static func renderAnnotation() {
        let controller = AnnotationWindowController()
        controller.present(image: testImage(), suggestedName: "Test",
                           defaultSaveDirectory: nil,
                           onCopy: { _ in }, onSave: { _, _ in }, onDelete: {})
        controller.debugPopulateShapes()   // drop one of each shape to verify geometry

        // Let AppKit lay out the toolbar + canvas, then snapshot the window content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if let content = controller.window?.contentView {
                writePNG(content, to: "/tmp/captureplus-annotation.png")
            }
            NSApp.terminate(nil)
        }
    }

    private static func testImage() -> NSImage {
        let size = NSSize(width: 1000, height: 640)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            .font: NSFont.systemFont(ofSize: 34),
            .paragraphStyle: para,
        ]
        "annotation test canvas".draw(in: NSRect(x: 0, y: size.height / 2 - 24, width: size.width, height: 48),
                                      withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    private static func writePNG(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
