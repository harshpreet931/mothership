# Mothership Design Language: "Sky"

> **Calm sky, sharp ink.** Work floats in a quiet atmosphere. Controls are frosted glass,
> content sits on solid cards, and color appears only when an agent needs you.

The primary reference is **Hark** (hark.com). There are 6 reference screenshots in
`~/Desktop/Screenshot 2026-10-07 at 15.36.*.png`. Secondary references are Apple Liquid
Glass, Linear, Raycast, Arc/Dia, Things 3, Superhuman, Family and Vercel Geist.

---

## 1. What Hark gets right (taken from the screenshots)

| # | Observation | How Mothership uses it |
|---|---|---|
| 1 | **An atmospheric backdrop.** A full-bleed, heavily blurred sky photo is the canvas. Every panel floats over it with sky visible in the gutters. | A "Sky" layer behind the whole window (procedural `MeshGradient` presets, §7). Panes and the sidebar are floating cards with 10 pt gutters where the sky shows. |
| 2 | **Frosted panels.** White glass at roughly 55–70 % tint, heavy blur, radius ≈ 24–28, no border, no shadow. | Sidebar, palette, composer, toasts and settings use glass. |
| 3 | **Black is the only accent.** The selected segment is a solid near-black capsule with white text. Everything else is monochrome. | Selection is a solid **ink pill** that inverts in dark mode, slides between items with `matchedGeometryEffect`, and has no tinted highlights. |
| 4 | **Pills and circles only.** Segmented pill (Chat · Projects), white "Connect" pills, frosted circle buttons (home ⌂, close ✕, back ‹), a capsule composer with `+` and mic. | Every control is a capsule or a circle. Nothing is a bordered rectangle. |
| 5 | **Quiet, big type for ambient information.** A giant tight-tracked clock fills the idle state ("Wed / Oct 7 / 3:36 PM"). A serif headline appears in editorial moments ("hark can do more"). Page titles are large and regular weight, not bold ("Accounts"). | The ambient Home uses a display clock and a New York serif greeting. Page titles are 34 pt regular. |
| 6 | **Chat bubbles.** The assistant gets an opaque white bubble on the left; the user gets a frosted pill on the right. Lots of air. | The tails of agent conversations in Fleet cards and the Home "Working now" panel use the same bubbles. |
| 7 | **Stacked cards.** A news card sits on a fanned stack, which reads as "there's more" with tactile depth. | Pending permissions and unread finishes become a fanned stack that spreads on hover. |
| 8 | **Inset grouped lists.** A frosted card with inset hairline dividers, tall rows (~64 pt), logo + title + subtitle, and a trailing white pill button. | Settings → Integrations is Hark's Accounts page, built for agents. |
| 9 | **Panels are user-composable** ("Create a new panel"). | The Home dashboard is made of panels, and users can add or remove them. |
| 10 | **Minimal chrome.** Home circle on the left, segmented pill centered, search pill on the right, composer at the bottom. Nothing else. | The top bar has no background band, just floating controls over the sky. |

## 2. What the rest of the best in class contributes

- **Apple Liquid Glass:** glass belongs to the *control layer* above content, never to the
  content itself. Radii are concentric (inner = outer − padding). Reduce Transparency is
  respected.
- **Linear:** restraint (monochrome plus one accent), everything works from the keyboard,
  feedback is instant (< 100 ms), and menus show their shortcuts.
- **Raycast:** ⌘K *is* the app. Results come in sections with trailing accessories, and a
  selected row has its own actions panel (⌘K on a row).
- **Arc / Dia:** the sidebar is the app's spine. Hovering the left edge peeks an auto-hidden
  sidebar. Each space has a quiet tint.
- **Things 3:** calm whitespace, a clear typographic hierarchy, and short moments of
  delight (completion animations under 300 ms).
- **Superhuman:** speed is the identity. Shortcut hints teach themselves, and "zero"
  moments are celebrated ("All quiet. 4 agents idle.").
