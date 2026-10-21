import ShipModel
import SwiftUI

/// A pending connect/disconnect the user is being asked about.
struct IntegrationChange: Identifiable {
    var id: String { kind.rawValue + (install ? "+" : "-") }
    let kind: AgentKind
    let install: Bool
}

enum IntegrationCopy {
    /// The file each installer edits.
    static func configFile(for kind: AgentKind) -> String {
        switch kind {
        case .claude: "~/.claude/settings.json"
        case .codex: "~/.codex/hooks.json"
        case .opencode: "~/.config/opencode/plugins/mothership.js"
        case .gemini: "~/.gemini/settings.json"
        default: "the agent's configuration"
        }
    }

    static func explanation(for kind: AgentKind, install: Bool) -> String {
        let shim = PathDisplay.abbreviated(ShipPaths.cliShim.path)
        let file = configFile(for: kind)
        if install {
            return "Mothership adds hook entries to \(file) that run \(shim) hook \(kind.rawValue) <event>. Your settings and other tools' hooks stay as they are, and a timestamped backup goes to \(PathDisplay.abbreviated(ShipPaths.backups.path)) first."
        }
        return "Mothership removes only its own entries (those running \(shim)) from \(file). Everything else stays, and a backup is saved first."
    }

    static let codexTrustNote = "Codex will ask you to trust these hooks once in /hooks."
}

/// Consent before touching an agent's config: what changes, where, and the exact
/// contents the installer would write.
struct IntegrationConsentSheet: View {
    let model: AppModel
    let change: IntegrationChange
    let onDone: () -> Void

    @State private var planned: String?
    @State private var loading = true
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AgentMark(kind: change.kind, size: 22)
                Text("\(change.install ? "Connect" : "Disconnect") \(change.kind.displayName)?")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Sky.ink)
            }
            Text(IntegrationCopy.explanation(for: change.kind, install: change.install))
                .font(.system(size: 13))
                .foregroundStyle(Sky.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if change.install {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Planned contents of \(IntegrationCopy.configFile(for: change.kind))")
                        .font(Sky.Font.meta)
                        .foregroundStyle(Sky.tertiary)
                    Group {
                        if loading {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
                        } else if let planned {
                            ScrollView([.vertical, .horizontal]) {
                                Text(planned)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Sky.ink.opacity(0.85))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(height: 220)
                        } else {
                            Text("A preview isn't available for this agent.")
                                .font(.system(size: 12))
                                .foregroundStyle(Sky.secondary)
                                .frame(maxWidth: .infinity, minHeight: 60)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Sky.radiusControl, style: .continuous).fill(Sky.recess))
                }
                if change.kind == .codex {
                    Label(IntegrationCopy.codexTrustNote, systemImage: "info.circle")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Sky.secondary)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Sky.danger)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(SecondaryPillStyle(height: 30, fill: Sky.recess))
                    .keyboardShortcut(.cancelAction)
                Button {
                    perform()
                } label: {
                    if working {
                        ProgressView().controlSize(.mini).tint(Sky.onInk)
                    } else {
                        Text(change.install ? "Connect" : "Disconnect")
                    }
                }
                .buttonStyle(InkCapsuleStyle(height: 30))
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            guard change.install else { loading = false; return }
            planned = await model.plannedIntegrationChange?(change.kind)
            loading = false
        }
    }

    private func perform() {
        working = true
        errorMessage = nil
        Task {
            do {
                if change.install {
                    try await model.installIntegration(change.kind)
                } else {
                    try await model.uninstallIntegration(change.kind)
                }
                onDone()
            } catch {
                errorMessage = error.localizedDescription
            }
            working = false
        }
    }
}
