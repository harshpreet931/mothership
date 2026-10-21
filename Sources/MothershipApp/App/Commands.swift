import AppKit
import ShipModel
import ShipProtocol

/// Every user-facing command. The main menu and the command palette are both built from
/// this list so titles and shortcuts never drift apart.
enum AppCommand: String, CaseIterable {
    case newWorkspace, openFolder, renameWorkspace, closeWorkspace
    case splitRight, splitDown, openBrowser, closePane, zoomPane, equalizeSplits
    case focusLeft, focusRight, focusUp, focusDown
    case nextWorkspace, previousWorkspace, jumpToAttention
    case home, fleet, toggleComposer
    case toggleSidebar, commandPalette, settings
    case increaseFontSize, decreaseFontSize, resetFontSize
    case clearScreen
    case quitAndEndSessions

    var title: String {
        switch self {
        case .newWorkspace: "New Workspace"
        case .openFolder: "Open Folder…"
        case .renameWorkspace: "Rename Workspace…"
        case .closeWorkspace: "Close Workspace"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .openBrowser: "Open Browser Split"
        case .closePane: "Close Pane"
        case .zoomPane: "Zoom Pane"
        case .equalizeSplits: "Equalize Splits"
        case .focusLeft: "Focus Pane Left"
        case .focusRight: "Focus Pane Right"
        case .focusUp: "Focus Pane Above"
        case .focusDown: "Focus Pane Below"
        case .nextWorkspace: "Next Workspace"
        case .previousWorkspace: "Previous Workspace"
        case .jumpToAttention: "Jump to Agent Needing Attention"
        case .home: "Home"
        case .fleet: "Fleet"
        case .toggleComposer: "Toggle Composer"
        case .toggleSidebar: "Toggle Sidebar"
        case .commandPalette: "Command Palette…"
        case .settings: "Settings…"
        case .increaseFontSize: "Increase Font Size"
        case .decreaseFontSize: "Decrease Font Size"
        case .resetFontSize: "Reset Font Size"
        case .clearScreen: "Clear Screen"
        case .quitAndEndSessions: "Quit and End All Sessions"
        }
    }

    var symbol: String {
        switch self {
        case .newWorkspace: "plus.rectangle.on.rectangle"
        case .openFolder: "folder"
        case .renameWorkspace: "pencil"
        case .closeWorkspace: "xmark.rectangle"
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .openBrowser: "safari"
        case .closePane: "xmark"
        case .zoomPane: "arrow.up.left.and.arrow.down.right"
        case .equalizeSplits: "equal.square"
        case .focusLeft: "arrow.left.square"
        case .focusRight: "arrow.right.square"
        case .focusUp: "arrow.up.square"
        case .focusDown: "arrow.down.square"
        case .nextWorkspace: "chevron.down"
        case .previousWorkspace: "chevron.up"
        case .jumpToAttention: "bell.badge"
        case .home: "house"
        case .fleet: "square.grid.2x2"
        case .toggleComposer: "text.bubble"
        case .toggleSidebar: "sidebar.left"
        case .commandPalette: "command"
        case .settings: "gearshape"
        case .increaseFontSize: "textformat.size.larger"
        case .decreaseFontSize: "textformat.size.smaller"
        case .resetFontSize: "textformat.size"
        case .clearScreen: "clear"
        case .quitAndEndSessions: "power"
        }
    }

    /// (key equivalent, modifiers) for the menu.
    var keyEquivalent: (String, NSEvent.ModifierFlags)? {
        switch self {
        case .newWorkspace: ("t", .command)
        case .openFolder: ("o", .command)
        case .renameWorkspace: nil
        case .closeWorkspace: ("w", [.command, .shift])
        case .splitRight: ("d", .command)
        case .splitDown: ("d", [.command, .shift])
        case .openBrowser: ("b", [.command, .shift])
        case .closePane: ("w", .command)
        case .zoomPane: ("\r", [.command, .shift])
        case .equalizeSplits: ("=", [.command, .control])
        case .focusLeft: (Self.arrow(NSLeftArrowFunctionKey), [.command, .option])
        case .focusRight: (Self.arrow(NSRightArrowFunctionKey), [.command, .option])
        case .focusUp: (Self.arrow(NSUpArrowFunctionKey), [.command, .option])
        case .focusDown: (Self.arrow(NSDownArrowFunctionKey), [.command, .option])
        case .nextWorkspace: ("]", [.command, .shift])
        case .previousWorkspace: ("[", [.command, .shift])
        case .jumpToAttention: ("u", [.command, .shift])
        case .home: ("0", .command)
        case .fleet: ("f", [.command, .shift])
        case .toggleComposer: ("l", .command)
        case .toggleSidebar: ("b", .command)
        case .commandPalette: ("k", .command)
        case .settings: (",", .command)
        case .increaseFontSize: ("+", .command)
        case .decreaseFontSize: ("-", .command)
        case .resetFontSize: ("0", [.command, .control])
        case .clearScreen: ("k", [.command, .option])
        case .quitAndEndSessions: ("q", [.command, .option])
        }
    }

    /// Shortcut as shown in the palette.
    var shortcutLabel: String? {
        switch self {
        case .zoomPane: return "⌘⇧↩"
        case .focusLeft: return "⌘⌥←"
        case .focusRight: return "⌘⌥→"
        case .focusUp: return "⌘⌥↑"
        case .focusDown: return "⌘⌥↓"
        default: break
        }
        guard let (key, modifiers) = keyEquivalent else { return nil }
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        return label + key.uppercased()
    }

    private static func arrow(_ key: Int) -> String {
        String(utf16CodeUnits: [unichar(key)], count: 1)
    }
}

