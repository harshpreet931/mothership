# Contributing to Mothership

Thanks for helping. Mothership is early, so bug reports with clear repro steps are as
valuable as code.

## Before you start

- **Bugs and features:** open an issue first for anything bigger than a small fix, so we can
  agree on the approach.
- **Security:** follow [SECURITY.md](SECURITY.md) and don't open a public issue.

## Setup

You need macOS 26+ and Xcode 26 (Swift 6.2+).

```sh
swift build                      # everything
swift build --target AgentKit    # one module, fast
swift test                       # all unit tests (Swift Testing)
swift test --filter ThemeKitTests
scripts/bundle.sh                # build/Mothership.app
scripts/qa.sh                    # end-to-end checks against a scratch app instance
```

`scripts/qa.sh` launches the real app against a throwaway `MOTHERSHIP_HOME`, so your own
Mothership, its sessions and its settings are never touched. Its windows stay tucked in a
screen corner and never take focus.

## Ground rules

These are also in [CLAUDE.md](CLAUDE.md), which AI coding agents read.

- **Never write to real agent configs** (`~/.claude`, `~/.codex`, `~/.config/opencode`,
  `~/.gemini`) from code under development or tests. Installers take a root directory, so
  tests use temp dirs. Never print or commit credentials.
- **Swift 6 strict concurrency.** Services are actors and UI is `@MainActor`. Don't use
  `@unchecked Sendable` or `nonisolated(unsafe)` without a one-line comment explaining why
  it's safe.
- **No force unwraps or `try!`** outside tests.
- **Dependencies point down only:**
  `MothershipApp → feature modules → ShipProtocol → ShipModel`.
- **Keep `mship hook` fast (<10 ms):** no heavy imports, and exit 0 silently when the app
  isn't running.
- **Agent CLIs change formats often.** Decoders must ignore unknown fields and never crash on
  unexpected input.
- **Prefer Apple frameworks.** Ask in an issue before adding a package.
- **Comments explain *why*, not *what*.**

## Pull requests

- Keep PRs focused, with a clear description of what changed and why.
- Add or update tests for logic changes. UI changes should include before/after
  screenshots, ideally in both a day and a night theme.
- `swift build` must stay warning-free, and `swift test` must pass.
- For UI, follow [docs/DESIGN.md](docs/DESIGN.md): calm, minimal, and color only means
  attention.

## Themes

Themes are plain JSON. [docs/themes.md](docs/themes.md) covers authoring and validation.
New built-in themes must pass `ThemeValidation` with zero errors and zero warnings.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
