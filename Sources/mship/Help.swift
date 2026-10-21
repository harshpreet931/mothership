import ShipModel

enum Help {
    private typealias Row = (command: String, arguments: String, summary: String)

    private static let sections: [(title: String, rows: [Row], note: String?)] = [
        ("PANES & WORKSPACES", [
            ("split", "[-- COMMAND…]", "Open a terminal pane beside this one (--down, --cwd DIR, --focus)"),
            ("split", "--browser URL", "Open a browser pane beside this one"),
            ("new", "[-- COMMAND…]", "Create a workspace tab (--name NAME, --cwd DIR, --background)"),
            ("focus", "SURFACE", "Bring a pane to the front"),
            ("close", "[SURFACE]", "Close a pane, ending its shell or agent"),
            ("send", "TEXT|-", "Paste text into a pane (--surface ID, --submit; - reads stdin)"),
            ("screen", "", "Print a pane's visible text (--surface ID, --lines N)"),
        ], nil),
        ("BROWSER", [
            ("open", "URL", "Open URL in this workspace's browser pane (--split, --new-workspace)"),
            ("browser snapshot", "", "Page outline with element refs like [ref=e12]"),
            ("browser click", "REF", "Click by ref or CSS selector"),
            ("browser fill", "REF TEXT", "Set a field the way a user would, React-safe (--submit)"),
            ("browser eval", "JS|-", "Run JavaScript and print the result as JSON"),
            ("browser console", "", "Console output, exceptions, failed requests (--errors, --json)"),
            ("browser screenshot", "", "Save a PNG of the pane and print its path"),
        ], "Browser commands act on this workspace's browser pane; --browser ID picks another."),
        ("AGENTS & ATTENTION", [
            ("status", "", "Every agent session: workspace, state, cwd, summary (--json)"),
            ("approve", "[ID]", "Allow the permission request an agent is waiting on"),
            ("deny", "[ID]", "Deny it (--reason tells the agent why)"),
            ("notify", "TITLE [BODY]", "A notification that opens this pane when clicked"),
            ("hook", "AGENT EVENT [JSON]", "Forward an agent hook event (what agent configs run)"),
            ("mcp", "", "MCP server giving agents Mothership's tools (stdio)"),
        ], nil),
        ("OTHER", [
            ("ping", "[-q]", "Check that Mothership is running"),
            ("version", "", "Print the version"),
            ("help", "[COMMAND]", "Options and examples for one command"),
        ], nil),
    ]

    static func overview(_ style: Style) -> String {
        let width = sections.flatMap(\.rows).map { $0.command.count + ($0.arguments.isEmpty ? 0 : $0.arguments.count + 1) }.max() ?? 20
        var text = style.bold("mship") + " " + style.dim("— drive Mothership from your shell, scripts, hooks and agents") + "\n\n"
        text += style.bold("USAGE") + "\n  mship <command> [options]\n"
        for section in sections {
            text += "\n" + style.bold(section.title) + "\n"
            for row in section.rows {
                let plain = row.command + (row.arguments.isEmpty ? "" : " " + row.arguments)
                let shown = style.cyan(row.command) + (row.arguments.isEmpty ? "" : " " + row.arguments)
                text += "  " + shown + String(repeating: " ", count: width - plain.count + 3) + row.summary + "\n"
            }
            if let note = section.note { text += "  " + style.dim(note) + "\n" }
        }
        text += """

            \(style.bold("EXAMPLES"))
              mship split --down -- npm run dev
              mship open localhost:3000
              mship new --name auth-fix --cwd ~/src/api -- claude "fix the failing auth tests"
              long-job && mship notify "Deploy finished" "api is live on staging"
              claude mcp add mothership -- mship mcp

            \(style.bold("ENVIRONMENT"))
              MOTHERSHIP_SOCKET          Control socket (set in every Mothership shell)
              MOTHERSHIP_SURFACE_ID      This pane: the default target of most commands
              MOTHERSHIP_WORKSPACE_ID    This workspace: the default scope of agents' MCP tools
              MOTHERSHIP_DEBUG=1         Explain why a hook exited silently
              NO_COLOR                   Disable colors

            \(style.bold("EXIT STATUS"))
              0 ok · 1 Mothership reported an error · 2 usage error · 3 Mothership isn't running
              \(style.dim("`mship hook` exits 0 whenever anything goes wrong, so it never blocks an agent."))

            """
        return text
    }