- **Family (wallet):** one container morphs between states instead of being swapped out.
  The permission UI morphs from a badge to a card to a resolved checkmark.
- **Vercel Geist:** sans for prose and mono for metadata (paths, branches, tokens), with
  tabular numbers.

## 3. Principles

1. **Content on cards, controls on glass, everything on sky.**
2. **Color = attention.** The chrome is monochrome. **Amber** means "needs you", **red**
   means error. Agent brand marks are small and are the only other color.
3. **Selection is ink.** One solid ink pill that slides. No outlines or tinted
   backgrounds for selection.
4. **Capsules and circles.** No bordered rectangles. No 1 px boxes around inputs.
5. **One focal point per view.** Big quiet type for ambient information, small precise type
   for data.
6. **The keyboard comes first, and the mouse is delightful.** Every action has a shortcut
   and appears in ⌘K.
7. **Calm motion.** Springs, nothing over 250 ms, no bounce on data. Pulsing is reserved
   for attention.
8. **Respect the terminal.** Aesthetics never cost terminal contrast or latency.
   Background animation freezes while you type.

## 4. Tokens

**Spacing (4 pt base):** 4 · 8 · 12 · 16 · 20 · 24 · 32 · 48. Floating gutter = **10**.
Panel inner padding = **14**.

**Radii (concentric):** chip 8 · control 12 · pane card 18 · panel 24 · capsule = height/2.

**Type**

| Token | Spec | Use |
|---|---|---|
| `display.xl` | SF Pro Display 64/60, regular, tracking −2 % | Ambient clock |
| `display.l` | SF Pro Display 34, regular, −1 % | Page titles ("Integrations") |
| `serif.l` | New York (`.serif`) 26, regular | Editorial headings ("Good evening, Harshpreet") |
| `title` | SF Pro 15, medium | Row titles, card titles |
| `body` | SF Pro 13.5, regular | Bubbles, descriptions |
| `meta` | SF Mono 11.5, regular, tabular | Paths, branches, tokens, timestamps |
| `label` | SF Pro 12, medium | Pills, segmented control |

**Color**

| Token | Day (light) | Night (dark) |
|---|---|---|
| `ink` (selection fill, primary text) | `#0D0E11` | `#F4F5F7` |
| `onInk` | `#FFFFFF` | `#0D0E11` |
| `text.secondary` | ink @ 56 % | ink @ 56 % |
| `text.tertiary` | ink @ 36 % | ink @ 36 % |
| `glass.fill` | white @ 55 % + blur 30 | `#14161B` @ 55 % + blur 30 |
| `glass.highlight` (top inner hairline) | white @ 70 % | white @ 8 % |
| `bubble` (opaque, assistant) | `#FFFFFF` | `#1D1F25` |
| `bubble.user` (frosted) | white @ 40 % | white @ 10 % |
| `pill.secondary` (e.g. Connect) | `#FFFFFF` | white @ 12 % |
| `attention` | `#FF7A1A` | `#FF8A33` |
| `attention.soft` | `#FF7A1A` @ 14 % | `#FF8A33` @ 18 % |
| `danger` | `#E5484D` | `#F2555A` |

"Done" is shown with an ink checkmark, not green, so green never competes with amber.

**Elevation:** glass has no shadows. Opaque cards get `0 8 24 ink@8 %` in Day only.

**Motion**
- Default spring: response 0.32, damping 0.86. Hover: 120 ms ease-out.
- Selection pill: `matchedGeometryEffect` spring.
- Attention pulse: a 1.8 s ease-in-out loop on an amber halo, scale 1 → 1.35, opacity
  0.5 → 0.
- Stacked cards: fan out on hover (±4°, 6 pt offsets), collapse on exit.
- Workspace switch: content crossfades with scale 0.985 → 1.
- Reduce Motion turns all of this into crossfades. Reduce Transparency turns glass into
  solid `bubble` surfaces.

## 5. Layout