/// Executes commands against the model and window. Target of every menu item.
@MainActor
final class CommandRouter: NSObject, NSMenuItemValidation {
    let model: AppModel
    weak var windowController: MainWindowController?
    /// Delegates of dynamic menus (NSMenu holds them weakly).
    var retainedMenuDelegates: [NSObject] = []
    var openSettings: () -> Void = {}

    init(model: AppModel) {
        self.model = model
    }

    @objc func performCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let raw = item.representedObject as? String,
              let command = AppCommand(rawValue: raw) else { return }
        perform(command)
    }

    /// The standard About panel with the Arch M icon (rendered when running unbundled).
    @objc func showAbout(_: Any?) {
        let bundledIcon = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Mothership",
            .applicationVersion: ShipInfo.version,
            .credits: NSAttributedString(
                string: "Mission control for your agents.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ]
        if let icon = bundledIcon ? NSApp.applicationIconImage : AppIconTile.image(size: 256) {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    /// File → New Workspace In → a recent project.
    @objc func newWorkspaceInProject(_ sender: Any?) {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String else { return }
        model.noteProjectUsed(path)
        model.createWorkspace(cwd: path)
    }

    @objc func selectWorkspaceByTag(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        model.selectWorkspace(at: item.tag)
    }

    func perform(_ command: AppCommand) {
        switch command {
        case .newWorkspace: model.createWorkspace()
        case .openFolder: model.openFolderAsWorkspace()
        case .renameWorkspace:
            if let id = model.selectedWorkspace?.id {
                if windowController?.isSidebarCollapsed == true { windowController?.toggleSidebar() }
                model.renamingWorkspaceID = id
            }
        case .closeWorkspace: model.selectedWorkspace.map { model.closeWorkspace($0.id) }
        case .splitRight: model.split(direction: .right)
        case .splitDown: model.split(direction: .down)
        case .openBrowser: model.openBrowserSplit()
        case .closePane: model.closeFocusedPane()
        case .zoomPane: model.toggleZoom()
        case .equalizeSplits: model.equalizeSplits()
        case .focusLeft: model.moveFocus(.left)
        case .focusRight: model.moveFocus(.right)
        case .focusUp: model.moveFocus(.up)
        case .focusDown: model.moveFocus(.down)
        case .nextWorkspace: model.selectAdjacentWorkspace(1)
        case .previousWorkspace: model.selectAdjacentWorkspace(-1)
        case .jumpToAttention: model.jumpToAttention()
        case .home: model.toggleHome()
        case .fleet: model.show(model.screen == .fleet ? .workspaces : .fleet)
        case .toggleComposer:
            if model.isComposerExpanded { model.closeComposer() } else { model.openComposer() }
        case .toggleSidebar: windowController?.toggleSidebar()
        case .commandPalette: model.isPalettePresented.toggle()
        case .settings: openSettings()
        case .increaseFontSize: model.runtime.adjustFontSize(by: 1)
        case .decreaseFontSize: model.runtime.adjustFontSize(by: -1)
        case .resetFontSize: model.runtime.resetFontSize()
        case .clearScreen:
            guard model.screen == .workspaces, !model.isPalettePresented else { return }
            model.focusedSurface?.terminal?.clearScreen()
        case .quitAndEndSessions:
            model.quitAndEndAllSessions()
        }
        if [.increaseFontSize, .decreaseFontSize, .resetFontSize].contains(command) {
            UserDefaults.standard.set(model.runtime.hasFontSizeOverride ? Double(model.runtime.fontSize) : 0, forKey: PreferenceKey.fontSize)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectWorkspaceByTag(_:)) {
            return model.workspaces.indices.contains(item.tag)
        }
        guard let raw = item.representedObject as? String, let command = AppCommand(rawValue: raw) else { return true }
        let workspace = model.selectedWorkspace
        switch command {
        case .renameWorkspace, .closeWorkspace, .splitRight, .splitDown, .openBrowser, .closePane, .jumpToAttention:
            return workspace != nil || command == .jumpToAttention
        case .zoomPane:
            item.state = workspace?.zoomedSurfaceID != nil ? .on : .off
            return (workspace?.layout.surfaceIDs.count ?? 0) > 1 || workspace?.zoomedSurfaceID != nil
        case .equalizeSplits, .focusLeft, .focusRight, .focusUp, .focusDown:
            return (workspace?.layout.surfaceIDs.count ?? 0) > 1
        case .nextWorkspace, .previousWorkspace:
            return model.workspaces.count > 1
        case .toggleSidebar:
            item.title = windowController?.isSidebarCollapsed == true ? "Show Sidebar" : "Hide Sidebar"
            return true
        case .home:
            item.state = model.screen == .home ? .on : .off
            return true
        case .fleet:
            item.state = model.screen == .fleet ? .on : .off
            return true
        case .toggleComposer:
            item.title = model.isComposerExpanded ? "Close Composer" : "Open Composer"
            return true
        case .clearScreen:
            // Only the pane you can see, and never from under the palette.
            return model.screen == .workspaces && !model.isPalettePresented && model.focusedSurface?.terminal != nil
        default:
            return true
        }
    }

    /// Commands offered in the palette.
    func paletteItems() -> [PaletteItem] {
        let hidden: Set<AppCommand> = [.commandPalette]
        return AppCommand.allCases.filter { !hidden.contains($0) }.map { command in
            PaletteItem(
                id: "command:\(command.rawValue)", section: .actions, title: command.title.replacingOccurrences(of: "…", with: ""),
                icon: .symbol(command.symbol), shortcut: command.shortcutLabel,
                perform: { [weak self] in self?.perform(command) }
            )
        }
    }
}
