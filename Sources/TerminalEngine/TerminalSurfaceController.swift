import AppKit
import Foundation
import GhosttyTerminal
import SessionHost
import ShipModel
import Synchronization

/// One terminal pane: a libghostty surface running the user's shell (or `command`) in a
/// PTY, plus everything the app needs from it. The surface is created lazily the first
/// time the view is in a window with a non-zero size, and torn down by `terminate()` or
/// when this controller is released.
@MainActor
public final class TerminalSurfaceController {
    public let surfaceID: SurfaceID
    public let workspaceID: WorkspaceID

    /// Every OSC/terminal event the agent engine cares about.
    public var onSignal: ((TerminalSignal) -> Void)?
    /// Keyboard focus moved into (true) or out of (false) this terminal.
    public var onFocusChange: ((Bool) -> Void)?
    /// The surface closed: the shell exited (`processAlive == false`) or Ghostty asked to close.
    public var onClose: ((_ processAlive: Bool) -> Void)?
    /// A ⌘-clicked link. Return true when handled; otherwise it opens in the default browser.
    public var onOpenURL: ((URL) -> Bool)?

    public private(set) var title: String?
    public private(set) var workingDirectory: String?
    public private(set) var isRunning = false
    public private(set) var hasExited = false

    /// True once the program in the pane can take input: the shell drew its first real
    /// prompt (its first OSC 7 / OSC 2, from precmd, settled for `readinessSettle`), or
    /// `readinessFallback` passed since the surface attached. Until then `paste` and `sendKey`
    /// queue. A shell still loading its rc files (an "instant prompt" may already be on screen
    /// with bracketed paste on) would otherwise have the tty echo the input, markers and all.
    public private(set) var isReady = false

    /// Quiet time after the first prompt signal before input flows (the precmd burst of
    /// OSC 133;A / 7 / 2 and the prompt itself land together; libghostty doesn't surface 133;A).
    public static var readinessSettle: Duration = .milliseconds(120)
    /// Readiness when no prompt signal ever comes (no shell integration, a program that
    /// sets no title).
    public static var readinessFallback: Duration = .seconds(4)

    /// `mshipd` owns this pane's PTY: the session outlives the app and reattaches on relaunch.
    public var isPersistent: Bool { persistent != nil }
    /// The session's process (the shell or startup command) once known.
    public private(set) var processID: Int32?
    /// The session opened: `reattached` is false when it had to be (re)started, true when an
    /// existing one (from before a quit or crash) was picked up with its screen.
    public var onSessionOpened: ((_ reattached: Bool) -> Void)?
    /// The connection to `mshipd` dropped; the owner reconnects and calls `reconnect(to:)`.
    public var onHostDisconnected: (() -> Void)?

    private let terminalView: MothershipTerminalView
    private let bridge: DelegateBridge
    private var attachedSurface: TerminalSurface?
    private var scrollbar: TerminalScrollbar?
    private var pendingInput: [PendingInput] = []
    private var persistent: PersistentState?

    private struct PersistentState {
        let link: PersistentLink
        let session: InMemoryTerminalSession
        let spec: SpawnSpec
        let allowsReattach: Bool
        var phase: Phase = .idle
        var closeReported = false
    }

    private enum Phase { case idle, opening, open, ended }
    private var readyWaiters: [@MainActor () -> Void] = []
    private var readinessTimer: Task<Void, Never>?
    private var fallbackTimer: Task<Void, Never>?
    private var visible = true

    private enum PendingInput {
        case paste(String)
        case key(TerminalKeyInput)
    }

