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
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        MothershipLockup(fontSize: 17)
                        Text("v\(ShipInfo.version)")
                            .font(Sky.Font.meta)
                            .foregroundStyle(Sky.tertiary)
                    }
                }
                SegmentedPill(
                    items: SettingsTab.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 }),
                    height: 44, segmentWidth: (640 - 6) / 4
                )
                Group {
                    switch model.settingsTab {
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
            VStack(alignment: .leading, spacing: 12) {
                Text("Sky")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Sky.secondary)
                    .padding(.leading, 22)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(SkyPreset.allCases, id: \.self) { preset in
                            SkySwatch(preset: preset, current: model.skyState, selected: model.skyPreset == preset) {
                                withAnimationIfAllowed { model.skyPreset = preset }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                    Text(skyCaption)
                        .font(.system(size: 13))
                        .foregroundStyle(Sky.secondary)
                        .padding(.bottom, 16)
                    Rectangle().fill(Sky.hairline).frame(height: 1).padding(.horizontal, 22)
                    GlassListRow(title: "Animate sky", subtitle: "Twinkling stars and drifting clouds. Rests while hidden, on Low Power or with Reduce Motion.") {
                        Image(systemName: "sparkles").font(.system(size: 16)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                    } trailing: {
                        Toggle("", isOn: Binding(get: { model.skyClock.animates }, set: { model.skyClock.animates = $0 }))
                            .toggleStyle(.switch).labelsHidden().tint(Sky.accentToggle)
                    }
                    .padding(.horizontal, 22)
                    GlassListRow(title: "Use my location", subtitle: model.skyClock.locationNote ?? "Places the sun exactly. Otherwise it's guessed from your time zone.", showsDivider: false) {
                        Image(systemName: "location").font(.system(size: 16)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                    } trailing: {
                        Toggle("", isOn: Binding(get: { model.skyClock.usesLocation }, set: { model.skyClock.usesLocation = $0 }))
                            .toggleStyle(.switch).labelsHidden().tint(Sky.accentToggle)
                    }
                    .padding(.horizontal, 22)
                }
                .glassPanel()
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
                GlassListRow(title: "Tint terminals with sky", subtitle: "Cards at 88 % with a blur, for more atmosphere") {
                    Image(systemName: "cloud").font(.system(size: 16)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Toggle("", isOn: Binding(get: { model.tintWithSky }, set: { model.tintWithSky = $0 }))
                        .toggleStyle(.switch).labelsHidden().tint(Sky.accentToggle)
                }
                GlassListRow(title: "Composer", subtitle: "The message bar under the panes (⌘L)", showsDivider: false) {
                    Image(systemName: "text.bubble").font(.system(size: 16)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
                } trailing: {
                    Toggle("", isOn: Binding(get: { model.isComposerVisible }, set: { model.isComposerVisible = $0 }))
                        .toggleStyle(.switch).labelsHidden().tint(Sky.accentToggle)
                }
            }
        }
        .onAppear {
            fontSize = model.runtime.fontSize
            themeChoice = model.runtime.themeChoice
        }
    }

    private var skyCaption: String {
        let state = model.skyState
        switch model.skyPreset {
        case .auto: return "Following the sun · \(state.phaseName.lowercased())"
        case .desktop: return "Your wallpaper, blurred"
        case .graphite: return "Flat and quiet"
        case .day, .dusk, .night: return "Always \(model.skyPreset.title.lowercased())"
        }
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
        model.runtime.themeChoice = choice
        UserDefaults.standard.set(choice.storageValue, forKey: PreferenceKey.theme)
    }

    private func setFont(_ size: Float) {
        model.runtime.setFontSize(size)
        fontSize = model.runtime.fontSize
        UserDefaults.standard.set(Double(fontSize), forKey: PreferenceKey.fontSize)
    }
}

/// A sky preset as a circle; the selected one gets a ring. "Sun" shows the sky right now.
struct SkySwatch: View {
    let preset: SkyPreset
    let current: SkyState
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    switch preset {
                    case .desktop:
                        Circle().fill(.ultraThinMaterial)
                        Circle().fill(Sky.glassFill)
                        Image(systemName: "macwindow").font(.system(size: 14)).foregroundStyle(Sky.secondary)
                    case .auto:
                        Circle().fill(LinearGradient(colors: [current.palette.top.color, current.palette.middle.color, current.palette.horizon.color], startPoint: .top, endPoint: .bottom))
                        Image(systemName: current.palette.stars > 0.5 ? "moon.stars.fill" : "sun.max.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    default:
                        Circle().fill(LinearGradient(colors: preset.swatch, startPoint: .top, endPoint: .bottom))
                    }
                }
                .frame(width: 48, height: 48)
                .overlay(Circle().strokeBorder(Sky.ink.opacity(0.1), lineWidth: 1))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Sky.ink : .clear, lineWidth: 2))
                Text(preset.shortTitle)
                    .font(Sky.Font.label)
                    .foregroundStyle(selected ? Sky.ink : Sky.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset == .auto ? "Sky follows the sun" : "\(preset.title) sky")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Notifications

struct NotificationSettings: View {
    @AppStorage(PreferenceKey.Notifications.enabled) private var enabled = true
    @AppStorage(PreferenceKey.Notifications.permissionRequests) private var permissions = true
    @AppStorage(PreferenceKey.Notifications.needsInput) private var needsInput = true
    @AppStorage(PreferenceKey.Notifications.finished) private var finished = true
    @AppStorage(PreferenceKey.Notifications.failed) private var failed = true
    @AppStorage(PreferenceKey.Notifications.terminalNotifications) private var terminal = true
    @AppStorage(PreferenceKey.Notifications.sound) private var sound = true
    @AppStorage(PreferenceKey.Notifications.dockBadge) private var dockBadge = true
    @AppStorage(PreferenceKey.Notifications.whenVisible) private var whenVisible = false

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
            row("Even when visible", "Also when the pane is on screen but Mothership is in the background", "eye", $whenVisible, divider: false)
        }
    }

    private func row(_ title: String, _ subtitle: String?, _ symbol: String, _ binding: Binding<Bool>, divider: Bool = true) -> some View {
        GlassListRow(title: title, subtitle: subtitle, showsDivider: divider) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 24).foregroundStyle(Sky.ink.opacity(0.75))
        } trailing: {
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden().tint(Sky.accentToggle)
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
