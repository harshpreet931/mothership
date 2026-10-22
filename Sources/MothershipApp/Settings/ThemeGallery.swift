import AppKit
import BackdropKit
import SwiftUI
import TerminalEngine
import ThemeKit
import UniformTypeIdentifiers

/// Settings → Appearance → Themes: every theme as a card (a still of its scene, a mock of
/// its glass and terminal), filters and search. Hovering a card previews it on the whole
/// window; clicking applies it (⌘Z goes back).
struct ThemeGallery: View {
    let model: AppModel
    @State private var filter: ThemeFilter = .all
    @State private var query = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Themes")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Sky.secondary)
                Spacer()
                Text(currentCaption)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Sky.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 22)
            .onSkyText()
            HStack(spacing: 10) {
                SegmentedPill(items: ThemeFilter.allCases.map { ($0, $0.title) }, selection: $filter, height: 32)
                Spacer(minLength: 8)
                SearchField(text: $query)
            }
            let shown = filtered
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 12) {
                ForEach(shown) { theme in
                    ThemeCard(model: model, theme: theme)
                }
            }
            .onHover { inside in if !inside { model.previewThemeID = nil } }
            if shown.isEmpty {
                Text(query.isEmpty ? "No themes in this filter." : "No themes match “\(query)”.")
                    .font(.system(size: 13))
                    .foregroundStyle(Sky.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .glassPanel(radius: Sky.radiusPane)
            }
            ForEach(model.themeProblems.keys.sorted(), id: \.self) { file in
                ThemeProblemCard(file: file, issue: model.themeProblems[file]?.first(where: { $0.severity == .error }) ?? model.themeProblems[file]?.first)
            }
            fileActions
            if let notice {
                Text(notice)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Sky.secondary)
                    .padding(.horizontal, 22)
                    .onSkyText()
                    .transition(.opacity)
            }
        }
        .animation(Sky.spring, value: filter)
        .onDisappear { model.previewThemeID = nil }
    }

    private var filtered: [ThemeKit.Theme] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.themes.filter { theme in
            filter.includes(theme) && (needle.isEmpty || theme.name.lowercased().contains(needle)
                || theme.summary.lowercased().contains(needle) || theme.tags.contains { $0.contains(needle) })
        }
    }

    private var currentCaption: String {
        let chosen = model.chosenTheme
        if let id = model.previewThemeID, id != chosen.id, let preview = model.theme(id: id) {
            return "Previewing \(preview.name)"
        }
        if model.themeScheduled {
            return "Day and night · now \(chosen.name)"
        }
        return chosen.backdrop.kind == .sunCycle ? "\(chosen.name) · \(model.skyState.phaseName.lowercased())" : chosen.name
    }

    private var fileActions: some View {
        HStack(spacing: 6) {
            Button("Open themes folder") {
                try? FileManager.default.createDirectory(at: AppModel.themesDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(AppModel.themesDirectory)
            }
            Button("Import theme…") { importTheme() }
            Button("Export current theme…") { exportTheme() }
            Spacer()
            Button("Reload") {
                model.reloadThemes()
                show("Reloaded \(model.userThemeIDs.count) of your themes.")
            }
        }
        .buttonStyle(GhostPillStyle(height: 30, foreground: Sky.ink.opacity(0.8)))
        .padding(.horizontal, 10)
        .onSkyText()
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Mothership theme (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = model.importTheme(from: url) {
            show(problem)
        } else {
            show("Imported \(url.deletingPathExtension().lastPathComponent).")
        }
    }

    private func exportTheme() {
        let theme = model.chosenTheme
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = theme.id + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ThemeLibrary.export(theme).write(to: url)
            show("Exported \(theme.name).")
        } catch {
            show("Couldn't export: \(error.localizedDescription)")
        }
    }

    private func show(_ message: String) {
        withAnimation(Sky.hover) { notice = message }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if notice == message { withAnimation(Sky.hover) { notice = nil } }
        }
    }
}

enum ThemeFilter: String, CaseIterable, Hashable {
    case all, animated, still, light, dark

