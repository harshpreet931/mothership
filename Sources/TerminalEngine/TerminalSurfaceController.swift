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

    private let terminalView: MothershipTerminalView
    private let bridge: DelegateBridge
    private var attachedSurface: TerminalSurface?
    private var scrollbar: TerminalScrollbar?
    private var pendingInput: [PendingInput] = []
    private var initialInputArmed = false
    private var visible = true

    private enum PendingInput {
        case paste(String)
        case key(TerminalKeyInput)
    }

    /// - Parameters:
    ///   - workingDirectory: Where the shell starts; nil for Ghostty's default (home).
    ///   - command: Replaces the login shell entirely. Prefer `initialInput` to run something
    ///     inside the shell so the pane survives the command exiting.
    ///   - initialInput: Typed into the shell once its first prompt is up, then Enter.
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
            initialInputArmed = true
        }
    }

    /// The NSView to place in the pane. Owned by this controller.
    public var view: NSView { terminalView }

    // MARK: Input

    /// Bracketed paste (not keystrokes). Queued until the shell is up.
    @discardableResult
    public func paste(text: String) -> Bool {
        guard attachedSurface != nil, !initialInputArmed else {
            pendingInput.append(.paste(text))
            return true
        }
        return terminalView.paste(text: text)
    }

    @discardableResult
    public func sendKey(_ key: TerminalKeyInput) -> Bool {
        guard attachedSurface != nil, !initialInputArmed else {
            pendingInput.append(.key(key))
            return true
        }
        return press(key)
    }

    /// Runs a Ghostty binding action on this surface (e.g. `"clear_screen"`).
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
        if initialInputArmed {
            // Give the shell a moment to print its first prompt if OSC 7 never arrives
            // (no shell integration, e.g. fish without the plugin).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.releaseInitialInput()
            }
        } else {
            flushPendingInput()
        }
    }

    fileprivate func surfaceDetached() {
        attachedSurface = nil
        isRunning = false
    }

    fileprivate func emit(_ signal: TerminalSignal) {
        switch signal {
        case .title(let value): title = value
        case .workingDirectory(let value):
            workingDirectory = value
            // The shell's first OSC 7 means its prompt is ready for input.
            releaseInitialInput()
        case .processExited: hasExited = true
        default: break
        }
        onSignal?(signal)
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

    private func releaseInitialInput() {
        guard initialInputArmed, attachedSurface != nil else { return }
        initialInputArmed = false
        flushPendingInput()
    }

    private func flushPendingInput() {
        guard attachedSurface != nil else { return }
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
