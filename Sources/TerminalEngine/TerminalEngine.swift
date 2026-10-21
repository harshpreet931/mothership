import ShipModel

// TerminalEngine wraps libghostty-spm's `GhosttyTerminal` behind a small API so the app
// never touches Ghostty types directly:
//
// - `TerminalRuntime`: the one shared `TerminalController` (config, theme, font size).
// - `TerminalSurfaceController`: one pane's terminal (view, PTY, signals, input, screen text).
// - `TerminalThemeChoice`: what Settings stores for the color theme.

/// Keys the app can press programmatically. Text goes through `paste(text:)` instead.
public enum TerminalKeyInput: Sendable, Equatable {
    case enter
    case escape
    case tab
    case backspace
    /// Ctrl+C.
    case interrupt
    case up, down, left, right, space

    /// `mship send --key` names: enter, escape, tab, backspace, ctrl-c, up, down, left, right, space.
    public init?(name: String) {
        switch name.lowercased() {
        case "enter", "return": self = .enter
        case "escape", "esc": self = .escape
        case "tab": self = .tab
        case "backspace": self = .backspace
        case "ctrl-c", "interrupt": self = .interrupt
        case "up": self = .up
        case "down": self = .down
        case "left": self = .left
        case "right": self = .right
        case "space": self = .space
        default: return nil
        }
    }
}