    /// - Parameters:
    ///   - workingDirectory: Where the shell starts; nil for Ghostty's default (home).
    ///   - command: Replaces the login shell entirely (a shell command line). To run something
    ///     and keep a shell afterwards, pass a wrapper such as `ShellLaunch.command(shell:)`.
    ///   - initialInput: Typed into the shell once it is ready (see `isReady`), then Enter.
    ///     Only for shells that can't take a `command` wrapper; typing races rc files.
    ///   - environment: Extra variables; the Mothership surface/workspace/socket variables
    ///     are always added.
    ///   - sessionHost: When set, `mshipd` owns the PTY (session id = `surfaceID`) and this
    ///     surface renders it through libghostty's in-memory backend; otherwise Ghostty spawns
    ///     the shell itself (`.exec`), which dies with the app.
    ///   - reattach: Pick up a live session with this id (restoring a saved layout) instead of
    ///     always starting one.
    public init(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID,
        workingDirectory: String?,
        command: String? = nil,
        initialInput: String? = nil,
        environment: [String: String] = [:],
        sessionHost: SessionHostClient? = nil,
        reattach: Bool = false,
        runtime: TerminalRuntime = .shared
    ) {
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
        terminalView = MothershipTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        bridge = DelegateBridge()
        bridge.owner = self
        terminalView.delegate = bridge

        var env = environment
        env.merge(ShipEnvironment.variables(surface: surfaceID, workspace: workspaceID)) { _, ship in ship }
        if let sessionHost {
            let link = PersistentLink(host: sessionHost, session: surfaceID.rawValue)
            let session = InMemoryTerminalSession(
                write: { [link] data in link.forwardInput(data) },
                resize: { [link] viewport in link.viewportChanged(viewport) }
            )
            let spec = PersistentShell.spec(command: command, workingDirectory: workingDirectory, environment: env)
            persistent = PersistentState(link: link, session: session, spec: spec, allowsReattach: reattach)
            terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session), context: .split)
        } else {
            terminalView.configuration = TerminalSurfaceOptions(
                backend: .exec,
                workingDirectory: Self.existingDirectory(workingDirectory),
                envVars: env,
                command: command,
                context: .split
            )
        }
        terminalView.controller = runtime.controller
        if let initialInput, !initialInput.isEmpty {
            pendingInput = [.paste(initialInput), .key(.enter)]
        }
    }

    /// The NSView to place in the pane. Owned by this controller.
    public var view: NSView { terminalView }

    // MARK: Readiness

    /// Runs `body` once the pane is ready for programmatic input (right away if it is).
    public func whenReady(_ body: @escaping @MainActor () -> Void) {
        if isReady { body() } else { readyWaiters.append(body) }
    }

    /// Suspends until the pane is ready for programmatic input.
    public func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            whenReady { continuation.resume() }
        }
    }

    // MARK: Input

    /// Pastes text (Ghostty frames it as a bracketed paste when the program asked for that;
    /// never add the markers yourself). Queued until `isReady`, then sent in order.
    @discardableResult
    public func paste(text: String) -> Bool {
        guard attachedSurface != nil, isReady, persistentAcceptsInput else {
            pendingInput.append(.paste(text))
            return true
        }
        return terminalView.paste(text: text)
    }

    /// Presses a key. Queued with pastes until `isReady`, so "paste, then Enter" stays in order.
    @discardableResult
    public func sendKey(_ key: TerminalKeyInput) -> Bool {
        guard attachedSurface != nil, isReady, persistentAcceptsInput else {
            pendingInput.append(.key(key))
            return true
        }
        return press(key)
    }

    /// Clears the screen and the scrollback (Ghostty's `clear_screen`). At a shell prompt the
    /// shell is asked to redraw it; full-screen programs (alternate screen) are left alone.
    @discardableResult
    public func clearScreen() -> Bool {
        terminalView.performBindingAction("clear_screen")
    }

    /// Runs a Ghostty binding action on this surface (e.g. `"scroll_to_top"`).
    @discardableResult
    public func performAction(_ action: String) -> Bool {
        terminalView.performBindingAction(action)
    }

    // MARK: Focus & visibility

    @discardableResult
    public func focus() -> Bool {
        terminalView.acquireProgrammaticFocus()
    }

    public var isFocused: Bool {
        terminalView.window?.firstResponder === terminalView
    }

    /// Hidden surfaces keep running (PTY, parser, scrollback) but stop rendering.
    public func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        terminalView.setSurfaceVisible(visible)
    }

    public var isVisible: Bool { visible }

    // MARK: Reading

    /// Text currently on screen, plus `scrollbackLines` rows above it. Nil before the
    /// surface exists.
    public func readScreenText(scrollbackLines: Int = 0) -> String? {
        guard let attachedSurface else { return nil }
        return TerminalScreenReader.readText(
            surface: attachedSurface, scrollbackLines: max(0, scrollbackLines), scrollbar: scrollbar
        )
    }

    public var selectedText: String? {
        attachedSurface?.readSelection()
    }

    /// The last presented frame (Metal content included), or a `cacheDisplay` fallback.
    public func snapshotImage() -> NSImage? {
        TerminalScreenReader.snapshot(of: terminalView) ?? terminalView.snapshotImage()
    }

    // MARK: Lifecycle

    /// Ends the pane's process (closing a pane or workspace) and frees the surface. The view
    /// stays usable as an empty pane.
    public func terminate() {
        if let persistent {
            persistent.link.host?.closeSession(surfaceID.rawValue)
            self.persistent?.phase = .ended
        }
        terminalView.controller = nil
        attachedSurface = nil
        isRunning = false
    }

    /// Lets go of a persistent session without ending it (the app is quitting): `mshipd`
    /// keeps the process running and buffering, and the next launch reattaches. Same as
    /// `terminate()` for the exec backend, whose shell can't outlive the app.
    public func detach() {
        guard let persistent else { return terminate() }
        persistent.link.host?.detach(surfaceID.rawValue)
        self.persistent?.phase = .ended
        terminalView.controller = nil
        attachedSurface = nil
        isRunning = false
    }

    /// After `mshipd` was restarted (it crashed or was killed): attach again. The old session
    /// died with the old host, so this starts a fresh shell under the existing screen.
    public func reconnect(to host: SessionHostClient) {
        guard let persistent, persistent.phase != .ended else { return }
        persistent.link.setHost(host)
        self.persistent?.phase = .idle
        if attachedSurface != nil { openSession() }
    }

    // MARK: Persistent sessions

    /// Opens the daemon session once the surface exists (replay into a live surface, never
    /// into libghostty's pre-attach buffer) and its first grid size has had a moment to land.
    private func scheduleOpen() {
        guard persistent?.phase == .idle else { return }
        persistent?.phase = .opening
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.openSession() }
        }
    }

    private func openSession() {
        guard let persistent, let host = persistent.link.host, persistent.phase != .ended, persistent.phase != .open else { return }
        self.persistent?.phase = .opening
        let link = persistent.link
        let session = persistent.session
        let owner = WeakController(self)
        link.beginReplay()
        host.setHandler(for: surfaceID.rawValue) { event in
            switch event {
            case .output(let offset, let data):
                session.receive(data)
                link.received(through: offset + UInt64(data.count))
            case .replayEnd(let suffix):
                if !suffix.isEmpty { session.receive(suffix) }
                DispatchQueue.main.async { MainActor.assumeIsolated { owner.controller?.replayFinished() } }
            case .exited(let exited):
                DispatchQueue.main.async { MainActor.assumeIsolated { owner.controller?.sessionExited(exited) } }
            case .disconnected:
                DispatchQueue.main.async { MainActor.assumeIsolated { owner.controller?.hostDisconnected() } }
            }
        }
        let size = link.viewport
        let spec = persistent.spec
        let attach = persistent.allowsReattach || link.receivedOffset > 0
        let from = link.receivedOffset
        let id = surfaceID.rawValue
        Task { @MainActor [weak self] in
            do {
                let opened = try await host.open(
                    session: id, attachIfExists: attach, spawn: spec, columns: size.columns, rows: size.rows, fromOffset: from
                )
                self?.sessionOpened(opened)
            } catch {
                self?.sessionOpenFailed(error)
            }
        }
    }

    private func sessionOpened(_ opened: OpenedMessage) {
        guard let persistent, persistent.phase == .opening else { return }
        self.persistent?.phase = .open
        processID = opened.pid
        persistent.link.markOpen()
        onSessionOpened?(!opened.created)
        flushPendingInput()
    }

    /// Exec panes always take input; persistent ones once the session is open and its replay
    /// has been parsed (the open reply and the replay's end reach the main actor separately).
    private var persistentAcceptsInput: Bool {
        guard let persistent else { return true }
        return persistent.phase == .open && !persistent.link.isReplaying
    }

    private func sessionOpenFailed(_ error: any Error) {
        guard let persistent else { return }
        self.persistent?.phase = .ended
        persistent.link.endReplay()
        persistent.session.receive("\r\n\u{1B}[2m[Mothership couldn't start this session: \(error)]\u{1B}[0m\r\n")
    }

    /// The replay is in; once the terminal has parsed it (and any answers it wrote back to old
    /// queries are dropped), input flows.
    private func replayFinished() {
        guard let persistent else { return }
        guard attachedSurface != nil, persistent.session.waitForPendingOutput() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.replayFinished() }
            }
            return
        }
        persistent.link.endReplay()
        flushPendingInput()
    }

    private func sessionExited(_ exited: ExitedMessage) {
        guard let persistent, persistent.phase != .ended else { return }
        self.persistent?.phase = .ended
        persistent.session.finish(exitCode: UInt32(bitPattern: exited.exitCode), runtimeMilliseconds: 0)
        // libghostty reports the exit through its close delegate; make sure the pane hears it once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.persistent?.closeReported == false else { return }
                self.closed(processAlive: false)
            }
        }
    }

    private func hostDisconnected() {
        guard persistent?.phase != .ended else { return }
        persistent?.phase = .idle
        persistent?.link.setHost(nil)
        onHostDisconnected?()
    }

    // MARK: Delegate plumbing

    fileprivate func surfaceAttached(_ surface: TerminalSurface) {
        attachedSurface = surface
        isRunning = true
        hasExited = false
        if persistent != nil { scheduleOpen() }
        if isReady {
            flushPendingInput()
        } else if fallbackTimer == nil {
            fallbackTimer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.readinessFallback)
                guard !Task.isCancelled else { return }
                self?.becomeReady()
            }
        }
    }

    fileprivate func surfaceDetached() {
        attachedSurface = nil
        isRunning = false
    }

    fileprivate func emit(_ signal: TerminalSignal) {
        // Replayed output re-runs old bells, notifications and progress reports; only state
        // (title, cwd) is worth taking from it.
        if persistent?.link.isReplaying == true {
            switch signal {
            case .bell, .desktopNotification, .progress, .commandFinished: return
            default: break
            }
        }
        switch signal {
        case .title(let value):
            title = value
            promptSignal()
        case .workingDirectory(let value):
            workingDirectory = value
            promptSignal()
        case .processExited: hasExited = true
        default: break
        }
        onSignal?(signal)
    }

    /// OSC 7 and OSC 2 come from the shell's precmd (after its rc files ran) or from a program
    /// that started and set its title: either way something is now reading input. Settle
    /// briefly from the first one so the rest of the burst (the prompt itself) lands first.
    /// Not restarted by later signals: agents animate their titles several times a second.
    private func promptSignal() {
        guard !isReady, attachedSurface != nil, readinessTimer == nil else { return }
        readinessTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.readinessSettle)
            guard !Task.isCancelled else { return }
            self?.becomeReady()
        }
    }

    private func becomeReady() {
        guard !isReady, attachedSurface != nil else { return }
        isReady = true
        readinessTimer?.cancel()
        fallbackTimer?.cancel()
        readinessTimer = nil
        fallbackTimer = nil
        flushPendingInput()
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter() }
    }

    fileprivate func focusChanged(_ focused: Bool) {
        onFocusChange?(focused)
    }

    fileprivate func closed(processAlive: Bool) {
        if persistent != nil {
            guard persistent?.closeReported == false else { return }
            persistent?.closeReported = true
        }
        if !processAlive {
            emit(.processExited)
        }
        isRunning = false
        onClose?(processAlive)
    }

    fileprivate func openURL(_ string: String) {
        guard let url = URL(string: string) ?? URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { return }
        if onOpenURL?(url) == true { return }
        NSWorkspace.shared.open(url)
    }

    fileprivate func scrollbarChanged(_ value: TerminalScrollbar) {
        scrollbar = value
    }

    private func flushPendingInput() {
        guard attachedSurface != nil, isReady, persistentAcceptsInput else { return }
        let queued = pendingInput
        pendingInput.removeAll()
        for item in queued {
            switch item {
            case .paste(let text): terminalView.paste(text: text)
            case .key(let key): press(key)
            }
        }
    }

    @discardableResult
    private func press(_ key: TerminalKeyInput) -> Bool {
        switch key {
        case .enter: terminalView.sendKey(.enter)
        case .escape: terminalView.sendKey(.escape)
        case .tab: terminalView.sendKey(.tab)
        case .backspace: terminalView.sendKey(.backspace)
        case .interrupt: terminalView.sendKey(.c, modifiers: .ctrl)
        case .up: terminalView.sendKey(.arrowUp)
        case .down: terminalView.sendKey(.arrowDown)
        case .left: terminalView.sendKey(.arrowLeft)
        case .right: terminalView.sendKey(.arrowRight)
        case .space: terminalView.sendKey(.space)
        }
    }

    private static func existingDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return expanded
    }
}

