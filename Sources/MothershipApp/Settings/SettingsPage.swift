import ShipModel
import SwiftUI
import TerminalEngine

/// Settings as Hark's Accounts page (§6): back circle + 34 pt title, a segmented pill, and
/// inset grouped glass lists with tall rows and trailing pills.
struct SettingsPage: View {
    let model: AppModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    CircleButton(symbol: "chevron.left", size: 44, label: "Back") { model.show(.workspaces) }
                    Text("Settings")
                        .font(Sky.Font.displayL)
                        .foregroundStyle(Sky.ink)
                        .onSkyText()
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        MothershipLockup(fontSize: 17)
                        Text("v\(ShipInfo.version)")
                            .font(Sky.Font.meta)
                            .foregroundStyle(Sky.tertiary)
                    }
                    .onSkyText()
                }
                SegmentedPill(
                    items: SettingsTab.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 }),
                    height: 44, segmentWidth: (640 - 6) / CGFloat(SettingsTab.allCases.count)
                )
                Group {
                    switch model.settingsTab {
                    case .general: GeneralSettings()
                    case .agents: AgentsSettings(model: model)
                    case .appearance: AppearanceSettings(model: model)
                    case .notifications: NotificationSettings()
                    case .keys: KeysSettings()
                    }
                }
                .transition(.opacity)
            }
            .frame(width: 640)
            .padding(.top, 36)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .bottomFade()
        .animation(Sky.spring, value: model.settingsTab)
    }
}

/// Frosted inset grouped list with hairlines inset on both sides.
struct GlassList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 6)
        .glassPanel()
    }
}

struct GlassListRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var showsDivider = true
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                leading
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15))
                        .foregroundStyle(Sky.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Sky.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .frame(minHeight: 64)
            if showsDivider {
                Rectangle().fill(Sky.hairline).frame(height: 1)
            }
        }
    }
}

// MARK: Agents

