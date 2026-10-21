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
}