    var title: String {
        switch self {
        case .all: "All"
        case .animated: "Animated"
        case .still: "Still"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    func includes(_ theme: ThemeKit.Theme) -> Bool {
        switch self {
        case .all: true
        case .animated: theme.tags.contains("animated")
        case .still: theme.tags.contains("still") || !theme.tags.contains("animated")
        case .light: theme.tags.contains("light") || theme.tone == .light
        case .dark: theme.tags.contains("dark") || theme.tone == .dark
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Sky.tertiary)
            TextField("Search themes", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Sky.ink)
        }
        .padding(.horizontal, 12)
        .frame(width: 170, height: 32)
        .glassCapsule()
    }
}

/// One theme: its scene's still with a mock of glass and a terminal strip, then name,
/// summary and tags. Hover previews; click applies.
private struct ThemeCard: View {
    let model: AppModel
    let theme: ThemeKit.Theme
    @State private var hovering = false

    private var isChosen: Bool { !model.themeScheduled && model.themeID == theme.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeThumbnail(theme: theme, altitude: model.skyClock.sun.altitude)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Sky.ink.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if theme.backdrop.kind == .sunCycle {
                        Label("Follows the sun", systemImage: "sun.horizon")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(height: 17)
                            .background(Capsule().fill(.black.opacity(0.35)))
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isChosen {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.black.opacity(0.45)))
                            .padding(6)
                    }
                }
                .scaleEffect(hovering ? 1.02 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(theme.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Sky.ink)
                        .lineLimit(1)
                    if model.userThemeIDs.contains(theme.id) {
                        Text("yours").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Sky.tertiary)
                    }
                }
                Text(theme.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Sky.secondary)
                    .lineLimit(2, reservesSpace: true)
                HStack(spacing: 4) {
                    ForEach(theme.tags.filter { $0 != "light" && $0 != "dark" }.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Sky.secondary)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Capsule().fill(Sky.ink.opacity(0.07)))
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            shape.fill(Sky.glassFill).overlay(shape.fill(Sky.ink.opacity(hovering ? 0.05 : 0)))
        }
        .overlay {
            // The chosen theme gets a ring rather than a fill, so its card reads the same on
            // every sky.
            if isChosen {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Sky.ink.opacity(0.85), lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { inside in
            withAnimation(Sky.hover) { hovering = inside }
            if inside { model.previewThemeID = theme.id } else if model.previewThemeID == theme.id { model.previewThemeID = nil }
        }
        .onTapGesture {
            model.applyTheme(theme.id, undoManager: NSApp.keyWindow?.undoManager ?? NSApp.mainWindow?.undoManager)
        }
        .contextMenu {
            Button("Use \(theme.name)") { model.applyTheme(theme.id, undoManager: NSApp.mainWindow?.undoManager) }
            Button("Use as Day Theme") {
                model.dayThemeID = theme.id
                model.themeScheduled = true
            }
            Button("Use as Night Theme") {
                model.nightThemeID = theme.id
                model.themeScheduled = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(theme.name). \(theme.summary)")
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// The still for a theme card (BackdropKit's render; the scene's gradient until it's
/// ready), with a mock of the theme's glass and its paired terminal.
struct ThemeThumbnail: View {
    let theme: ThemeKit.Theme
    let altitude: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                if let image = ThemeThumbnailCache.shared.image(for: theme, altitude: altitude) {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let scene = ThemeLibrary.scene(for: theme, sunAltitude: altitude) {
                    // No still (no renderer): the scene's gradient.
                    LinearGradient(
                        stops: scene.gradient.map { Gradient.Stop(color: $0.color.color, location: $0.location) },
                        startPoint: .top, endPoint: .bottom
                    )
                } else {
                    // Desktop: frosted wallpaper stand-in.
                    LinearGradient(colors: [Color(white: 0.62), Color(white: 0.78)], startPoint: .top, endPoint: .bottom)
                        .overlay(Image(systemName: "macwindow").font(.system(size: 18)).foregroundStyle(.white.opacity(0.85)))
                }
                mock(size: geometry.size)
            }
        }
    }

    /// A sliver of glass (sidebar) and a terminal strip, in the theme's tone and pairing.
    private func mock(size: CGSize) -> some View {
        let dark = ThemeThumbnailCache.isDarkTone(theme, altitude: altitude)
        let glass = (dark ? theme.palette.darkGlass : theme.palette.lightGlass).color
        let ink: Color = dark ? .white : Color(nsColor: NSColor(srgbRed: 0.05, green: 0.055, blue: 0.067, alpha: 1))
        let terminal = ThemeThumbnailCache.terminalColors(theme, dark: dark)
        return HStack(alignment: .bottom, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(ink.opacity(0.8)).frame(width: size.width * 0.14, height: 3)
                Capsule().fill(ink.opacity(0.4)).frame(width: size.width * 0.1, height: 3)
                Capsule().fill(theme.palette.attention.color).frame(width: 5, height: 5)
            }
            .padding(6)
            .frame(width: size.width * 0.26, height: size.height * 0.52, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(glass))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(terminal.accents.prefix(3).enumerated()), id: \.offset) { index, accent in
                    Capsule().fill(accent).frame(width: size.width * [0.22, 0.32, 0.16][index], height: 3)
                }
                Capsule().fill(terminal.foreground.opacity(0.7)).frame(width: size.width * 0.26, height: 3)
            }
            .padding(6)
            .frame(width: size.width * 0.58, height: size.height * 0.52, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(terminal.background))
        }
        .padding(6)
    }
}