/// Lets the app's main menu claim its key equivalents (⌘T, ⌘D, ⌘K, ⌘1…) before
/// Ghostty's default keybinds see them; everything else goes to the terminal as usual.
final class MothershipTerminalView: AppTerminalView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command),
           let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Ghostty holds its delegate weakly and casts it to each optional protocol; this object
/// adopts all the ones we forward, without exposing GhosttyTerminal protocols on the
/// public controller.
@MainActor
private final class DelegateBridge:
    TerminalSurfaceTitleDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfaceProgressReportDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceScrollbarDelegate,
    TerminalSurfaceOpenURLDelegate
{
    weak var owner: TerminalSurfaceController?

    func terminalDidChangeTitle(_ title: String) {
        owner?.emit(.title(title))
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        let resolved = path.hasPrefix("file://") ? (URL(string: path)?.path ?? path) : path
        owner?.emit(.workingDirectory(resolved))
    }

    func terminalDidRingBell() {
        owner?.emit(.bell)
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        owner?.emit(.desktopNotification(title: title, body: body))
    }

    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        let name = switch state {
        case .remove: "remove"
        case .set: "set"
        case .error: "error"
        case .indeterminate: "indeterminate"
        case .pause: "pause"
        }
        owner?.emit(.progress(state: name, percent: percent))
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        owner?.emit(.commandFinished(exitCode: exitCode, durationNanos: durationNanos))
    }

    func terminalDidClose(processAlive: Bool) {
        owner?.closed(processAlive: processAlive)
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        owner?.focusChanged(focused)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        owner?.surfaceAttached(surface)
    }

    func terminalDidDetachSurface() {
        owner?.surfaceDetached()
    }

    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        owner?.scrollbarChanged(scrollbar)
    }

    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        owner?.openURL(url)
    }
}