```
╭──────────────────────────────── sky (MeshGradient) ─────────────────────────────────╮
│ ● ● ●  (⌂) (◫)            ╭ Workspaces ┃ Fleet ╮                   ( ⌕ Search ⌘K ) │  floating, no bar
│ ╭─────────────────╮  ╭──────────────────────────────╮ ╭───────────────────────────╮ │
│ │ ▌mothership  ✳● │  │                              │ │                           │ │
│ │  ~/ship  ⑂ feat │  │      terminal card (r18)     │ │   terminal / browser      │ │
│ │ ╭─────────────╮ │  │                              │ │                           │ │
│ │ │ Bash · npm… │ │  │                              │ │                           │ │
│ │ │(Deny)(Allow)│ │  │                              │ │                           │ │
│ │ ╰─────────────╯ │  │                              │ │                           │ │
│ │  web-dashboard  │  │                              │ │                           │ │
│ │  infra        ✓ │  ╰──────────────────────────────╯ ╰───────────────────────────╯ │
│ │ ＋ New workspace │       ( Message Claude · mothership …              ＋  🎙 )     │  composer
│ ╰─────────────────╯                                                                 │
╰─────────────────────────────────────────────────────────────────────────────────────╯
```

- **Window:** no visible titlebar. The traffic lights float over the sky, aligned with the
  sidebar panel's top inset.
- **Top bar (≈ 52 pt, transparent):**
  - Left: circle buttons **Home** ⌂ and **Sidebar** ◫, 32 pt glass circles.
  - Center: segmented pill **Workspaces · Fleet**.
  - Right: search pill "Search ⌘K".
  - Double-clicking empty top-bar space zooms the window.
- **Sidebar:** a floating glass panel inset by 10, radius 24, default width 260. It can be
  collapsed (⌘B) and peeks when you hover the left edge.
- **Content:** pane cards with radius 18 and 10 pt gutters showing the sky. A split divider
  is the gutter itself, and the cursor changes on hover.
- **Composer:** a bottom band of 56 pt with a centered capsule (max width 720). It can be
  toggled with ⌘L and hidden in Settings.

## 6. Components

### Sidebar row (vertical tab)
- **Resting:**
  - Line 1: name in `title`, with agent glyphs on the right (14 pt brand marks, monochrome
    until they need attention).
  - Line 2: `meta` cwd and branch, e.g. `~/ship · ⑂ feat/token-refresh`.
  - Line 3: an optional `body` secondary line with the agent summary, 1 line, truncated.
- **Selected:** a solid ink pill behind the row. Text becomes `onInk`, and the pill slides
  between rows.
- **Hover:** glass highlight at 6 %.
- **Attention:** an amber dot with a pulse halo on the glyph, and the summary line turns
  amber. No colored left bars.
- **Pending permission:** the row grows (Family-style morph) into an inline card:
  - The card is the `bubble` surface with radius 14.
  - A tool line, e.g. "Bash wants to run".
  - The command in `meta` on a recessed chip.
  - Two capsules: Deny (secondary) and Allow (ink).
  - After a decision the card collapses into a ✓ that fades away.

### Agent glyphs
Use brand-recognizable but monochrome marks: a Claude spark, the Codex/OpenAI knot,
OpenCode brackets, a Gemini sparkle. Draw them as SF Symbols or simple `Path`s; don't
ship trademarked artwork beyond simple marks. State overlays:
- **Working:** a slow rotating arc around the glyph (2 s per rotation, 1.5 pt).
- **Needs you:** an amber dot with a halo.
- **Done and unread:** a small ink dot.
- **Error:** a red dot.

### Segmented pill
- A glass capsule track with height 36 and padding 3.
- The selected segment is an ink capsule with an `onInk` label. Unselected labels use
  `text.secondary`.
- The selection animates with matched geometry.

### Buttons
- **Primary:** an ink capsule.
- **Secondary:** a `pill.secondary` capsule (white in Day) with ink text, like Hark's
  "Connect".
- **Ghost:** a text-only capsule that shows a glass hover.
- **Circle:** 32 or 44 pt glass circles holding a single symbol.
- No bordered buttons anywhere.

