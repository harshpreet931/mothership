import AgentKit
import AppKit
import Intelligence
import ShipModel
import ShipProtocol
import TerminalEngine

/// Composition root.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = ProcessInfo.processInfo.environment
    private(set) var model: AppModel?
    private(set) var windowController: MainWindowController?
    private var router: CommandRouter?
    private var services: AppServices?

    private var isDemo: Bool { environment["MOTHERSHIP_DEMO"] == "1" }

    private func makeAgentEngine() -> any AgentEngineProtocol {
        if isDemo { return DemoAgentEngine() }
        // Debug: MOTHERSHIP_ENGINE=none measures the UI alone (no scanning, no sessions).
        if environment["MOTHERSHIP_ENGINE"] == "none" { return NoopAgentEngine() }
        var configuration = AgentEngineConfiguration.standard
        // A held hook hides the agent's own prompt; for a session in VS Code or iTerm that
        // reads as a frozen agent, so only hold prompts for panes Mothership hosts.
        configuration.holdPermissionsForExternalSessions = false
        // On-device titles and reply summaries (Foundation Models); without Apple Intelligence
        // the heuristics stay. MOTHERSHIP_INTELLIGENCE=off turns them off.
        if environment["MOTHERSHIP_INTELLIGENCE"] != "off" {
            let namer = SessionNamer()
            configuration.textGenerator = SessionTextGenerator(
                isAvailable: { SessionNamer.isAvailable },
                title: { digest in try await namer.title(prompts: digest.prompts, replies: digest.replies, folder: digest.folder) },
                summary: { reply, title in try await namer.summary(of: reply, title: title) }
            )
            configuration.generatedTextCache = ShipPaths.supportDirectory.appending(path: "generated-titles.json")
        }
        return AgentEngine(configuration: configuration)
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
        } else {
            // Before restoring: saved panes reattach to their live mshipd sessions.
            model.startSessionHost()
            if let saved { model.restore(saved) }
        }
        if model.workspaces.isEmpty {
            model.createWorkspace(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        }

        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        model.start()
        services.start()
        // Tasks (worktrees, diffs) and PR status. Demo mode and MOTHERSHIP_GH=none keep gh off.
        if isDemo || environment["MOTHERSHIP_GH"] == "none" { GitServices.configure(github: nil) }
        if !isDemo {
            model.startTaskServices()
            model.startPullRequestStatus()
            // QA (scratch homes): a scripted task run, see DebugTaskScript.
            if let script = environment["MOTHERSHIP_DEBUG_TASK"] { model.runDebugTaskScript(script) }
        }
        NSApp.activate()

        if isDemo {
            model.portsProvider = { DemoAgentEngine.demoPorts }
            model.plannedIntegrationChange = { kind in DemoAgentEngine.plannedContents(kind) }
        } else {
            // MOTHERSHIP_PORTS_ROOT_PID (debug): scan another process tree, to verify ports
            // where this build's own shells can't open sockets.
            let scanner = PortScanner(rootPID: environment["MOTHERSHIP_PORTS_ROOT_PID"].flatMap(Int32.init) ?? getpid())
            model.portsProvider = { await scanner.scan() }
            // Panes descend from mshipd as well as the app: ports and the engine's pane scans
            // walk both trees, and follow the daemon's pid when it changes.
            model.onPaneHostPIDsChanged = { [weak model] pids in
                Task { await scanner.setRoots(pids) }
                #if false  // AgentEngine.setPaneHostPIDs lands with the engine branch; connected at merge.
                if let engine = model?.engine as? AgentEngine { Task { await engine.setPaneHostPIDs(pids) } }
                #endif
                _ = model
            }
            model.onPaneHostPIDsChanged?(model.paneHostPIDs)
            if let engine = model.engine as? AgentEngine {
                model.plannedIntegrationChange = { kind in (try? await engine.plannedIntegrationContents(kind)) ?? nil }
            }
        }
        // Debug aids for verifying UI (see DebugSnapshot): MOTHERSHIP_SKY picks a sky without
        // saving it; MOTHERSHIP_SNAPSHOT_VIEW opens home | fleet | palette | settings[:tab].
        if let sky = environment["MOTHERSHIP_SKY"].flatMap(SkyPreset.init(rawValue:)) {
            model.persistsSky = false
            model.skyPreset = sky
        }
        // MOTHERSHIP_SKY_TIME=HH:MM pins the sky's time of day.
        if let time = environment["MOTHERSHIP_SKY_TIME"] { model.skyClock.pinTime(time) }
        model.skyClock.start()
        if let path = environment["MOTHERSHIP_SNAPSHOT"], !path.isEmpty {
            DebugSnapshot.prepareView(environment["MOTHERSHIP_SNAPSHOT_VIEW"], model: model, root: windowController.root)
            let delay = environment["MOTHERSHIP_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 2.4
            DebugSnapshot.schedule(to: path, after: delay, window: windowController)
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

    /// Asks first while agents or commands are running (AppModel.confirmQuit).
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        model?.confirmQuit() == false ? .terminateCancel : .terminateNow
    }

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

    /// Settings is a page in the main window (Sky: Hark's Accounts pattern).
    private func showSettings() {
        model?.openSettings()
        windowController?.window?.makeKeyAndOrderFront(nil)
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
        let (infra, _) = model.createWorkspace(cwd: existing(home + "/Documents"), name: "infra", focus: false, insertAfterSelection: false)
        infra.colorHex = "7CC47F"
        infra.isPinned = false
        let (api, apiSurface) = model.createWorkspace(cwd: existing("/tmp"), name: "api-gateway", focus: false, insertAfterSelection: false)
        // Show what a restored pane looks like.
        apiSurface.resumeOffer = AgentSessionKey(kind: .claude, sessionID: "demo-restored")
        // Tasks (Best-of-3 in flight, Best-of-2 with one kept), their runs' workspaces, PRs.
        DemoTasks.seed(
            model, home: home, existing: existing,
            named: ["mothership": main.id, "web-dashboard": web.id, "infra": infra.id, "api-gateway": api.id]
        )
        model.createWorkspace(cwd: home, name: "scratch", focus: false, insertAfterSelection: false)
        model.selectWorkspace(main.id)
    }
}