/// Theme stills, rendered once (per sun phase for sun-cycle themes).
///
/// Rendering flushes a Core Animation transaction, which runs AppKit's layout and would
/// re-enter SwiftUI if it happened inside a view update. So a card only asks for its still;
/// they render one per run loop turn, outside any update, and cards redraw as each arrives.
@MainActor
@Observable
final class ThemeThumbnailCache {
    static let shared = ThemeThumbnailCache()
    private var images: [String: CGImage] = [:]
    @ObservationIgnored private var queue: [(key: String, scene: ThemeKit.Scene)] = []
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var rendering = false

    /// The still if it's ready; otherwise nil, and it's on its way.
    func image(for theme: ThemeKit.Theme, altitude: Double) -> CGImage? {
        guard theme.backdrop.kind != .desktop else { return nil }
        // Sun-cycle stills only change by phase; 4° steps keep the cache small.
        let key = theme.backdrop.kind == .sunCycle ? "\(theme.id)#\(Int((altitude / 4).rounded()))" : theme.id
        if let cached = images[key] { return cached }
        guard !requested.contains(key), let scene = ThemeLibrary.scene(for: theme, sunAltitude: altitude) else { return nil }
        requested.insert(key)
        queue.append((key, scene))
        if !rendering {
            rendering = true
            DispatchQueue.main.async { MainActor.assumeIsolated { ThemeThumbnailCache.shared.renderNext() } }
        }
        return nil
    }

    private func renderNext() {
        guard !queue.isEmpty else {
            rendering = false
            return
        }
        let (key, scene) = queue.removeFirst()
        if let image = BackdropView.renderImage(of: scene, size: CGSize(width: 320, height: 200), scale: 2)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) {
            images[key] = image
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { ThemeThumbnailCache.shared.renderNext() } }
    }

    /// The chrome tone a theme shows in its card (auto: by the scene's own brightness).
    static func isDarkTone(_ theme: ThemeKit.Theme, altitude: Double) -> Bool {
        switch theme.tone {
        case .dark: return true
        case .light: return false
        case .auto: return ThemeLibrary.scene(for: theme, sunAltitude: altitude)?.isDark ?? true
        }
    }

    static func terminalColors(_ theme: ThemeKit.Theme, dark: Bool) -> (background: Color, foreground: Color, accents: [Color]) {
        let name = dark ? (theme.terminal?.dark ?? theme.terminal?.light) : (theme.terminal?.light ?? theme.terminal?.dark)
        if let name, let colors = TerminalRuntime.previewColors(for: .named(name), dark: dark) {
            return (Color(nsColor: colors.background), Color(nsColor: colors.foreground), colors.accents.map { Color(nsColor: $0) })
        }
        return dark
            ? (Color(white: 0.08), Color(white: 0.85), [Color.red, Color.green, Color.blue].map { $0.opacity(0.8) })
            : (Color(white: 0.97), Color(white: 0.2), [Color.red, Color.green, Color.blue].map { $0.opacity(0.7) })
    }
}

/// A user theme that didn't load, shown quietly with its first problem.
private struct ThemeProblemCard: View {
    let file: String
    let issue: ThemeIssue?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(Sky.attention)
            VStack(alignment: .leading, spacing: 2) {
                Text(file).font(Sky.Font.meta).foregroundStyle(Sky.ink)
                Text(issue?.message ?? "Couldn't be loaded.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Sky.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassPanel(radius: Sky.radiusPane)
    }
}