### Composer
- A glass capsule with height 44 and a leading agent glyph.
- The placeholder adapts:
  - "Message Claude · mothership" when the focused pane runs an agent.
  - "Start a task…" otherwise, which launches a chosen agent in a new workspace (the
    worktree option comes later).
- The trailing `＋` opens a menu: choose the agent, attach the current selection or browser
  element, broadcast to all agents.
- The trailing 🎙 starts dictation.
- ⏎ sends. While an agent is busy, ⇧⏎ queues the prompt, and a small "1 queued" chip
  appears.
- Delivery is a bracketed paste into the target pane followed by Enter.

### Attention stack (in-app toasts)
- Lives at the top right, below the search pill.
- A fanned stack of glass cards for events you didn't see: permission requests, finished
  runs, errors.
- The top card shows the full content and actions. Hovering fans out up to 3 cards.
- Esc dismisses. Clicking a card jumps to its pane.
- System notifications still fire when the app is in the background.

### Home (⌂) – ambient mission control
- **Left column:** a `display.xl` clock and date, the same composition as Hark's idle
  screenshot.
- **Above the panels:** a `serif.l` greeting ("Good evening, Harshpreet", using the first
  name from `NSFullUserName()`), with a status sentence below it ("3 agents working · 1
  needs you").
- **Panels (glass, radius 24, in a masonry grid):**
  - **Needs you:** the fanned stack.
  - **Working now:** one card per agent with bubble tails (last prompt as a frosted pill,
    last reply as a white bubble).
  - **Today:** tokens and estimated cost, with tabular numbers.
  - **Ports:** `localhost:3000 · web-dashboard` with an Open pill.
  - **Elsewhere:** agents running in VS Code or iTerm.
  - **＋ Create a new panel.**
- Home is the empty state, and it's also where ⌘0 goes.

### Fleet
- A grid of agent cards, minimum width 320, covering every session in and out of the app.
- Each card has:
  - A header: brand glyph, name, workspace, state, elapsed time.
  - The bubble tail.
  - The pending permission, if any, with inline actions.
  - A footer: tokens and context bar in `meta`.
- Filter pills: All · Needs you · Working · Done · Elsewhere.
- Clicking a card focuses its pane, or reveals the host app for external sessions.

### Settings (Hark Accounts pattern)
- A circle back button, then a `display.l` title.
- A segmented pill: **Agents · Appearance · Notifications · Keys**.
- Content is an inset grouped glass list with tall rows: logo, title, subtitle (e.g.
  "Hooks · 13 events · v2.1.306"), and a trailing pill.
- The trailing pill reads Connect (secondary), Connected ✓ (ghost), or Repair (amber text)
  when another tool overwrote our hooks.
- **Appearance:** sky preset swatches (circles), terminal theme, font size, and the
  composer toggle.

### Command palette (⌘K)
- A centered glass panel, radius 24, width 640.
- A 20 pt input with no box.
- Sectioned results: Actions · Workspaces · Agents · Recent commands, each with a trailing
  shortcut hint in `meta`.
- ⌘K on a selected result opens its actions panel (Raycast).
- Matching is fuzzy and highlights the matched characters in ink.

### Pane chrome
- No permanent tab bars.
- On hover (or while an agent is active), a small glass capsule sits top-right inside the
  pane: title · state glyph · split · close.
- **Focused pane:** a subtle elevation plus a 1 pt ink ring at 18 %.
- **Attention pane:** an amber outer halo (soft 14 pt glow, pulsing) instead of a hard
  border.

### Empty states
- A `serif.l` line plus one ink capsule action, e.g. "Nothing running. *Start a task*".

## 7. Sky presets

Each preset is a 3×3 `MeshGradient`:
- **Day:** Hark blue sky. Cornflower `#5B8FD6` at the top, cloud white `#E9EEF4` at the
  bottom right, steel `#8FA9C8` at the bottom left.
- **Dusk:** peach `#F2B38A`, mauve `#B98BB5`, indigo `#4B4F8C`.
- **Night:** `#0B1020`, `#1B2340`, `#2A1F3D`, plus a faint star grain.
- **Graphite:** a near-flat `#1A1B1F` → `#24262B` for minimalists.
- **Desktop:** see-through, using a behind-window blur of the user's wallpaper.
- **Auto:** follows the time of day (Dawn → Day → Dusk → Night).

Add a 2 % noise overlay to prevent banding. Drift the mesh control points very slowly
(about 60 s per cycle) only while idle. Freeze for 3 s after any keystroke, and freeze
entirely on battery or with Reduce Motion. Day pairs with the light chrome, and Night,
Dusk and Graphite pair with dark chrome. Auto follows the system appearance unless the
user overrides it.

## 8. The terminal inside the sky

- The pane card's background is the Ghostty theme background, kept opaque for legibility.
  Dark terminal cards floating on a Day sky are intentional and striking, like Hark's black
  "Sign in to Google" pill on blue.
- An optional "Tint with sky" setting gives 88 % opacity and a blur for users who want
  more atmosphere.
- Inner padding is 14/16, and the radius of the clipped content is 18.

## 9. Accessibility

- Text on glass meets WCAG AA. Add a dimming or brightening scrim under glass when the sky
  is too bright or too dark behind it.
- All controls have VoiceOver labels and visible keyboard focus.
- Hit targets are at least 28 pt.
- Honor Reduce Motion, Reduce Transparency and Increase Contrast. Increase Contrast adds
  1 pt ink @ 30 % strokes to glass.

## 10. Anti-patterns (don't)

- Gradients or colored fills on controls.
- Colored borders on idle elements.
- Numeric badges everywhere (only the Dock badge counts).
- Tab bars inside panes.
- Emoji in the UI.
- Drop shadows on glass.
- More than one accent hue in the chrome.
- Bold page titles.
- Bordered text fields.
- Spinners where a shimmer or arc reads calmer.
- Animation while typing.

## 11. Logo: "Arch M"

Two arches with three legs read as a lowercase **m**, and also as a saucer's dome
hovering over its glowing disc. It pairs with the lowercase wordmark `mothership`.
Exploration canvas: https://claude.ai/artifact/5J2aE3eeg7K9Hpt9Hrkbvt (board 04).

**Geometry** (120 × 120 viewBox; the mark spans y 33–89, so shift it up 1 to center it optically):

```
arches: M28 68 V54 A16 16 0 0 1 60 54 V68 M60 54 A16 16 0 0 1 92 54 V68
        stroke 10, round caps, round joins, no fill
disc:   rect x18 y80 w84 h9 rx4.5        (the 7-unit gap above it is the "hover")
```

| Context | Arches | Disc | Ground |
|---|---|---|---|
| App icon (primary) | `#F4F5F7` | horizontal gradient `#5B8FD6` → `#C6DBFF` | ink tile `#0D0E11` + top radial highlight white @ 14 % + inner top hairline white @ 12 % |
| Sky (Day surfaces) | ink `#0D0E11` | white | the sky |
| Light UI (on white) | ink | gradient `#3F74C4` → `#8DB4F0` | white |
| Dark UI | `#F4F5F7` | gradient `#5B8FD6` → `#C6DBFF` | ink |
| Mono ≤ 32 px (menu bar, favicons, template images) | stroke **12** | height **11**, rx 5.5 | single color (`currentColor`/template) |

- **Wordmark:** `mothership` in lowercase, SF Pro Display Medium, tracking −3.5 %. The
  mark's height is about 1.45 × the x-height, with a gap of 0.4 × the mark's width.
- **Icon:** the mark fills about 62 % of the tile width. The tile uses the macOS 26
  rounded-rect icon shape. Don't add drop shadows inside the tile.
- **Motion (optional, ≤ 600 ms, once):** on launch or Home, the disc draws in from the
  center outward, then the arches rise 2 units into place.
- **Don't:** recolor the arches with the gradient, outline the mark, tilt it, or put the
  amber attention color in the logo. Amber means "needs you", never "brand".
