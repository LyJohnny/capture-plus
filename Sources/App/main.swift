import AppKit

// Menu-bar-only app entry point. LSUIElement in Info.plist keeps it out of the Dock;
// .accessory here is belt-and-suspenders so it holds even if the plist is missed.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
