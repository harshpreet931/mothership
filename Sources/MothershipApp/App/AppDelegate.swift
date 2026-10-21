import AppKit
import ShipModel
import ShipProtocol
import TerminalEngine

/// Composition root.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = ProcessInfo.processInfo.environment
    private(set) var model: AppModel?
    private(set) var windowController: MainWindowController?
    private var settingsController: SettingsWindowController?
    private var router: CommandRouter?
    private var services: AppServices?

    private var isDemo: Bool { environment["MOTHERSHIP_DEMO"] == "1" }

    /// The agent engine. The lead swaps `NoopAgentEngine()` for `AgentKit.AgentEngine`.
    private func makeAgentEngine() -> any AgentEngineProtocol {
        isDemo ? DemoAgentEngine() : NoopAgentEngine()
    }

    func applicationDidFinishLaunching(_: Notification) {
        PreferenceKey.registerDefaults()
        // Debug aid for snapshots: force light or dark regardless of the system setting.
        switch environment["MOTHERSHIP_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        let defaults = UserDefaults.standard

        let runtime = TerminalRuntime.shared
        runtime.themeChoice = TerminalThemeChoice(storageValue: defaults.string(forKey: PreferenceKey.theme))
        let storedSize = defaults.double(forKey: PreferenceKey.fontSize)
        if storedSize > 0 { runtime.setFontSize(Float(storedSize)) }

        // Demo mode never touches the user's saved layout.
        let store: StateStore? = isDemo ? nil : StateStore()
        let model = AppModel(engine: makeAgentEngine(), runtime: runtime, store: store)
        model.shellEnvironment = CLIShim.shellEnvironment(shimDirectory: CLIShim.installIfNeeded())
        self.model = model
        // Socket, notifications and browser panes; must exist before panes are restored.
        let services = AppServices(model: model)
        self.services = services

        let router = CommandRouter(model: model)
        router.openSettings = { [weak self] in self?.showSettings() }
        self.router = router
        NSApp.mainMenu = MainMenu.make(router: router)

        let saved = store?.load()?.windows.first
        let windowController = MainWindowController(
            model: model, router: router, frame: saved?.frame, sidebarWidth: saved?.sidebarWidth
        )
        self.windowController = windowController

        if isDemo {
            DemoSeed.populate(model)
        } else if let saved {
            model.restore(saved)
        }
        if model.workspaces.isEmpty {
            model.createWorkspace(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        }

        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        model.start()
        services.start()
        NSApp.activate()

        if let path = environment["MOTHERSHIP_SNAPSHOT"], !path.isEmpty {
            // MOTHERSHIP_SNAPSHOT_PALETTE=1 opens ⌘K first, to check the palette too.
            if environment["MOTHERSHIP_SNAPSHOT_PALETTE"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { model.isPalettePresented = true }
            }
            DebugSnapshot.schedule(to: path, window: windowController)
        }
        // MOTHERSHIP_SNAPSHOT_SETTINGS=/path.png: open Settings (tab index in
        // MOTHERSHIP_SNAPSHOT_SETTINGS_TAB) and capture it too.
        if let path = environment["MOTHERSHIP_SNAPSHOT_SETTINGS"], !path.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showSettings()
                let tab = Int(self?.environment["MOTHERSHIP_SNAPSHOT_SETTINGS_TAB"] ?? "") ?? 0
                (self?.settingsController?.window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let window = self?.settingsController?.window else { return }
                let ok = DebugSnapshot.captureContent(of: window, to: URL(fileURLWithPath: path))
                NSLog("Mothership: settings snapshot %@", ok ? path : "failed")
            }
        }
        // MOTHERSHIP_DEBUG_INPUT="cmd": pasted + Enter into the focused pane after launch; the
        // pane's screen text is logged with the snapshot (exercises paste/sendKey/readScreen).
        if let input = environment["MOTHERSHIP_DEBUG_INPUT"], !input.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let terminal = model.focusedSurface?.terminal else { return }
                terminal.paste(text: input)
                terminal.sendKey(.enter)
            }
        }
    }

    func applicationWillTerminate(_: Notification) {
        services?.stop()
        model?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_: Notification) {
        model?.setAppActive(true)
    }

    func applicationDidResignActive(_: Notification) {
        model?.setAppActive(false)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { windowController?.showWindow(nil) }
        return true
    }

    private func showSettings() {
        guard let model else { return }
        if settingsController == nil {
            settingsController = SettingsWindowController(model: model)
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }
}

/// Seeds a believable set of workspaces for `MOTHERSHIP_DEMO=1`.
@MainActor
enum DemoSeed {
    static func populate(_ model: AppModel) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func existing(_ path: String) -> String {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : home
        }
        let (main, _) = model.createWorkspace(cwd: home, name: "mothership", focus: true, insertAfterSelection: false)
        main.colorHex = "7C8CFF"
        // Focus the right pane so the left one (Claude, waiting on a permission) glows.
        main.focusedSurfaceID = model.split(direction: .right, focus: false)?.id
        let (web, _) = model.createWorkspace(cwd: existing(home + "/Desktop"), name: "web-dashboard", focus: false, insertAfterSelection: false)
        _ = web
        let (infra, _) = model.createWorkspace(cwd: existing(home + "/Documents"), name: "infra", focus: false, insertAfterSelection: false)
        infra.colorHex = "7CC47F"
        infra.isPinned = false
        let (api, apiSurface) = model.createWorkspace(cwd: existing("/tmp"), name: "api-gateway", focus: false, insertAfterSelection: false)
        _ = api
        // Show what a restored pane looks like.
        apiSurface.resumeOffer = AgentSessionKey(kind: .claude, sessionID: "demo-restored")
        model.createWorkspace(cwd: home, name: "scratch", focus: false, insertAfterSelection: false)
        model.selectWorkspace(main.id)
    }
}
