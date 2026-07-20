import AppKit

/// App-wide hub. Owns the menu-bar controller (which in turn owns every feature
/// service) and drives the launch sequence.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSApplicationDelegate callbacks are delivered on the main thread; assert
        // main-actor isolation so we can drive the @MainActor services directly.
        MainActor.assumeIsolated {
            // Debug UI render harness (CAPTUREPLUS_RENDER=annotation) — renders a piece of UI
            // to a PNG and exits, so UI can be inspected without a human at the screen.
            if let mode = ProcessInfo.processInfo.environment["CAPTUREPLUS_RENDER"] {
                UITestHarness.run(mode)
                return
            }

            // Reconcile the stored login-item preference with the actual registration.
            AppSettings.shared.syncLoginItemState()

            // Install a standard main menu. Capture + is an accessory app so this menu
            // never shows, but its key equivalents route the standard text-editing
            // shortcuts (Cmd-A/C/V/X/Z) to whatever text field is first responder.
            MainMenu.install()

            menuBar = MenuBarController()
            menuBar.install()

            // Start polling/purge timers and register the global hotkeys.
            menuBar.startServices()

            // First-launch onboarding / permissions walkthrough.
            menuBar.showOnboardingIfNeeded()
        }
    }
}