/// What the Ghostty I/O-thread closures (input, resize) and the session-event handler need,
/// shared without touching the main-actor controller: the current host (swappable on
/// reconnect), whether replay is in progress, the last grid size, and how much output we have.
final class PersistentLink: Sendable {
    private struct State {
        var host: SessionHostClient?
        var replaying = true
        var open = false
        var viewport = (columns: UInt16(80), rows: UInt16(24), width: UInt32(0), height: UInt32(0))
        var receivedOffset: UInt64 = 0
    }

    let session: UUID
    private let state: Mutex<State>

    init(host: SessionHostClient, session: UUID) {
        self.session = session
        state = Mutex(State(host: host))
    }

    var host: SessionHostClient? { state.withLock { $0.host } }
    var isReplaying: Bool { state.withLock { $0.replaying } }
    var receivedOffset: UInt64 { state.withLock { $0.receivedOffset } }
    var viewport: (columns: UInt16, rows: UInt16) { state.withLock { ($0.viewport.columns, $0.viewport.rows) } }

    func setHost(_ host: SessionHostClient?) {
        state.withLock { state in
            state.host = host
            state.open = false
        }
    }

    func beginReplay() { state.withLock { $0.replaying = true } }
    func endReplay() { state.withLock { $0.replaying = false } }

