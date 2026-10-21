import AppKit
import ShipModel
import SwiftUI
import TerminalEngine

/// Native preferences window: toolbar tabs, each a SwiftUI pane.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        func add(_ title: String, _ symbol: String, _ view: some View) {
            let controller = NSHostingController(rootView: view.frame(width: 560).fixedSize(horizontal: false, vertical: true))
            controller.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("General", "gearshape", GeneralSettingsView(model: model))
        add("Integrations", "puzzlepiece.extension", IntegrationsSettingsView(model: model))
        add("Notifications", "bell.badge", NotificationSettingsView())

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = "General"
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: General

struct GeneralSettingsView: View {
    let model: AppModel
    @State private var fontSize: Double = 13
    @State private var themeChoice: TerminalThemeChoice = .automatic
    @State private var themeQuery = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Font size") {
                    HStack(spacing: 10) {
                        Slider(value: $fontSize, in: 8 ... 32, step: 1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller")
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .frame(width: 220)
                        Text("\(Int(fontSize)) pt")
                            .font(.body.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .onChange(of: fontSize) { _, value in
                    guard Float(value) != model.runtime.fontSize else { return }
                    model.runtime.setFontSize(Float(value))
                    UserDefaults.standard.set(value, forKey: PreferenceKey.fontSize)
                }
                if model.runtime.hasFontSizeOverride {
                    Button("Use size from Ghostty config") {
                        model.runtime.resetFontSize()
                        UserDefaults.standard.set(0, forKey: PreferenceKey.fontSize)
                        fontSize = Double(model.runtime.fontSize)
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("Terminal")
            } footer: {
                configFooter
            }

            Section("Theme") {
                Picker("Colors", selection: $themeChoice) {
                    Text(model.runtime.userConfigHasTheme ? "From Ghostty config" : "Automatic").tag(TerminalThemeChoice.automatic)
                    Text("Mothership").tag(TerminalThemeChoice.mothership)
                    if case .named(let name) = themeChoice {
                        Text(name).tag(themeChoice)
                    }
                }
                .onChange(of: themeChoice) { _, choice in apply(choice) }
                TextField("Search 480+ themes", text: $themeQuery)
                    .textFieldStyle(.roundedBorder)
                ThemeGrid(query: themeQuery, selection: $themeChoice)
                    .frame(height: 220)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            fontSize = Double(model.runtime.fontSize)
            themeChoice = model.runtime.themeChoice
        }
    }

    @ViewBuilder private var configFooter: some View {
        if let path = model.runtime.userConfigPath {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fonts and colors come from \(PathDisplay.abbreviated(path)).")
                if let issue = model.runtime.configurationIssue {
                    Label("Some settings in that file couldn't be applied: \(issue)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            }
        } else {
            Text("No Ghostty config found; using Mothership defaults.")
        }
    }

    private func apply(_ choice: TerminalThemeChoice) {
        model.runtime.themeChoice = choice
        UserDefaults.standard.set(choice.storageValue, forKey: PreferenceKey.theme)
    }
}

private struct ThemeGrid: View {
    let query: String
    @Binding var selection: TerminalThemeChoice
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let names = TerminalRuntime.availableThemeNames.filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ThemeSwatch(name: "Mothership", choice: .mothership, selected: selection == .mothership, dark: colorScheme == .dark) {
                    selection = .mothership
                }
                ForEach(names, id: \.self) { name in
                    let choice = TerminalThemeChoice.named(name)
                    ThemeSwatch(name: name, choice: choice, selected: selection == choice, dark: colorScheme == .dark) {
                        selection = choice
                    }
                }
            }
            .padding(2)
        }
    }
}

private struct ThemeSwatch: View {
    let name: String
    let choice: TerminalThemeChoice
    let selected: Bool
    let dark: Bool
    let action: () -> Void

    var body: some View {
        let colors = TerminalRuntime.previewColors(for: choice, dark: dark)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text("~ $ ls")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(nsColor: colors?.foreground ?? .textColor))
                HStack(spacing: 3) {
                    ForEach(Array((colors?.accents ?? []).enumerated()), id: \.offset) { _, color in
                        Circle().fill(Color(nsColor: color)).frame(width: 7, height: 7)
                    }
                }
                Spacer(minLength: 0)
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: colors?.foreground ?? .textColor).opacity(0.8))
                    .lineLimit(1)
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(Color(nsColor: colors?.background ?? .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Palette.accent : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Integrations

struct IntegrationsSettingsView: View {
    let model: AppModel
    @State private var pending: PendingChange?
    @State private var working: AgentKind?
    @State private var errorMessage: String?

    struct PendingChange: Identifiable {
        var id: String { kind.rawValue + (install ? "+" : "-") }
        let kind: AgentKind
        let install: Bool
    }

    var body: some View {
        Form {
            Section {
                if model.integrations.isEmpty {
                    Text("The agent engine hasn't reported any integrations yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.integrations) { status in
                    IntegrationRow(status: status, busy: working == status.kind) {
                        pending = PendingChange(kind: status.kind, install: !status.installed)
                    }
                }
            } header: {
                Text("Agent hooks")
            } footer: {
                Text("Hooks let Mothership see exactly what each agent is doing and answer permission prompts from the sidebar. Nothing is changed without your confirmation, and every change is backed up first.")
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .alert(item: $pending) { change in
            Alert(
                title: Text("\(change.install ? "Install" : "Remove") \(change.kind.displayName) integration?"),
                message: Text(Self.explanation(for: change.kind, install: change.install)),
                primaryButton: .default(Text(change.install ? "Install" : "Remove")) { perform(change) },
                secondaryButton: .cancel()
            )
        }
    }

    private func perform(_ change: PendingChange) {
        working = change.kind
        errorMessage = nil
        Task {
            do {
                if change.install {
                    try await model.installIntegration(change.kind)
                } else {
                    try await model.uninstallIntegration(change.kind)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            working = nil
        }
    }

    static func explanation(for kind: AgentKind, install: Bool) -> String {
        let file = switch kind {
        case .claude: "~/.claude/settings.json (the \"hooks\" section)"
        case .codex: "~/.codex/hooks.json"
        case .opencode: "a plugin file in ~/.config/opencode/plugins/"
        case .gemini: "~/.gemini/settings.json (the \"hooks\" section)"
        default: "the agent's configuration"
        }
        let shim = PathDisplay.abbreviated(ShipPaths.cliShim.path)
        if install {
            return "Mothership will add entries to \(file) that run \(shim) hook \(kind.rawValue) <event>. Existing settings and other tools' hooks are kept, and a timestamped backup is saved to \(PathDisplay.abbreviated(ShipPaths.backups.path)) first."
        }
        return "Mothership will remove only its own entries (those running \(shim)) from \(file). Everything else stays as it is, and a backup is saved first."
    }
}

private struct IntegrationRow: View {
    let status: IntegrationStatus
    let busy: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentGlyph(kind: status.kind, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.kind.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if let version = status.version {
                        Text(version)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(status.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(status.installed ? AnyShapeStyle(Palette.success) : AnyShapeStyle(.secondary))
                if let path = status.executablePath {
                    Text(PathDisplay.abbreviated(path))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(status.installed ? "Uninstall" : "Install", action: onToggle)
                    .disabled(status.executablePath == nil && !status.installed)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Notifications

struct NotificationSettingsView: View {
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
        Form {
            Section {
                Toggle("Show notifications", isOn: $enabled)
            } footer: {
                Text("Mothership never notifies about the pane you're looking at.")
            }
            Section("Notify me when an agent…") {
                Toggle("Asks for permission", isOn: $permissions)
                Toggle("Is waiting for input", isOn: $needsInput)
                Toggle("Finishes", isOn: $finished)
                Toggle("Fails", isOn: $failed)
                Toggle("Any program sends a terminal notification (OSC 9/99/777)", isOn: $terminal)
            }
            .disabled(!enabled)
            Section("Style") {
                Toggle("Play sounds", isOn: $sound)
                Toggle("Show count on the Dock icon", isOn: $dockBadge)
                Toggle("Notify even when the pane is visible but Mothership isn't frontmost", isOn: $whenVisible)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
    }
}
