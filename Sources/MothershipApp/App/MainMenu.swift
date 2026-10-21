import AppKit

/// Programmatic main menu. Mothership's own items target the `CommandRouter`; standard
/// items (Edit, Window) go through the responder chain so the terminal handles copy/paste.
@MainActor
enum MainMenu {
    static func make(router: CommandRouter) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(router: router)))
        main.addItem(submenu(fileMenu(router: router), title: "File"))
        main.addItem(submenu(editMenu(), title: "Edit"))
        main.addItem(submenu(viewMenu(router: router), title: "View"))
        main.addItem(submenu(paneMenu(router: router), title: "Pane"))
        let window = windowMenu(router: router)
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        main.addItem(submenu(help, title: "Help"))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? menu.title, action: nil, keyEquivalent: "")
        if let title { menu.title = title }
        item.submenu = menu
        return item
    }

    private static func command(_ command: AppCommand, router: CommandRouter, hidden: Bool = false, key: String? = nil, modifiers: NSEvent.ModifierFlags? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: #selector(CommandRouter.performCommand(_:)), keyEquivalent: "")
        item.target = router
        item.representedObject = command.rawValue
        if let (defaultKey, defaultModifiers) = command.keyEquivalent {
            item.keyEquivalent = key ?? defaultKey
            item.keyEquivalentModifierMask = modifiers ?? defaultModifiers
        }
        if hidden {
            // Alternate trigger for the same command (e.g. ⌘= alongside ⌘+).
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        return item
    }

    private static func appMenu(router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: "Mothership")
        let about = menu.addItem(withTitle: "About Mothership", action: #selector(CommandRouter.showAbout(_:)), keyEquivalent: "")
        about.target = router
        menu.addItem(.separator())
        menu.addItem(command(.settings, router: router))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Mothership", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Mothership", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu(router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(command(.newWorkspace, router: router))
        menu.addItem(command(.openBrowser, router: router))
        menu.addItem(.separator())
        menu.addItem(command(.splitRight, router: router))
        menu.addItem(command(.splitDown, router: router))
        menu.addItem(.separator())
        menu.addItem(command(.closePane, router: router))
        menu.addItem(command(.closeWorkspace, router: router))
        menu.addItem(.separator())
        menu.addItem(command(.renameWorkspace, router: router))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func viewMenu(router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(command(.home, router: router))
        menu.addItem(command(.fleet, router: router))
        menu.addItem(.separator())
        menu.addItem(command(.commandPalette, router: router))
        menu.addItem(command(.commandPalette, router: router, hidden: true, key: "p", modifiers: [.command, .shift]))
        menu.addItem(command(.toggleSidebar, router: router))
        menu.addItem(command(.toggleComposer, router: router))
        menu.addItem(.separator())
        menu.addItem(command(.increaseFontSize, router: router))
        menu.addItem(command(.increaseFontSize, router: router, hidden: true, key: "="))
        menu.addItem(command(.decreaseFontSize, router: router))
        menu.addItem(command(.resetFontSize, router: router))
        menu.addItem(.separator())
        menu.addItem(command(.clearScreen, router: router))
        menu.addItem(.separator())
        let fullScreen = menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    private static func paneMenu(router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: "Pane")
        menu.addItem(command(.zoomPane, router: router))
        menu.addItem(command(.equalizeSplits, router: router))
        menu.addItem(.separator())
        menu.addItem(command(.focusLeft, router: router))
        menu.addItem(command(.focusRight, router: router))
        menu.addItem(command(.focusUp, router: router))
        menu.addItem(command(.focusDown, router: router))
        menu.addItem(.separator())
        menu.addItem(command(.jumpToAttention, router: router))
        return menu
    }

    private static func windowMenu(router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(command(.previousWorkspace, router: router))
        menu.addItem(command(.previousWorkspace, router: router, hidden: true, key: "{", modifiers: .command))
        menu.addItem(command(.nextWorkspace, router: router))
        menu.addItem(command(.nextWorkspace, router: router, hidden: true, key: "}", modifiers: .command))
        menu.addItem(.separator())
        for index in 0 ..< 9 {
            let item = NSMenuItem(title: "Workspace \(index + 1)", action: #selector(CommandRouter.selectWorkspaceByTag(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = .command
            item.target = router
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }
}
