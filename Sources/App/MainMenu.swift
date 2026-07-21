import AppKit

/// Builds and installs the app's main menu.
///
/// Capture + is an accessory (`LSUIElement`) app, so this menu never appears in the
/// system menu bar — but its **key equivalents** are what make the standard
/// text-editing shortcuts (Cmd-A/C/X/V/Z, etc.) work inside any focused text
/// field (annotation text box, settings fields). Without a main menu, AppKit has
/// nowhere to route those command-key events, so they're simply dropped.
///
/// Every editing item is left with `target = nil` so the action routes down the
/// responder chain to whatever text view is first responder.
enum MainMenu {

    /// Tag on the application-menu "Settings…" item. The menu-bar owner locates the
    /// item by this tag after launch to point it at the settings window — MainMenu is
    /// static and built before the controller that opens Settings exists, so the item
    /// is left target-less here.
    static let settingsMenuItemTag = 7_710

    /// Installs a freshly built standard menu as `NSApp.mainMenu` and points
    /// `NSApp.windowsMenu` at the Window submenu. Called once at launch.
    static func install() {
        let menu = build()
        NSApp.mainMenu = menu
    }

    /// Constructs a standard main menu: Application, Edit, and Window submenus.
    /// Wires `NSApp.windowsMenu` as a side effect so AppKit manages the window list.
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Capture +"

        mainMenu.addItem(applicationMenuItem(appName: appName))
        mainMenu.addItem(editMenuItem())

        let windowItem = windowMenuItem()
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowItem.submenu

        return mainMenu
    }

    // MARK: - Application menu

    private static func applicationMenuItem(appName: String) -> NSMenuItem {
        let container = NSMenuItem()
        let menu = NSMenu(title: appName)

        menu.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(settingsItem())
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), key: "q"))

        container.submenu = menu
        return container
    }

    /// The standard "Settings…" item (⌘,). Unlike the editing items this needs a real
    /// target, but MainMenu is built before the settings-window owner exists — so it's
    /// left target-less and wired up post-launch by tag (`settingsMenuItemTag`). The
    /// key equivalent lives here (in `NSApp.mainMenu`) so ⌘, opens Settings from any
    /// focused Capture + window.
    private static func settingsItem() -> NSMenuItem {
        let mi = item("Settings…", Selector(("openSettingsMenu:")), key: ",")
        mi.tag = settingsMenuItemTag
        return mi
    }

    // MARK: - Edit menu

    /// The standard editing items, all wired to first-responder selectors so they
    /// act on whatever text view currently has focus.
    private static func editMenuItem() -> NSMenuItem {
        let container = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(item("Undo", Selector(("undo:")), key: "z"))
        menu.addItem(item("Redo", Selector(("redo:")), key: "Z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))

        container.submenu = menu
        return container
    }

    // MARK: - Window menu

    private static func windowMenuItem() -> NSMenuItem {
        let container = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))

        container.submenu = menu
        return container
    }

    // MARK: - Item builder

    /// Builds a menu item whose action routes through the responder chain
    /// (`target == nil`), with an optional key equivalent and modifier mask.
    private static func item(_ title: String,
                             _ action: Selector,
                             key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        mi.target = nil
        return mi
    }
}
