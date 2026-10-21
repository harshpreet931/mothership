import ShipModel

enum Help {
    static func overview(_ style: Style) -> String {
        let h = style.bold
        let c = style.cyan
        let d = style.dim
        return """
        \(h("mship")) \(d("— drive Mothership from your shell, scripts, hooks and agents"))

        \(h("USAGE"))
          mship <command> [options]

        \(h("PANES & WORKSPACES"))
          \(c("split")) [--right|--down|--left|--up] [--cwd DIR] [--focus] [-- COMMAND…]
                              Open a terminal pane beside this one, optionally running COMMAND
          \(c("split --browser")) URL     Open a browser pane beside this one
          \(c("new")) [--name NAME] [--cwd DIR] [--background] [-- COMMAND…]
                              Create a workspace (a vertical tab)
          \(c("focus")) SURFACE           Bring a pane to the front
          \(c("send")) [--surface ID] [--submit] TEXT|-
                              Paste text into a pane (this one by default; - reads stdin)
          \(c("screen")) [--surface ID] [--lines N]
                              Print a pane's visible text, plus N lines of scrollback

        \(h("BROWSER"))
          \(c("open")) URL [--split|--new-workspace]
                              Open URL in this workspace's browser pane (localhost:3000 works)
          \(c("browser snapshot"))            Page outline with element refs ([ref=e12])
          \(c("browser click")) REF           Click by ref or CSS selector
          \(c("browser fill")) REF TEXT [--submit]
                              Set a field's value the way a user would (React-safe)
          \(c("browser eval")) JS|-          Run JavaScript and print the result as JSON
          \(c("browser console")) [--errors] [--json]
                              Console messages, exceptions and failed requests
          \(c("browser screenshot"))          Save a PNG of the pane and print its path
                              All browser commands take --browser ID to pick a pane.

        \(h("AGENTS & ATTENTION"))
          \(c("status")) [--json]             Every agent session: workspace, state, cwd, summary
          \(c("notify")) TITLE [BODY]         Show a notification that opens this pane when clicked
          \(c("hook")) AGENT EVENT [JSON]     Forward an agent hook event (stdin or JSON argument);
                              installed into agent configs by Mothership, with consent
          \(c("mcp"))                         Serve Mothership's tools to an agent over MCP (stdio)

        \(h("OTHER"))
          \(c("ping")) [-q]                   Check that Mothership is running
          \(c("version"))                     Print the version
          \(c("help")) [COMMAND]              Show help for a command

        \(h("EXAMPLES"))
          mship split --down -- npm run dev
          mship open localhost:3000
          mship new --name auth-fix --cwd ~/src/api -- claude "fix the failing auth tests"
          long-job && mship notify "Deploy finished" "api is live on staging"
          mship status
          claude mcp add mothership -- mship mcp

        \(h("ENVIRONMENT"))
          MOTHERSHIP_SOCKET          Control socket (set in every Mothership shell)
          MOTHERSHIP_SURFACE_ID      This pane, the default target of most commands
          MOTHERSHIP_WORKSPACE_ID    This workspace, the default scope for agents' MCP tools
          NO_COLOR                   Disable colors; MOTHERSHIP_DEBUG=1 explains silent hook exits

        \(h("EXIT STATUS"))
          0 ok · 1 Mothership reported an error · 2 usage error · 3 Mothership isn't running
          \(d("`mship hook` exits 0 whenever anything goes wrong, so it can never block an agent."))

        """
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
        "focus": """
            usage: mship focus SURFACE

            Selects the pane's workspace and gives the pane keyboard focus.
            """,
        "send": """
            usage: mship send [--surface ID] [--submit] TEXT…
                   mship send [--surface ID] [--submit] -        (reads TEXT from stdin)

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