    func markOpen() {
        let (host, size) = state.withLock { state in
            state.open = true
            return (state.host, state.viewport)
        }
        // The grid may have changed while the open was in flight.
        host?.resize(session, columns: size.columns, rows: size.rows, widthPixels: size.width, heightPixels: size.height)
    }

    func received(through offset: UInt64) {
        state.withLock { $0.receivedOffset = max($0.receivedOffset, offset) }
    }

    /// Keystrokes and the terminal's replies. Dropped during replay: they'd be the terminal
    /// answering queries (DA, DSR…) found in old output, injected as input into the shell.
    func forwardInput(_ data: Data) {
        let host = state.withLock { $0.replaying || !$0.open ? nil : $0.host }
        host?.input(data, to: session)
    }

    func viewportChanged(_ viewport: InMemoryTerminalViewport) {
        let host = state.withLock { state -> SessionHostClient? in
            state.viewport = (viewport.columns, viewport.rows, viewport.widthPixels, viewport.heightPixels)
            return state.open ? state.host : nil
        }
        host?.resize(session, columns: viewport.columns, rows: viewport.rows, widthPixels: viewport.widthPixels, heightPixels: viewport.heightPixels)
    }
}

/// A weak reference the session-event handler can carry to the main actor.
final class WeakController: @unchecked Sendable {
    // @unchecked: `controller` is only read on the main actor (the handler hops there first).
    weak var controller: TerminalSurfaceController?
    @MainActor init(_ controller: TerminalSurfaceController) { self.controller = controller }
}