    static let commands: [String: String] = [
        "split": """
            usage: mship split [--right|--down|--left|--up] [--cwd DIR] [--focus] [--surface ID] [-- COMMAND…]
                   mship split --browser URL [--right|--down|…]

            Opens a new pane next to this one (or next to --surface) and prints its surface id.
            With a COMMAND after --, the new shell runs it and stays open afterwards. A single
            argument is taken as a shell string ("npm run dev && open ."); several are quoted.
            The new pane starts in this directory unless --cwd says otherwise.

              mship split --down -- npm run dev
              mship split -- claude "write tests for src/auth.ts"
              mship split --browser localhost:5173
            """,
        "new": """
            usage: mship new [--name NAME] [--cwd DIR] [--background] [-- COMMAND…]

            Creates a workspace (vertical tab) and prints its first pane's surface id.
            --background keeps you where you are.

              mship new --name review --cwd ~/src/api.worktrees/review -- codex "review this branch"
            """,
        "close": """
            usage: mship close [SURFACE]

            Closes a pane (this one by default), as its close button does: its shell or agent ends,
            even when sessions are kept running across quits.
            """,
        "focus": """
            usage: mship focus SURFACE

            Selects the pane's workspace and gives the pane keyboard focus.
            """,
        "send": """
            usage: mship send [--surface ID] [--submit] TEXT…
                   mship send [--surface ID] [--submit] -        (reads TEXT from stdin)
                   mship send [--surface ID] --key down --key enter   (press keys, for TUIs)

            Pastes TEXT into a pane (bracketed paste, so newlines don't run commands one by one).
            --submit presses Enter afterwards. Defaults to this pane.
            """,
        "screen": """
            usage: mship screen [--surface ID] [--lines N]

            Prints the text visible in a pane (this one by default), with N lines of scrollback above.
            """,
        "open": """
            usage: mship open URL [--split|--new-workspace]

            Opens URL in this workspace's browser pane, splitting one open if there is none.
            --split always opens a new pane; --new-workspace opens it in a new tab.
            Bare hosts work: localhost:3000, 127.0.0.1:8080/admin.
            """,
        "browser": """
            usage: mship browser snapshot
                   mship browser click REF
                   mship browser fill REF TEXT [--submit]
                   mship browser eval JS|-
                   mship browser console [--errors] [--json]
                   mship browser screenshot
                   (each takes --browser ID; default: this workspace's browser pane)

            snapshot prints an outline of the page where every interactive element has a ref,
            e.g. `- button "Sign in" [ref=e12]`. click and fill accept such a ref or a CSS selector.
            eval accepts an expression (document.title) or a body with `return`; await works.
            """,
        "status": """
            usage: mship status [--json]

            Lists every agent session Mothership knows about, including ones running outside it
            (VS Code, iTerm, tmux): workspace, agent, state, directory and summary. Sessions that
            need you come first.
            """,
        "approve": """
            usage: mship approve [ID] [--surface ID]

            Allows a permission request an agent is waiting on (Claude Code and Codex hooks,
            the OpenCode plugin). With no ID it answers the request in this pane, or the only
            one waiting. `mship status` shows what's waiting.
            """,
        "deny": """
            usage: mship deny [ID] [--surface ID] [--reason TEXT]

            Denies a permission request. --reason is passed to the agent so it can adjust.
            """,
        "notify": """
            usage: mship notify TITLE [BODY…] [--surface ID]

            Shows a macOS notification. Clicking it brings you to this pane.

              make test && mship notify "Tests passed" || mship notify "Tests failed" "see pane"
            """,
        "hook": """
            usage: mship hook AGENT EVENT [JSON]

            Forwards one agent hook event to Mothership. The payload is read from stdin, or from
            the JSON argument (Codex `notify` style). Prints whatever Mothership answers (e.g. a
            permission decision) and exits with its status. Permission events may wait while you
            decide; all others give up after 2 seconds. If Mothership isn't running, exits 0
            silently. Set MOTHERSHIP_DEBUG=1 to see why a hook did nothing.

              mship hook claude PermissionRequest < payload.json
            """,
        "mcp": """
            usage: mship mcp

            Runs an MCP server on stdin/stdout that gives an agent Mothership's tools: browser_open,
            browser_snapshot, browser_click, browser_fill, browser_eval, browser_console,
            browser_screenshot, terminal_split, terminal_read_screen, terminal_send_text,
            notify_user, agents_status and workspace_new. Tools act on the agent's own workspace.
            Supports MCP 2026-07-28 (stateless) and the initialize handshake of 2024-11-05 → 2025-11-25.

              claude mcp add mothership -- mship mcp
              codex mcp add mothership -- mship mcp
            """,
        "ping": """
            usage: mship ping [-q]

            Prints the app's version, pid and the socket round-trip time. Exits 3 if it isn't
            running. -q prints nothing (for scripts).
            """,
        "version": "usage: mship version\n\nPrints mship's version.",
        "help": "usage: mship help [COMMAND]",
    ]

    static func command(_ name: String) -> String? { commands[name].map { $0 + "\n" } }
}