struct AgentsSettings: View {
    let model: AppModel
    @State private var pending: IntegrationChange?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassList {
                if model.integrations.isEmpty {
                    GlassListRow(title: "No agents found", subtitle: "Install Claude Code, Codex, OpenCode or Gemini CLI, then come back.", showsDivider: false) {
                        AgentMark(kind: .claude, size: 20, color: Sky.tertiary)
                    } trailing: { EmptyView() }
                }
                ForEach(Array(model.integrations.enumerated()), id: \.element.id) { index, status in
                    GlassListRow(
                        title: status.kind.displayName, subtitle: subtitle(status),
                        showsDivider: index < model.integrations.count - 1
                    ) {
                        AgentMark(kind: status.kind, size: 20)
                            .frame(width: 24)
                    } trailing: {
                        trailing(status)
                    }
                }
            }
            Text("Hooks let Mothership see exactly what each agent is doing and answer permission prompts where you are. Nothing changes without your confirmation; every change is backed up first.")
                .font(.system(size: 12.5))
                .foregroundStyle(Sky.secondary)
                .padding(.horizontal, 22)
                .onSkyText()
        }
        .sheet(item: $pending) { change in
            IntegrationConsentSheet(model: model, change: change) { pending = nil }
        }
    }

    private func subtitle(_ status: IntegrationStatus) -> String {
        guard status.executablePath != nil else { return "Not installed on this Mac" }
        return [status.detail, status.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func needsRepair(_ status: IntegrationStatus) -> Bool {
        let detail = status.detail.lowercased()
        return detail.contains("overwritten") || detail.contains("broken") || detail.contains("repair")
    }

    @ViewBuilder
    private func trailing(_ status: IntegrationStatus) -> some View {
        if status.unsupportedReason != nil, !status.installed {
            Text("Unsupported")
                .font(.system(size: 13))
                .foregroundStyle(Sky.tertiary)
        } else if needsRepair(status) {
            Button("Repair") { pending = IntegrationChange(kind: status.kind, install: true) }
                .buttonStyle(SecondaryPillStyle(height: 30, foreground: Sky.attention))
        } else if status.installed {
            Button {
                pending = IntegrationChange(kind: status.kind, install: false)
            } label: {
                HStack(spacing: 5) {
                    Text("Connected")
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(GhostPillStyle(height: 30, foreground: Sky.ink.opacity(0.7)))
            .help("Disconnect…")
        } else {
            Button("Connect") { pending = IntegrationChange(kind: status.kind, install: true) }
                .buttonStyle(SecondaryPillStyle(height: 30))
                .disabled(status.executablePath == nil)
                .opacity(status.executablePath == nil ? 0.45 : 1)
        }
    }
}

// MARK: Appearance

struct AppearanceSettings: View {
    let model: AppModel
    @State private var fontSize: Float = 13
    @State private var themeChoice: TerminalThemeChoice = .automatic

    private static let popularThemes = [
        "Catppuccin Mocha", "Catppuccin Latte", "TokyoNight", "Dracula", "Nord", "Gruvbox Dark",
        "Rose Pine", "One Dark Two", "GitHub Dark", "GitHub Light Default", "Solarized Dark Higher Contrast", "Everforest Dark Hard",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ThemeGallery(model: model)
            GlassList {
                GlassListRow(title: "Day and night themes", subtitle: model.themeScheduled
                    ? "Switches at sunrise and sunset, like macOS appearance"
                    : "Switch between two themes at sunrise and sunset") {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 15)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Toggle("", isOn: Binding(get: { model.themeScheduled }, set: { model.themeScheduled = $0 }))
                        .toggleStyle(SkySwitchStyle())
                }
                if model.themeScheduled {
                    GlassListRow(title: "By day", subtitle: nil) {
                        Image(systemName: "sun.max").font(.system(size: 15)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                    } trailing: {
                        ThemeMenu(model: model, selection: Binding(get: { model.dayThemeID }, set: { model.dayThemeID = $0 }))
                    }
                    GlassListRow(title: "At night", subtitle: nil) {
                        Image(systemName: "moon").font(.system(size: 15)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                    } trailing: {
                        ThemeMenu(model: model, selection: Binding(get: { model.nightThemeID }, set: { model.nightThemeID = $0 }))
                    }
                }
                GlassListRow(title: "Use the theme's terminal colors", subtitle: themeTerminalSubtitle) {
                    Image(systemName: "terminal").font(.system(size: 15)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Toggle("", isOn: Binding(get: { model.usesThemeTerminal }, set: { model.usesThemeTerminal = $0 }))
                        .toggleStyle(SkySwitchStyle())
                }
                GlassListRow(title: "Animate sky", subtitle: "Twinkling stars and drifting clouds. Rests while hidden, on Low Power or with Reduce Motion.") {
                    Image(systemName: "sparkles").font(.system(size: 16)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Toggle("", isOn: Binding(get: { model.skyClock.animates }, set: { model.skyClock.animates = $0 }))
                        .toggleStyle(SkySwitchStyle())
                }
                GlassListRow(title: "Use my location", subtitle: model.skyClock.locationNote ?? "Places the sun exactly. Otherwise it's guessed from your time zone.", showsDivider: false) {
                    Image(systemName: "location").font(.system(size: 16)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Toggle("", isOn: Binding(get: { model.skyClock.usesLocation }, set: { model.skyClock.usesLocation = $0 }))
                        .toggleStyle(SkySwitchStyle())
                }
            }
            GlassList {
                GlassListRow(title: "Terminal theme", subtitle: themeSubtitle) {
                    Image(systemName: "paintpalette").font(.system(size: 16)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Menu {
                        Button(model.runtime.userConfigHasTheme ? "From Ghostty config" : "Automatic") { apply(.automatic) }
                        Button("Mothership") { apply(.mothership) }
                        Section("Popular") {
                            ForEach(Self.popularThemes.filter { TerminalRuntime.availableThemeNames.contains($0) }, id: \.self) { name in
                                Button(name) { apply(.named(name)) }
                            }
                        }
                        Menu("All \(TerminalRuntime.availableThemeNames.count) themes") {
                            ForEach(TerminalRuntime.availableThemeNames, id: \.self) { name in
                                Button(name) { apply(.named(name)) }
                            }
                        }
                    } label: {
                        Text(themeLabel)
                            .font(Sky.Font.label)
                            .foregroundStyle(Sky.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Capsule().fill(Sky.pillSecondary))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                GlassListRow(title: "Font size", subtitle: model.runtime.hasFontSizeOverride ? "Set here" : "From your Ghostty config") {
                    Image(systemName: "textformat.size").font(.system(size: 16)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    HStack(spacing: 10) {
                        CircleButton(symbol: "minus", size: 30, label: "Smaller") { setFont(fontSize - 1) }
                        Text("\(Int(fontSize)) pt")
                            .font(Sky.Font.meta)
                            .foregroundStyle(Sky.ink)
                            .frame(width: 44)
                        CircleButton(symbol: "plus", size: 30, label: "Larger") { setFont(fontSize + 1) }
                    }
                }
                GlassListRow(title: "Terminal follows the sky", subtitle: followsSkySubtitle) {
                    Image(systemName: "sun.horizon").font(.system(size: 15)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Toggle("", isOn: Binding(get: { model.terminalFollowsSky }, set: { model.terminalFollowsSky = $0 }))
                        .toggleStyle(SkySwitchStyle())
                        .disabled(model.terminalDayTheme == nil && !model.terminalFollowsSky)
                }
                GlassListRow(title: "Tint terminals with sky", subtitle: "Cards at 88 % with a blur, for more atmosphere") {
                    Image(systemName: "cloud").font(.system(size: 16)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Toggle("", isOn: Binding(get: { model.tintWithSky }, set: { model.tintWithSky = $0 }))
                        .toggleStyle(SkySwitchStyle())
                }
                GlassListRow(title: "Composer pill", subtitle: "A slim pill at the bottom; ⌘L opens the composer either way", showsDivider: false) {
                    Image(systemName: "text.bubble").font(.system(size: 16)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Toggle("", isOn: Binding(get: { model.isComposerVisible }, set: { model.isComposerVisible = $0 }))
                        .toggleStyle(SkySwitchStyle())
                }
            }
        }
        .onAppear {
            fontSize = model.runtime.fontSize
            themeChoice = model.baseThemeChoice
        }
    }

    /// "By day, Catppuccin Mocha becomes Catppuccin Latte", or why it can't.
    private var followsSkySubtitle: String {
        _ = themeChoice
        let base = model.baseThemeName ?? "your theme"
        guard let light = model.terminalDayTheme else { return "No light sibling known for \(base)" }
        return "By day, \(base) becomes \(light); the chrome follows"
    }

    private var themeTerminalSubtitle: String {
        let theme = model.chosenTheme
        guard let pairing = theme.terminal, pairing.dark != nil || pairing.light != nil else { return "\(theme.name) doesn't suggest terminal colors" }
        let names = [pairing.dark, pairing.light].compactMap { $0 }.joined(separator: " / ")
        return model.usesThemeTerminal ? "\(names), from \(theme.name)" : "\(names); off keeps your own"
    }

    private var themeLabel: String {
        switch themeChoice {
        case .automatic: model.runtime.userConfigHasTheme ? "Ghostty config" : "Automatic"
        case .mothership: "Mothership"
        case .named(let name): name
        }
    }

    private var themeSubtitle: String {
        model.runtime.userConfigPath.map { "Fonts and colors from \(PathDisplay.abbreviated($0))" } ?? "Mothership defaults"
    }

    private func apply(_ choice: TerminalThemeChoice) {
        themeChoice = choice
        model.baseThemeChoice = choice
        model.runtime.themeChoice = choice
        model.applyTerminalTheme()
        PreferenceStore.defaults.set(choice.storageValue, forKey: PreferenceKey.theme)
    }

    private func setFont(_ size: Float) {
        model.runtime.setFontSize(size)
        fontSize = model.runtime.fontSize
        PreferenceStore.defaults.set(Double(fontSize), forKey: PreferenceKey.fontSize)
    }
}

/// A compact theme picker (the day/night schedule).
struct ThemeMenu: View {
    let model: AppModel
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(model.themes) { theme in
                Button {
                    selection = theme.id
                } label: {
                    if theme.id == selection { Label(theme.name, systemImage: "checkmark") } else { Text(theme.name) }
                }
            }
        } label: {
            Text(model.theme(id: selection)?.name ?? selection)
                .font(Sky.Font.label)
                .foregroundStyle(Sky.ink)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(Sky.pillSecondary))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: General

struct GeneralSettings: View {
    @AppStorage(PreferenceKey.keepSessionsAlive, store: PreferenceStore.defaults) private var keepAlive = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassList {
                GlassListRow(
                    title: "Keep sessions running when Mothership quits",
                    subtitle: "Shells and agents keep working in the background; reopening picks up right where they are.",
                    showsDivider: false
                ) {
                    Image(systemName: "moon.zzz").font(.system(size: 15)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Toggle("", isOn: $keepAlive).toggleStyle(SkySwitchStyle())
                }
            }
            Text(keepAlive
                ? "Turn this off to end every shell and agent when you quit."
                : "Quitting ends every shell and agent, like closing a terminal window.")
                .font(.system(size: 12.5))
                .foregroundStyle(Sky.secondary)
                .padding(.horizontal, 22)
                .onSkyText()
        }
    }
}

// MARK: Notifications

struct NotificationSettings: View {
    @AppStorage(PreferenceKey.Notifications.enabled, store: PreferenceStore.defaults) private var enabled = true
    @AppStorage(PreferenceKey.Notifications.permissionRequests, store: PreferenceStore.defaults) private var permissions = true
    @AppStorage(PreferenceKey.Notifications.needsInput, store: PreferenceStore.defaults) private var needsInput = true
    @AppStorage(PreferenceKey.Notifications.finished, store: PreferenceStore.defaults) private var finished = true
    @AppStorage(PreferenceKey.Notifications.failed, store: PreferenceStore.defaults) private var failed = true
    @AppStorage(PreferenceKey.Notifications.terminalNotifications, store: PreferenceStore.defaults) private var terminal = true
    @AppStorage(PreferenceKey.Notifications.sound, store: PreferenceStore.defaults) private var sound = true
    @AppStorage(PreferenceKey.Notifications.dockBadge, store: PreferenceStore.defaults) private var dockBadge = true
    @AppStorage(PreferenceKey.Notifications.whenVisible, store: PreferenceStore.defaults) private var whenVisible = false
    @AppStorage(PreferenceKey.Notifications.externalAgents, store: PreferenceStore.defaults) private var externalAgents = false

    var body: some View {
        GlassList {
            row("Notifications", "Never about the pane you're looking at", "bell", $enabled)
            row("Permission requests", "Allow or deny from the banner", "hand.raised", $permissions)
            row("Waiting for you", "An agent asked a question", "questionmark.bubble", $needsInput)
            row("Finished", "An agent ended its turn", "checkmark.circle", $finished)
            row("Failed", "An agent hit an error", "exclamationmark.triangle", $failed)
            row("Terminal notifications", "OSC 9 / 99 / 777 from any program", "terminal", $terminal)
            row("Sounds", nil, "speaker.wave.2", $sound)
            row("Dock badge", "Count of agents that need you", "app.badge", $dockBadge)
            row("Even when visible", "Also when the pane is on screen but Mothership is in the background", "eye", $whenVisible)
            row("Agents running outside Mothership", "Claude, Codex and friends in other terminals or editors", "rectangle.on.rectangle", $externalAgents, divider: false)
        }
    }

    private func row(_ title: String, _ subtitle: String?, _ symbol: String, _ binding: Binding<Bool>, divider: Bool = true) -> some View {
        GlassListRow(title: title, subtitle: subtitle, showsDivider: divider) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
        } trailing: {
            Toggle("", isOn: binding).toggleStyle(SkySwitchStyle())
        }
        .opacity(binding.wrappedValue || title == "Notifications" ? 1 : 0.85)
    }
}

// MARK: Keys

struct KeysSettings: View {
    var body: some View {
        let commands = AppCommand.allCases.filter { $0.shortcutLabel != nil }
        GlassList {
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                GlassListRow(title: command.title.replacingOccurrences(of: "…", with: ""), showsDivider: index < commands.count - 1) {
                    Image(systemName: command.symbol).font(.system(size: 14)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.7))
                } trailing: {
                    Text(command.shortcutLabel ?? "")
                        .font(Sky.Font.meta)
                        .foregroundStyle(Sky.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(Sky.recess))
                }
            }
        }
    }
}
