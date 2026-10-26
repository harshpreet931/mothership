import Foundation

/// The built-in catalog, as the same JSON a user theme is written in (see docs/themes.md).
/// Decoded once; a theme that fails to decode is dropped, and a test asserts all 19 load and
/// validate.
enum BuiltInThemes {
    static let catalog: [Theme] = json.compactMap { try? JSONDecoder().decode(Theme.self, from: Data($0.utf8)) }
    static let ids: Set<String> = Set(catalog.map(\.id))

    static let json: [String] = [
        mothershipSky, midnight, aurora, nebula, deepSea, sakura, ember, monsoon, firstSnow, dune, fireflyForest,
        synthwave, digitalRain, mars, lunar, goldenHour, graphite, paper, desktop,
    ]

    // MARK: Sun cycle

    /// The living sky, ported from the app's sun-phase keyframes (SunModel.swift): starry
    /// night with the moon and the odd shooting star, twilight, blue hour, golden hour, and
    /// a day of drifting clouds. The glow follows the sun up out of the horizon.
    static let mothershipSky = #"""
        {
          "id": "mothership-sky", "name": "Mothership Sky", "author": "Mothership", "version": 1,
          "summary": "The living sky: follows the real sun from starry night through golden hour to day",
          "tone": "auto", "tags": ["animated", "light", "dark", "night", "calm"],
          "backdrop": {"kind": "sunCycle", "phases": {
            "night": {
              "gradient": [{"color": "#050814", "location": 0}, {"color": "#0B1128", "location": 0.55}, {"color": "#161B3A", "location": 1}],
              "glows": [{"color": "#2A235000", "center": {"x": 0.8, "y": 1.06}, "radius": 0.65}],
              "layers": [
                {"kind": "stars", "colors": ["#FFFFFF", "#DCE4FF"], "density": 0.85, "speed": 0.3, "opacity": 1},
                {"kind": "moon", "colors": ["#F4F1E8"], "position": {"x": 0.36, "y": 0.035}, "size": 0.12, "opacity": 1},
                {"kind": "shootingStars", "colors": ["#FFFFFF"], "opacity": 0.85, "everySeconds": [45, 150]},
                {"kind": "grain", "opacity": 0.02}
              ]},
            "twilight": {
              "gradient": [{"color": "#0E1735", "location": 0}, {"color": "#212D5C", "location": 0.55}, {"color": "#544B81", "location": 1}],
              "glows": [{"color": "#97627E4D", "center": {"x": 0.8, "y": 1.06}, "radius": 0.65}],
              "layers": [
                {"kind": "stars", "colors": ["#FFFFFF", "#DCE4FF"], "density": 0.85, "speed": 0.3, "opacity": 0.62},
                {"kind": "shootingStars", "colors": ["#FFFFFF"], "opacity": 0.5, "everySeconds": [45, 150]},
                {"kind": "clouds", "colors": ["#A895BF", "#78719C"], "density": 0.5, "speed": 0.2, "opacity": 0.15},
                {"kind": "grain", "opacity": 0.02}
              ]},
            "blueHour": {
              "gradient": [{"color": "#22376D", "location": 0}, {"color": "#4E629E", "location": 0.55}, {"color": "#B88A98", "location": 1}],
              "glows": [{"color": "#F19F77A6", "center": {"x": 0.8, "y": 1.035}, "radius": 0.65}],
              "layers": [
                {"kind": "stars", "colors": ["#FFFFFF", "#DCE4FF"], "density": 0.85, "speed": 0.3, "opacity": 0.17},
                {"kind": "clouds", "colors": ["#E3AEB2", "#AF94AB"], "density": 0.5, "speed": 0.2, "opacity": 0.4},
                {"kind": "grain", "opacity": 0.02}
              ]},
            "goldenHour": {
              "gradient": [{"color": "#3760AF", "location": 0}, {"color": "#7496D2", "location": 0.55}, {"color": "#F2C0A0", "location": 1}],
              "glows": [{"color": "#FFC27AAD", "center": {"x": 0.8, "y": 0.86}, "radius": 0.68}],
              "layers": [
                {"kind": "clouds", "colors": ["#FFDAC5", "#CEC3CA"], "density": 0.5, "speed": 0.2, "opacity": 0.68},
                {"kind": "grain", "opacity": 0.02}
              ]},
            "day": {
              "gradient": [{"color": "#2B6AD8", "location": 0}, {"color": "#5C97E8", "location": 0.55}, {"color": "#CBE1F6", "location": 1}],
              "glows": [{"color": "#FFF4DC40", "center": {"x": 0.8, "y": 0.46}, "radius": 0.62}],
              "layers": [
                {"kind": "clouds", "colors": ["#FFFFFF", "#C6DBF7"], "density": 0.5, "speed": 0.2, "opacity": 0.95},
                {"kind": "grain", "opacity": 0.02}
              ]}
          }},
          "palette": {"attention": "#FF8A33", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#10141F9E"},
          "terminal": {"dark": "Catppuccin Mocha", "light": "Catppuccin Latte"}
        }
        """#

    /// Cherry blossom through a spring day: pale sky and petals by day, peach at golden
    /// hour, lavender at blue hour, and a plum night with petals drifting under the moon.
    static let sakura = #"""
        {
          "id": "sakura", "name": "Sakura", "author": "Mothership", "version": 1,
          "summary": "Cherry blossom drifting through a spring day, and under the moon at night",
          "tone": "auto", "tags": ["animated", "light", "dark", "seasonal", "calm"],
          "backdrop": {"kind": "sunCycle", "phases": {
            "night": {
              "gradient": [{"color": "#0B0B1F", "location": 0}, {"color": "#1A1534", "location": 0.55}, {"color": "#2B1E45", "location": 1}],
              "glows": [{"color": "#FF9EC126", "center": {"x": 0.22, "y": 1.05}, "radius": 0.55}],
              "layers": [
                {"kind": "stars", "colors": ["#FFFFFF", "#FFE3EE"], "density": 0.6, "speed": 0.25, "opacity": 0.8},
                {"kind": "moon", "colors": ["#FFF3F7"], "position": {"x": 0.7, "y": 0.1}, "size": 0.1, "opacity": 0.95},
                {"kind": "particles", "particle": "petals", "colors": ["#F2B6CF", "#FFD3E2"], "density": 0.32, "speed": 0.18, "direction": 65, "size": 0.45, "opacity": 0.55},
                {"kind": "grain", "opacity": 0.025}
              ]},
            "twilight": {
              "gradient": [{"color": "#1C1F45", "location": 0}, {"color": "#3E3768", "location": 0.55}, {"color": "#7A5784", "location": 1}],
              "glows": [{"color": "#C0709A40", "center": {"x": 0.78, "y": 1.04}, "radius": 0.65}],
              "layers": [
                {"kind": "stars", "colors": ["#FFFFFF", "#FFE3EE"], "density": 0.6, "speed": 0.25, "opacity": 0.45},
                {"kind": "clouds", "colors": ["#B99AC4", "#7E6A9E"], "density": 0.4, "speed": 0.12, "opacity": 0.15},
                {"kind": "particles", "particle": "petals", "colors": ["#D99AB8", "#F0BFD3"], "density": 0.35, "speed": 0.2, "direction": 65, "size": 0.45, "opacity": 0.65},
                {"kind": "grain", "opacity": 0.025}
              ]},
            "blueHour": {
              "gradient": [{"color": "#4C5A99", "location": 0}, {"color": "#9A8CBF", "location": 0.55}, {"color": "#E2A9BC", "location": 1}],
              "glows": [{"color": "#F5A3A880", "center": {"x": 0.78, "y": 1.0}, "radius": 0.7}],
              "layers": [
                {"kind": "stars", "colors": ["#FFFFFF"], "density": 0.6, "speed": 0.25, "opacity": 0.12},
                {"kind": "clouds", "colors": ["#E6C3D8", "#A795BF"], "density": 0.4, "speed": 0.12, "opacity": 0.35},
                {"kind": "particles", "particle": "petals", "colors": ["#E8A3C0", "#F2BCD2"], "density": 0.38, "speed": 0.22, "direction": 65, "size": 0.48, "opacity": 0.8},
                {"kind": "grain", "opacity": 0.02}
              ]},
            "goldenHour": {
              "gradient": [{"color": "#8FA6D6", "location": 0}, {"color": "#F2C1C8", "location": 0.55}, {"color": "#FFD7B8", "location": 1}],
              "glows": [{"color": "#FFC89AA6", "center": {"x": 0.8, "y": 0.84}, "radius": 0.7}],
              "layers": [
                {"kind": "clouds", "colors": ["#FFE2D6", "#F3C4CF"], "density": 0.4, "speed": 0.12, "opacity": 0.5},
                {"kind": "particles", "particle": "petals", "colors": ["#F7AFC6", "#FFC6D3", "#FFD9C9"], "density": 0.4, "speed": 0.25, "direction": 65, "size": 0.5, "opacity": 0.9},
                {"kind": "grain", "opacity": 0.02}
              ]},
            "day": {
              "gradient": [{"color": "#A9CBEB", "location": 0}, {"color": "#E9D7E6", "location": 0.55}, {"color": "#FBE5EC", "location": 1}],
              "glows": [{"color": "#FFF6EA80", "center": {"x": 0.82, "y": 0.18}, "radius": 0.6}],
              "layers": [
                {"kind": "clouds", "colors": ["#FFFFFF", "#F6E3EC"], "density": 0.4, "speed": 0.12, "opacity": 0.45},
                {"kind": "particles", "particle": "petals", "colors": ["#F6B3CB", "#F9C9D9", "#FFE1EA"], "density": 0.4, "speed": 0.25, "direction": 65, "size": 0.5, "opacity": 0.9},
                {"kind": "grain", "opacity": 0.02}
              ]}
          }},
          "palette": {"attention": "#FF7A1A", "danger": "#E5484D", "lightGlass": "#FFFFFF8C", "darkGlass": "#1A142499"},
          "terminal": {"dark": "Rose Pine", "light": "Rose Pine Dawn"}
        }
        """#

    /// A desert from noon haze to a night so clear the Milky Way shows: sand blowing in a
    /// warm wind, a pale sun, a copper sunset, then stars, a moon and shooting stars.
    static let dune = #"""
        {
          "id": "dune", "name": "Dune", "author": "Mothership", "version": 1,
          "summary": "Warm desert wind from noon haze to a copper sunset and a night full of stars",
          "tone": "auto", "tags": ["animated", "light", "dark", "night", "vivid"],
          "backdrop": {"kind": "sunCycle", "phases": {
            "night": {
              "gradient": [{"color": "#04060F", "location": 0}, {"color": "#0A0F24", "location": 0.5}, {"color": "#141A35", "location": 0.85}, {"color": "#1B1F3A", "location": 1}],
              "glows": [{"color": "#1B1F3A00", "center": {"x": 0.8, "y": 1.06}, "radius": 0.7}],
              "layers": [
                {"kind": "stars", "colors": ["#FFFFFF", "#FFE8C8", "#D6E2FF"], "density": 1, "speed": 0.3, "opacity": 1},
                {"kind": "moon", "colors": ["#F6EFE0"], "position": {"x": 0.3, "y": 0.1}, "size": 0.1, "opacity": 0.9},
                {"kind": "shootingStars", "colors": ["#FFFFFF"], "opacity": 0.9, "everySeconds": [30, 90]},
                {"kind": "particles", "particle": "dust", "colors": ["#8C7A70", "#6E6470"], "density": 0.2, "speed": 0.25, "direction": 82, "size": 0.2, "opacity": 0.12},
                {"kind": "grain", "opacity": 0.03}
              ]},
            "twilight": {
              "gradient": [{"color": "#111734", "location": 0}, {"color": "#262A50", "location": 0.5}, {"color": "#4E3F62", "location": 0.85}, {"color": "#6B4F66", "location": 1}],
              "glows": [{"color": "#8E5A7A33", "center": {"x": 0.8, "y": 1.04}, "radius": 0.7}],
              "layers": [
                {"kind": "stars", "colors": ["#FFFFFF", "#FFE8C8", "#D6E2FF"], "density": 1, "speed": 0.3, "opacity": 0.6},
                {"kind": "shootingStars", "colors": ["#FFFFFF"], "opacity": 0.5, "everySeconds": [30, 90]},
                {"kind": "particles", "particle": "dust", "colors": ["#A88378", "#7E6A78"], "density": 0.24, "speed": 0.28, "direction": 82, "size": 0.2, "opacity": 0.18},
                {"kind": "grain", "opacity": 0.03}
              ]},
            "blueHour": {
              "gradient": [{"color": "#26336A", "location": 0}, {"color": "#6A5E92", "location": 0.5}, {"color": "#C88B7B", "location": 0.85}, {"color": "#D9A07A", "location": 1}],
              "glows": [{"color": "#E8896A73", "center": {"x": 0.8, "y": 0.99}, "radius": 0.75}],
              "layers": [
                {"kind": "stars", "colors": ["#FFFFFF"], "density": 1, "speed": 0.3, "opacity": 0.2},
                {"kind": "particles", "particle": "dust", "colors": ["#C99A86", "#9C7A86"], "density": 0.28, "speed": 0.32, "direction": 82, "size": 0.22, "opacity": 0.3},
                {"kind": "grain", "opacity": 0.03}
              ]},
            "goldenHour": {
              "gradient": [{"color": "#4E6AA6", "location": 0}, {"color": "#C79A8C", "location": 0.5}, {"color": "#EFAE72", "location": 0.85}, {"color": "#F6C27E", "location": 1}],
              "glows": [{"color": "#FFB25EA6", "center": {"x": 0.78, "y": 0.8}, "radius": 0.78}],
              "layers": [
                {"kind": "sun", "colors": ["#FFE0A3", "#FFB04D"], "position": {"x": 0.78, "y": 0.8}, "size": 0.08, "opacity": 1},
                {"kind": "particles", "particle": "dust", "colors": ["#F0B878", "#D98E55"], "density": 0.32, "speed": 0.35, "direction": 82, "size": 0.22, "opacity": 0.55},
                {"kind": "grain", "opacity": 0.03}
              ]},
            "day": {
              "gradient": [{"color": "#5E97D1", "location": 0}, {"color": "#A9C6DE", "location": 0.5}, {"color": "#E8D3AE", "location": 0.85}, {"color": "#EBC48C", "location": 1}],
              "glows": [{"color": "#FFF1D066", "center": {"x": 0.78, "y": 0.22}, "radius": 0.62}],
              "layers": [
                {"kind": "sun", "colors": ["#FFF8E7", "#FFE7B0"], "position": {"x": 0.78, "y": 0.2}, "size": 0.06, "opacity": 0.9},
                {"kind": "particles", "particle": "dust", "colors": ["#E3BF8A", "#D4A26A"], "density": 0.3, "speed": 0.35, "direction": 82, "size": 0.22, "opacity": 0.45},
                {"kind": "grain", "opacity": 0.03}
              ]}
          }},
          "palette": {"attention": "#0FB5A6", "danger": "#E5484D", "lightGlass": "#FFFFFF8C", "darkGlass": "#14131C99"},
          "terminal": {"dark": "Gruvbox Material Dark", "light": "Gruvbox Light"}
        }
        """#

    // MARK: Night skies

    static let midnight = #"""
        {
          "id": "midnight", "name": "Midnight", "author": "Mothership", "version": 1,
          "summary": "A clear, moonless sky long after the city has gone quiet",
          "tone": "dark", "tags": ["animated", "dark", "night", "calm"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#02030A", "location": 0}, {"color": "#060A1C", "location": 0.5}, {"color": "#0D1430", "location": 0.85}, {"color": "#18203F", "location": 1}],
            "glows": [{"color": "#3A4C8A40", "center": {"x": 0.5, "y": 1.12}, "radius": 0.8}],
            "layers": [
              {"kind": "stars", "colors": ["#FFFFFF", "#CFDBFF", "#FFE9C9"], "density": 0.75, "speed": 0.25, "opacity": 1},
              {"kind": "shootingStars", "colors": ["#FFFFFF"], "opacity": 0.8, "everySeconds": [40, 120]},
              {"kind": "grain", "opacity": 0.025}
            ]}},
          "palette": {"attention": "#FF8A33", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#10131C8C"},
          "terminal": {"dark": "TokyoNight Night", "light": "TokyoNight Day"}
        }
        """#

    static let aurora = #"""
        {
          "id": "aurora", "name": "Aurora", "author": "Mothership", "version": 1,
          "summary": "Northern lights rippling green and violet over a still arctic night",
          "tone": "dark", "tags": ["animated", "dark", "night", "vivid"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#03080F", "location": 0}, {"color": "#071526", "location": 0.45}, {"color": "#0B2433", "location": 0.8}, {"color": "#0F3340", "location": 1}],
            "glows": [{"color": "#2BD9A033", "center": {"x": 0.55, "y": 0.3}, "radius": 0.7}],
            "layers": [
              {"kind": "stars", "colors": ["#FFFFFF", "#D8F7FF"], "density": 0.55, "speed": 0.2, "opacity": 0.85},
              {"kind": "aurora", "colors": ["#3CF5A3", "#2FD6C9", "#7B5CFF"], "position": {"x": 0.5, "y": 0.28}, "size": 0.6, "speed": 0.3, "opacity": 0.85},
              {"kind": "grain", "opacity": 0.025}
            ]}},
          "palette": {"attention": "#FF8A33", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#0A141E99"},
          "terminal": {"dark": "Nord", "light": "Nord Light"}
        }
        """#

    static let nebula = #"""
        {
          "id": "nebula", "name": "Nebula", "author": "Mothership", "version": 1,
          "summary": "A magenta stellar nursery glowing slowly in deep space",
          "tone": "dark", "tags": ["animated", "dark", "night", "vivid"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#05020C", "location": 0}, {"color": "#0E0620", "location": 0.4}, {"color": "#180A2E", "location": 0.75}, {"color": "#120824", "location": 1}],
            "glows": [
              {"color": "#C2409A59", "center": {"x": 0.68, "y": 0.32}, "radius": 0.45},
              {"color": "#3A5BD940", "center": {"x": 0.22, "y": 0.62}, "radius": 0.5}
            ],
            "layers": [
              {"kind": "nebula", "colors": ["#C2409A", "#7B3FE0", "#2E6BE6"], "position": {"x": 0.64, "y": 0.36}, "size": 0.7, "speed": 0.06, "opacity": 0.75},
              {"kind": "stars", "colors": ["#FFFFFF", "#E6D9FF", "#FFD6F0"], "density": 0.8, "speed": 0.25, "opacity": 0.9},
              {"kind": "grain", "opacity": 0.03}
            ]}},
          "palette": {"attention": "#FFC233", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#120A1E99"},
          "terminal": {"dark": "Rose Pine Moon", "light": "Rose Pine Dawn"}
        }
        """#

    static let fireflyForest = #"""
        {
          "id": "firefly-forest", "name": "Firefly Forest", "author": "Mothership", "version": 1,
          "summary": "Fireflies drifting between dark pines under a sliver of moonlight",
          "tone": "dark", "tags": ["animated", "dark", "night", "calm"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#050B10", "location": 0}, {"color": "#0A1618", "location": 0.35}, {"color": "#0C1C17", "location": 0.7}, {"color": "#07130D", "location": 1}],
            "glows": [
              {"color": "#6E8FB32E", "center": {"x": 0.72, "y": 0.02}, "radius": 0.55},
              {"color": "#C8F25C14", "center": {"x": 0.35, "y": 0.75}, "radius": 0.5}
            ],
            "layers": [
              {"kind": "stars", "colors": ["#E8F0FF"], "density": 0.3, "speed": 0.2, "opacity": 0.45},
              {"kind": "particles", "particle": "fireflies", "colors": ["#E6FF7A", "#C4F25C", "#FFE873"], "density": 0.32, "speed": 0.12, "size": 0.3, "opacity": 1},
              {"kind": "grain", "opacity": 0.03}
            ]}},
          "palette": {"attention": "#FF8A33", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#0A120E99"},
          "terminal": {"dark": "Everforest Dark Hard", "light": "Everforest Light Med"}
        }
        """#

    static let lunar = #"""
        {
          "id": "lunar", "name": "Lunar", "author": "Mothership", "version": 1,
          "summary": "The Earth rising blue over a grey moonscape, under stars that never twinkle",
          "tone": "dark", "tags": ["still", "dark", "night", "calm"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#000000", "location": 0}, {"color": "#020308", "location": 0.55}, {"color": "#0B0C10", "location": 0.78}, {"color": "#26272C", "location": 0.9}, {"color": "#3A3B41", "location": 1}],
            "glows": [{"color": "#4A8FE033", "center": {"x": 0.2, "y": 0.17}, "radius": 0.16}],
            "layers": [
              {"kind": "stars", "colors": ["#FFFFFF", "#E4ECFF"], "density": 0.9, "speed": 0, "opacity": 0.9},
              {"kind": "moon", "colors": ["#4A8FE0", "#2E6FCF", "#F2F7FF", "#3E9E6A"], "position": {"x": 0.2, "y": 0.17}, "size": 0.13, "opacity": 1},
              {"kind": "grain", "opacity": 0.03}
            ]}},
          "palette": {"attention": "#FF8A33", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#0E0F138C"},
          "terminal": {"dark": "Tomorrow Night", "light": "Tomorrow"}
        }
        """#

    // MARK: Water, fire, weather

    static let deepSea = #"""
        {
          "id": "deep-sea", "name": "Deep Sea", "author": "Mothership", "version": 1,
          "summary": "Light from the surface fading into the deep, with bubbles rising past",
          "tone": "dark", "tags": ["animated", "dark", "calm"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#0B4A66", "location": 0}, {"color": "#073550", "location": 0.3}, {"color": "#042238", "location": 0.65}, {"color": "#020D1C", "location": 1}],
            "glows": [{"color": "#5CC8E64D", "center": {"x": 0.5, "y": -0.08}, "radius": 0.75}],
            "layers": [
              {"kind": "particles", "particle": "dust", "colors": ["#7FD8E8"], "density": 0.25, "speed": 0.05, "direction": 10, "size": 0.12, "opacity": 0.3},
              {"kind": "particles", "particle": "bubbles", "colors": ["#CFF6FF", "#9DE6F5"], "density": 0.3, "speed": 0.25, "direction": 180, "size": 0.45, "opacity": 0.55},
              {"kind": "grain", "opacity": 0.025}
            ]}},
          "palette": {"attention": "#FFB020", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#04182A99"},
          "terminal": {"dark": "Material Ocean", "light": "Iceberg Light"}
        }
        """#

    static let ember = #"""
        {
          "id": "ember", "name": "Ember", "author": "Mothership", "version": 1,
          "summary": "Embers rising from a fire just out of view, glowing on warm black",
          "tone": "dark", "tags": ["animated", "dark", "night", "vivid"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#070403", "location": 0}, {"color": "#120806", "location": 0.45}, {"color": "#22100A", "location": 0.75}, {"color": "#3A170B", "location": 1}],
            "glows": [
              {"color": "#FF6A1F73", "center": {"x": 0.5, "y": 1.08}, "radius": 0.75},
              {"color": "#FF9A3D26", "center": {"x": 0.5, "y": 1.0}, "radius": 0.35}
            ],
            "layers": [
              {"kind": "particles", "particle": "embers", "colors": ["#FFB15C", "#FF7A2E", "#FFD27A"], "density": 0.45, "speed": 0.35, "direction": 182, "size": 0.3, "opacity": 0.95},
              {"kind": "grain", "opacity": 0.035}
            ]}},
          "palette": {"attention": "#3DD6F5", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#120A0799"},
          "terminal": {"dark": "Gruvbox Dark Hard", "light": "Gruvbox Light Hard"}
        }
        """#

    /// Bengaluru in June.
    static let monsoon = #"""
        {
          "id": "monsoon", "name": "Monsoon", "author": "Mothership", "version": 1,
          "summary": "Bengaluru in June: slate clouds and steady rain, nowhere you need to be",
          "tone": "dark", "tags": ["animated", "dark", "seasonal", "calm"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#1A222C", "location": 0}, {"color": "#26303C", "location": 0.4}, {"color": "#323E4B", "location": 0.75}, {"color": "#3D4A57", "location": 1}],
            "glows": [{"color": "#9FB6CC26", "center": {"x": 0.28, "y": -0.05}, "radius": 0.7}],
            "layers": [
              {"kind": "clouds", "colors": ["#4B5967", "#2E3843"], "density": 0.85, "speed": 0.12, "opacity": 0.75},
              {"kind": "particles", "particle": "rain", "colors": ["#B9C8D8", "#8FA3B8"], "density": 0.65, "speed": 0.85, "direction": 12, "size": 0.2, "opacity": 0.55},
              {"kind": "grain", "opacity": 0.025}
            ]}},
          "palette": {"attention": "#FF8A33", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#141A228C"},
          "terminal": {"dark": "Kanagawa Wave", "light": "Kanagawa Lotus"}
        }
        """#

    static let firstSnow = #"""
        {
          "id": "first-snow", "name": "First Snow", "author": "Mothership", "version": 1,
          "summary": "The hush of the first snowfall under a soft white winter sky",
          "tone": "light", "tags": ["animated", "light", "seasonal", "calm"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#9FB3C8", "location": 0}, {"color": "#C9D4E0", "location": 0.5}, {"color": "#E3E9F0", "location": 0.8}, {"color": "#F2F5F8", "location": 1}],
            "glows": [{"color": "#FFFFFF66", "center": {"x": 0.7, "y": 0.12}, "radius": 0.6}],
            "layers": [
              {"kind": "clouds", "colors": ["#DDE4EC", "#C3CEDA"], "density": 0.5, "speed": 0.08, "opacity": 0.45},
              {"kind": "particles", "particle": "snow", "colors": ["#FFFFFF", "#EEF4FB"], "density": 0.5, "speed": 0.18, "direction": 8, "size": 0.45, "opacity": 0.95},
              {"kind": "grain", "opacity": 0.02}
            ]}},
          "palette": {"attention": "#FF7A1A", "danger": "#E5484D", "lightGlass": "#FFFFFF99", "darkGlass": "#1A1F268C"},
          "terminal": {"dark": "Iceberg Dark", "light": "Iceberg Light"}
        }
        """#

    // MARK: Worlds

    static let synthwave = #"""
        {
          "id": "synthwave", "name": "Synthwave", "author": "Mothership", "version": 1,
          "summary": "A striped retro sun setting behind a neon grid that runs to the horizon",
          "tone": "dark", "tags": ["animated", "dark", "night", "vivid"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#0A0119", "location": 0}, {"color": "#1C0538", "location": 0.3}, {"color": "#3E0B58", "location": 0.48}, {"color": "#7A1A6E", "location": 0.6}, {"color": "#12042A", "location": 0.6}, {"color": "#0A0218", "location": 1}],
            "glows": [{"color": "#FF297566", "center": {"x": 0.5, "y": 0.6}, "radius": 0.5}],
            "layers": [
              {"kind": "stars", "colors": ["#FFFFFF", "#FFC6F2"], "density": 0.45, "speed": 0.25, "opacity": 0.7},
              {"kind": "sun", "colors": ["#FFE14D", "#FF8A3D", "#FF2975"], "position": {"x": 0.5, "y": 0.5}, "size": 0.34, "opacity": 1},
              {"kind": "grid", "colors": ["#FF2BD6", "#7A5CFF"], "position": {"x": 0.5, "y": 0.6}, "density": 0.5, "speed": 0.35, "opacity": 0.85},
              {"kind": "grain", "opacity": 0.03}
            ]}},
          "palette": {"attention": "#2DE2E6", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#12062099"},
          "terminal": {"dark": "Synthwave", "light": "Rose Pine Dawn"}
        }
        """#

    static let digitalRain = #"""
        {
          "id": "digital-rain", "name": "Digital Rain", "author": "Mothership", "version": 1,
          "summary": "Green glyphs falling through the dark, faster than you can read them",
          "tone": "dark", "tags": ["animated", "dark", "vivid"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#000000", "location": 0}, {"color": "#010603", "location": 0.5}, {"color": "#02100A", "location": 1}],
            "glows": [{"color": "#00FF661A", "center": {"x": 0.5, "y": 1.1}, "radius": 0.6}],
            "layers": [
              {"kind": "digitalRain", "colors": ["#00FF66", "#33FF8A", "#B9FFD6"], "density": 0.55, "speed": 0.6, "size": 0.35, "opacity": 0.75},
              {"kind": "grain", "opacity": 0.03}
            ]}},
          "palette": {"attention": "#FFB020", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#000A0499"},
          "terminal": {"dark": "Matrix", "light": "GitHub Light Default"}
        }
        """#

    /// Mars sunsets are blue: fine dust scatters blue light forward around the sun.
    static let mars = #"""
        {
          "id": "mars", "name": "Mars", "author": "Mothership", "version": 1,
          "summary": "Dusk on Mars: rust dunes, drifting dust and the planet's strange blue sunset",
          "tone": "dark", "tags": ["animated", "dark", "vivid"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#1C0D0A", "location": 0}, {"color": "#4A2416", "location": 0.35}, {"color": "#8A4426", "location": 0.7}, {"color": "#B8673A", "location": 0.9}, {"color": "#C98451", "location": 1}],
            "glows": [
              {"color": "#7FB2E673", "center": {"x": 0.3, "y": 0.78}, "radius": 0.28},
              {"color": "#E08A5233", "center": {"x": 0.5, "y": 1.0}, "radius": 0.8}
            ],
            "layers": [
              {"kind": "stars", "colors": ["#FFF1E6"], "density": 0.25, "speed": 0.2, "opacity": 0.4},
              {"kind": "sun", "colors": ["#E8F2FF", "#A9CBF0"], "position": {"x": 0.3, "y": 0.78}, "size": 0.035, "opacity": 0.95},
              {"kind": "particles", "particle": "dust", "colors": ["#D9895A", "#B8643A"], "density": 0.35, "speed": 0.3, "direction": 76, "size": 0.2, "opacity": 0.45},
              {"kind": "grain", "opacity": 0.035}
            ]}},
          "palette": {"attention": "#4BE3A0", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#1A0D0999"},
          "terminal": {"dark": "Red Planet", "light": "Gruvbox Light"}
        }
        """#

    static let goldenHour = #"""
        {
          "id": "golden-hour", "name": "Golden Hour", "author": "Mothership", "version": 1,
          "summary": "The last warm hour of the day, held forever: a low sun and peach clouds",
          "tone": "light", "tags": ["animated", "light", "calm", "vivid"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#2E4C8C", "location": 0}, {"color": "#6F7DB8", "location": 0.28}, {"color": "#D99A8E", "location": 0.52}, {"color": "#F4B07A", "location": 0.72}, {"color": "#FFD49A", "location": 0.88}, {"color": "#FFE6C2", "location": 1}],
            "glows": [{"color": "#FFB46AB3", "center": {"x": 0.78, "y": 0.84}, "radius": 0.8}],
            "layers": [
              {"kind": "sun", "colors": ["#FFF0C2", "#FFB14E"], "position": {"x": 0.78, "y": 0.86}, "size": 0.085, "opacity": 1},
              {"kind": "clouds", "colors": ["#FFC9A8", "#F09A8A", "#FFE2C4"], "density": 0.55, "speed": 0.14, "opacity": 0.8},
              {"kind": "grain", "opacity": 0.025}
            ]}},
          "palette": {"attention": "#00B3A4", "danger": "#E5484D", "lightGlass": "#FFFFFF99", "darkGlass": "#1C16148C"},
          "terminal": {"dark": "Flexoki Dark", "light": "Flexoki Light"}
        }
        """#

    // MARK: Minimal

    static let graphite = #"""
        {
          "id": "graphite", "name": "Graphite", "author": "Mothership", "version": 1,
          "summary": "Flat near-black with a whisper of grain: nothing moves but your work",
          "tone": "dark", "tags": ["still", "dark", "minimal"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#17181C", "location": 0}, {"color": "#1C1D21", "location": 0.55}, {"color": "#222429", "location": 1}],
            "layers": [{"kind": "grain", "opacity": 0.02}]}},
          "palette": {"attention": "#FF8A33", "danger": "#F2555A", "lightGlass": "#FFFFFF8C", "darkGlass": "#1F2127A6"},
          "terminal": {"dark": "Ghostty Default Style Dark", "light": "GitHub Light Default"}
        }
        """#

    static let paper = #"""
        {
          "id": "paper", "name": "Paper", "author": "Mothership", "version": 1,
          "summary": "Warm off-white like a good notebook page, with a faint paper tooth",
          "tone": "light", "tags": ["still", "light", "minimal"],
          "backdrop": {"kind": "fixed", "scene": {
            "gradient": [{"color": "#F8F6F1", "location": 0}, {"color": "#F3F0E9", "location": 0.55}, {"color": "#ECE8DF", "location": 1}],
            "layers": [{"kind": "grain", "colors": ["#8A7F6A"], "opacity": 0.04}]}},
          "palette": {"attention": "#FF7A1A", "danger": "#E5484D", "lightGlass": "#FFFFFFA6", "darkGlass": "#1E1D1A8C"},
          "terminal": {"light": "Alabaster"}
        }
        """#

    static let desktop = #"""
        {
          "id": "desktop", "name": "Desktop", "author": "Mothership", "version": 1,
          "summary": "No scene: your wallpaper shows through frosted glass",
          "tone": "auto", "tags": ["still", "light", "dark", "minimal"],
          "backdrop": {"kind": "desktop"},
          "palette": {"attention": "#FF8A33", "danger": "#F2555A", "lightGlass": "#FFFFFFA6", "darkGlass": "#14161BA6"},
          "terminal": {"dark": "Ghostty Default Style Dark", "light": "GitHub Light Default"}
        }
        """#
}
