# Writing a Mothership theme

A theme is one JSON file. Put it in your themes folder and Mothership picks it up while it
runs. Saving the file reloads it. Built-in themes use exactly the same format; the
catalog lives in `Sources/ThemeKit/BuiltInThemes.swift`, and a good way to start is to export
one and change it.

## A complete example

```json
{
  "id": "harbour-lights",
  "name": "Harbour Lights",
  "summary": "A calm harbour at night, lights on the water and a slow drizzle",
  "author": "you@example.com",
  "version": 1,
  "tone": "dark",
  "tags": ["animated", "dark", "night", "calm"],
  "backdrop": {
    "kind": "fixed",
    "scene": {
      "gradient": [
        {"color": "#050A14", "location": 0},
        {"color": "#0B1626", "location": 0.5},
        {"color": "#14233A", "location": 0.82},
        {"color": "#1E3350", "location": 1}
      ],
      "glows": [
        {"color": "#F2B76640", "center": {"x": 0.3, "y": 1.02}, "radius": 0.45}
      ],
      "layers": [
        {"kind": "stars", "colors": ["#FFFFFF", "#DCE6FF"], "density": 0.4, "speed": 0.2, "opacity": 0.7},
        {"kind": "particles", "particle": "rain", "colors": ["#9FB4CC"], "density": 0.35, "speed": 0.7,
         "direction": 8, "size": 0.18, "opacity": 0.4},
        {"kind": "grain", "opacity": 0.025}
      ]
    }
  },
  "palette": {
    "attention": "#FF8A33",
    "danger": "#F2555A",
    "lightGlass": "#FFFFFF8C",
    "darkGlass": "#0C14208C"
  },
  "terminal": {"dark": "TokyoNight Storm", "light": "TokyoNight Day"}
}
```

## Fields

| Field | What it does |
|---|---|
| `id` | Lowercase letters, digits and dashes. Must not reuse a built-in id. |
| `name`, `summary` | The picker's title and one-line description. |
| `author`, `version` | Optional author; version starts at 1. |
| `tone` | `dark` or `light` chrome (glass and text). `auto` picks light chrome over bright scenes and dark over dim ones. |
| `tags` | Any of `animated`, `still`, `light`, `dark`, `night`, `seasonal`, `calm`, `vivid`, `minimal`. |
| `backdrop` | What's behind the glass (below). |
| `palette` | Chrome colors (below). |
| `terminal` | Names of Ghostty terminal themes that suit the scene, for dark and light. |

Colors are `#RRGGBB`, or `#RRGGBBAA` with alpha.

### Backdrop

- **`"kind": "fixed"`**: one `scene`, always.
- **`"kind": "sunCycle"`**: a scene per sun phase, in `phases`, blended continuously by the sun's
  altitude:

  | Phase | Anchored at |
  |---|---|
  | `night` | −18° |
  | `twilight` | −9° |
  | `blueHour` | −3° |
  | `goldenHour` | 4° |
  | `day` | 20° |

  You need at least two phases; missing ones are bridged by their neighbours.
- **`"kind": "desktop"`**: no scene. The wallpaper shows through frosted glass.

How a sun-cycle blend works:

- Gradients blend in OKLab, so colors never go muddy halfway.
- Glows blend pairwise by position in the list. Put the sun's glow first in every phase,
  and it rises with the sun.
- Layers pair up by `kind` (and `particle`): stars with stars, clouds with clouds. A layer that
  only one phase has fades in or out by opacity.
- Keep layers in the same order in every phase.

### Scene

- `gradient`: top-to-bottom stops. Each stop has a `location` from 0 (top) to 1 (bottom), in
  ascending order. Two stops at the same location make a hard edge, like Synthwave's
  horizon.
- `glows`: soft radial lights. Each has a `center` (x 0 = left, 1 = right; y 0 = top,
  1 = bottom; up to half a window outside is fine) and a `radius` as a fraction of the
  window's larger side (0…1.5). The color's alpha is the strength.
- `layers`, drawn in order:

  | `kind` | Notes |
  |---|---|
  | `stars` | `density`, `speed` (twinkle; 0 = still), `colors` |
  | `shootingStars` | `everySeconds: [min, max]` |
  | `moon`, `sun` | `position`, `size` (fraction of the shorter side), `colors` (a moon tinted blue and green is an Earth) |
  | `clouds` | `colors` `[light, shade]`, `density`, `speed` |
  | `aurora`, `nebula` | `colors`, `position`, `size`, `speed` |
  | `particles` | needs `particle`: `snow`, `rain`, `petals`, `embers`, `bubbles`, `fireflies`, `dust` or `leaves`. `direction` is in degrees: 0 falls straight down, 90 drifts right, 180 rises. |
  | `grid` | a retro floor; `position.y` is the horizon |
  | `digitalRain` | falling glyphs |
  | `grain` | film grain; keep `opacity` around 0.02–0.04 |

  `density`, `speed`, `opacity`, `size` and `position` are all 0…1.

### Palette

| Field | Use |
|---|---|
| `attention` | The "needs you" color for badges and glows. It must stand apart from every color in your scene and from `danger`. Over warm scenes (fire, desert, sunset) use a cool attention like teal or cyan. |
| `danger` | Errors and destructive actions. |
| `lightGlass`, `darkGlass` | The glass tint for light and dark chrome; alpha is opacity (0.55 ≈ `8C`). |
| `selection` | Optional selection fill. |

## Validation

Mothership checks every theme when it loads.

**Errors.** The theme is skipped and the problem is shown:

- a bad id;
- fewer than two gradient stops, or stops out of order;
- values outside 0…1;
- a `particle` on a non-particle layer, or a particles layer without one;
- `everySeconds` that isn't `[min, max]`;
- a fixed backdrop without a scene, or a sun cycle with fewer than two phases.

**Design checks.** These are warnings for your themes; built-ins must pass them:

- Primary text on the glass over the scene's middle color needs 4.5:1 contrast, and secondary
  text (ink at 56 %) needs 3:1. If it fails, make the glass more opaque, or move the scene's
  middle away from the text color.
- `attention` must not be confusable with any gradient or layer color, or with `danger`.
  Confusable means nearly the same color (ΔE_OK < 0.1), or the same hue family at a similar
  colorfulness.

## Tips from the built-ins

- Sample the mood from a real reference: a photo of the place at that hour.
- Put the darkest stop at the top for night scenes, and let the horizon carry the light.
- A glow just below the window (`y` ≈ 1.05) reads as a light source out of view: a fire, a
  city, the sun after it has set.
- One or two layers beat five. Grain at 0.02–0.03 takes the digital edge off any gradient.
- Check your theme over both glass tints if you use `tone: auto`.
