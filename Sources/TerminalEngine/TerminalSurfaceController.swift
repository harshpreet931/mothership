import AppKit
import Foundation
import GhosttyTerminal
import ShipModel

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

    private let terminalView: MothershipTerminalView
    private let bridge: DelegateBridge
    private var attachedSurface: TerminalSurface?
    private var scrollbar: TerminalScrollbar?
    private var pendingInput: [PendingInput] = []
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
    public init(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID,
        workingDirectory: String?,
        command: String? = nil,
        initialInput: String? = nil,
        environment: [String: String] = [:],
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
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: Self.existingDirectory(workingDirectory),
            envVars: env,
            command: command,
            context: .split
        )
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
        guard attachedSurface != nil, isReady else {
            pendingInput.append(.paste(text))
            return true
        }
        return terminalView.paste(text: text)
    }

    /// Presses a key. Queued with pastes until `isReady`, so "paste, then Enter" stays in order.
    @discardableResult
    public func sendKey(_ key: TerminalKeyInput) -> Bool {
        guard attachedSurface != nil, isReady else {
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

    /// Kills the shell and frees the surface. The view stays usable as an empty pane.
    public func terminate() {
        terminalView.controller = nil
        attachedSurface = nil
        isRunning = false
    }

    // MARK: Delegate plumbing

    fileprivate func surfaceAttached(_ surface: TerminalSurface) {
        attachedSurface = surface
        isRunning = true
        hasExited = false
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
        guard attachedSurface != nil, isReady else { return }
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
