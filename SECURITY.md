# Security

Mothership runs shells and coding agents, edits agent hook configs (with your consent),
listens on local Unix sockets, and exposes tools to agents over MCP. Security reports are
taken seriously.

## Reporting a vulnerability

Please **don't open a public issue.** Use GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository. Include:

- what an attacker can do, and the conditions they need;
- steps to reproduce, or a proof of concept;
- the Mothership version or commit, and the macOS version.

You'll get an acknowledgement within a few days. A fix will be coordinated before any public
disclosure.

## Scope

These areas are the most sensitive:

- **Control socket and session daemon:** `control.sock` and `sessions.sock` are user-only
  (`0600`) and check the peer's uid. A way for another user or process to drive panes,
  read screens or answer permission prompts is in scope.
- **MCP tools** (`mship mcp`): tools are scoped to the caller's workspace by default. Escaping
  that scope, or leaking another pane's screen or secrets, is in scope.
- **Hook installers:** any path that writes agent configs without consent, or corrupts them,
  is in scope.
- **Permission flow:** anything that approves an agent's request without the user doing so
  is in scope.
