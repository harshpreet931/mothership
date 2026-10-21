import GitKit
import ShipModel
import SwiftUI

/// Best-of-N, side by side (a page like Fleet): one column per run with what it did and
/// what it cost, and the decision (keep one, discard the rest) right underneath.
struct CompareView: View {
    let model: AppModel
    @State private var dismissedOffer = false

    var body: some View {
        if let id = model.compareTaskID, let task = model.task(id: id) {
            content(task)
        } else {
            VStack(spacing: 12) {
                Text("Nothing to compare.").font(Sky.Font.serifL).foregroundStyle(Sky.ink)
                Button("Back to workspaces") { model.goBack() }.buttonStyle(SecondaryPillStyle(height: 32))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ task: AgentTask) -> some View {
        let kept = task.runs.first { $0.outcome == .kept }
        let others = task.runs.filter { $0.outcome == .running && $0.id != kept?.id }
        return VStack(alignment: .leading, spacing: 18) {
            header(task)
            if let kept, !others.isEmpty, !dismissedOffer {
                KeepOffer(model: model, kept: kept, others: others) { dismissedOffer = true }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            GeometryReader { geometry in
                let count = max(task.runs.count, 1)
                let spacing: CGFloat = 12
                let fits = (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count) >= 290
                ScrollView(fits ? [] : .horizontal) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(task.runs) { run in
                            RunColumn(model: model, task: task, run: run)
                                .frame(width: fits ? nil : 320)
                                .frame(minWidth: 0, maxWidth: fits ? .infinity : nil, maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .frame(height: geometry.size.height)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.top, 6)
        .animation(Sky.spring, value: task.runs.map(\.outcome))
    }

    private func header(_ task: AgentTask) -> some View {
        HStack(alignment: .center, spacing: 14) {
            CircleButton(symbol: "chevron.left", size: 36, label: "Back (Esc)") { model.goBack() }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Sky.ink)
                    .lineLimit(1)
                Text(subtitle(task))
                    .font(Sky.Font.meta)
                    .foregroundStyle(Sky.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            TaskPhaseMark(phase: model.phase(of: task))
            Text(model.phase(of: task).label)
                .font(Sky.Font.label)
                .foregroundStyle(Sky.secondary)
        }
        .help(task.prompt)
    }

    private func subtitle(_ task: AgentTask) -> String {
        let repo = (task.repoRoot as NSString).lastPathComponent
        let best = task.runs.count > 1 ? "Best of \(task.runs.count)" : "1 run"
        return "\(best) · \(repo) · from \(task.baseBranch) · started \(Format.elapsed(since: task.createdAt)) ago"
    }
}

/// "You kept Claude's run. Discard the other two?" — one click to finish the decision.
private struct KeepOffer: View {
    let model: AppModel
    let kept: TaskRun
    let others: [TaskRun]
    let onDismiss: () -> Void
    @State private var working = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundStyle(Sky.ink.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                Text("You kept \(kept.agent.shortName)'s run.")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Sky.ink)
                Text(error ?? (others.count == 1
                    ? "Discard the other run to remove its worktree and branch."
                    : "Discard the other \(others.count) runs to remove their worktrees and branches."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(error == nil ? Sky.secondary : Sky.danger)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Not now", action: onDismiss).buttonStyle(GhostPillStyle(height: 30))
            Button {
                discardOthers()
            } label: {
                if working {
                    ProgressView().controlSize(.mini).tint(Sky.onInk)
                } else {
                    Text(others.count == 1 ? "Discard the other run" : "Discard \(others.count) runs")
                }
            }
            .buttonStyle(InkCapsuleStyle(height: 30))
            .disabled(working)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .glassPanel(radius: Sky.radiusPane)
    }

    private func discardOthers() {
        working = true
        error = nil
        Task {
            for run in others {
                do {
                    try await model.discardRun(run.id)
                } catch {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    break
                }
            }
            working = false
        }
    }
}

/// One run: agent and state, elapsed · tokens · cost, the diff, the changed files, the last
/// reply, and View diff / Open pane / Keep ▾ / Discard.
private struct RunColumn: View {
    let model: AppModel
    let task: AgentTask
    let run: TaskRun
    @State private var confirmingDiscard = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let session = model.session(for: run)
        let phase = model.phase(of: run)
        VStack(alignment: .leading, spacing: 14) {
            header(session: session, phase: phase)
            stats(session: session)
            changes
            if let message = session?.lastAssistantMessage, !message.isEmpty {
                AssistantBubble(text: message, lineLimit: 6)
            }
            Spacer(minLength: 0)
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Sky.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions(phase: phase)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel()
        .overlay {
            if run.outcome == .kept {
                RoundedRectangle(cornerRadius: Sky.radiusPanel, style: .continuous)
                    .strokeBorder(Sky.ink.opacity(0.35), lineWidth: 1.5)
            }
        }
        .opacity(run.outcome == .discarded ? 0.5 : 1)
    }

    private func header(session: AgentSession?, phase: TaskPhase) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                if let session {
                    AgentStatusGlyph(kind: session.kind, state: session.state, unread: session.unread, hasPermission: session.pendingPermission != nil, size: 17)
                } else {
                    AgentMark(kind: run.agent, size: 17).frame(width: 24, height: 24)
                }
                Text(run.agent.displayName)
                    .font(Sky.Font.title)
                    .foregroundStyle(Sky.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Color.clear.frame(width: 0, height: 24)
                switch run.outcome {
                case .kept:
                    Text("Kept")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Sky.onInk)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Sky.ink))
                case .discarded:
                    Text("Discarded").font(Sky.Font.label).foregroundStyle(Sky.tertiary)
                case .running:
                    Text(phase.label)
                        .font(Sky.Font.meta)
                        .foregroundStyle(phase == .needsYou ? Sky.attention : (phase == .failed ? Sky.danger : Sky.secondary))
                }
            }
            HStack(spacing: 6) {
                Text("\(Image(systemName: "arrow.triangle.branch")) \(run.branch)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status = model.pullRequest(for: run.workspaceID) {
                    Spacer(minLength: 4)
                    PullRequestChip(status: status) { model.openPullRequest(status, in: run.workspaceID) }
                }
            }
            .font(Sky.Font.meta)
            .foregroundStyle(Sky.tertiary)
            .padding(.leading, 33)
        }
    }

    private func stats(session: AgentSession?) -> some View {
        let start = session?.startedAt ?? task.createdAt
        let end = session.flatMap { $0.state.isWorking || $0.needsYou ? nil : $0.lastActivity } ?? Date()
        let usage = session?.usage
        return HStack(spacing: 8) {
            StatTile(label: "Elapsed", value: Format.elapsed(since: start, now: end))
            StatTile(label: "Tokens", value: usage.map { Format.tokens($0.inputTokens + $0.outputTokens + $0.cacheWriteTokens) } ?? "—")
            StatTile(label: "Cost", value: usage?.costUSD.map(Format.cost) ?? "—")
        }
    }

    @ViewBuilder private var changes: some View {
        if let diff = run.diff, !diff.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    DiffStatText(insertions: diff.insertions, deletions: diff.deletions, size: 12)
                    Text(verbatim: "·").foregroundStyle(Sky.tertiary)
                    Text(diff.files.count == 1 ? "1 file" : "\(diff.files.count) files")
                        .font(Sky.Font.meta)
                        .foregroundStyle(Sky.secondary)
                    Spacer(minLength: 0)
                    DiffBalanceBar(insertions: diff.insertions, deletions: diff.deletions)
                        .frame(width: 54)
                }
                VStack(spacing: 0) {
                    ForEach(diff.files.prefix(7)) { file in
                        FileChangeRow(file: file)
                    }
                    if diff.files.count > 7 {
                        Text("\(diff.files.count - 7) more")
                            .font(Sky.Font.meta)
                            .foregroundStyle(Sky.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Sky.radiusControl, style: .continuous).fill(Sky.recess))
            }
        } else {
            Text(run.diff == nil ? "Changes appear as the agent works." : "No changes yet.")
                .font(.system(size: 12.5))
                .foregroundStyle(Sky.tertiary)
        }
    }

    @ViewBuilder private func actions(phase _: TaskPhase) -> some View {
        if confirmingDiscard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Discard \(run.agent.shortName)'s run? Its worktree and branch are removed.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Sky.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Spacer()
                    Button("Cancel") { confirmingDiscard = false }.buttonStyle(GhostPillStyle(height: 28))
                    Button("Discard") { perform { try await model.discardRun(run.id) } }
                        .buttonStyle(SecondaryPillStyle(height: 28, foreground: Sky.danger, fill: Sky.recess))
                }
            }
            .transition(.opacity)
        } else if run.outcome == .discarded {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                Button("View diff") { model.openDiff(run.id) }
                    .buttonStyle(SecondaryPillStyle(height: 28, fill: Sky.recess))
                    .fixedSize()
                    .disabled(run.diff?.isEmpty ?? false)
                Button { model.openRunPane(run) } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(GhostPillStyle(height: 28, foreground: Sky.ink.opacity(0.75)))
                .fixedSize()
                .help("Open this run's pane")
                Spacer(minLength: 2)
                if run.outcome == .running {
                    Button {
                        confirmingDiscard = true
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(GhostPillStyle(height: 28, foreground: Sky.secondary))
                    .fixedSize()
                    .help("Discard this run")
                    keepMenu
                }
            }
        }
    }

    private var keepMenu: some View {
        Menu {
            Button("Open Pull Request") { perform { try await model.keepRun(run.id, mode: .pullRequest) } }
            Button("Merge into \(task.baseBranch)") { perform { try await model.keepRun(run.id, mode: .mergeIntoBase) } }
            Button("Keep Branch") { perform { try await model.keepRun(run.id, mode: .keepBranch) } }
        } label: {
            HStack(spacing: 5) {
                if working {
                    ProgressView().controlSize(.mini).tint(Sky.onInk)
                } else {
                    Text("Keep")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
            .font(Sky.Font.label)
            .foregroundStyle(Sky.onInk)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule(style: .continuous).fill(Sky.ink))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(working)
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await action()
                confirmingDiscard = false
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(Sky.tertiary)
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Sky.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Sky.radiusControl, style: .continuous).fill(Sky.recess))
    }
}

/// A file in a change list: status letter, path, counts.
struct FileChangeRow: View {
    let file: FileChange

    var body: some View {
        HStack(spacing: 8) {
            StatusLetter(letter: Self.letter(file.status))
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Sky.ink.opacity(0.88))
                .lineLimit(1)
                .layoutPriority(1)
            let directory = (file.path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                Text(directory)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Sky.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            DiffStatText(insertions: file.insertions, deletions: file.deletions, size: 10.5)
        }
        .frame(height: 22)
        .help(file.path)
    }

    static func letter(_ status: FileChange.Status) -> String {
        switch status {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        }
    }
}

/// M / A / D / R / U in a small rounded square.
struct StatusLetter: View {
    let letter: String
    var onSelection = false

    var body: some View {
        Text(letter)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(onSelection ? Sky.onSelection.opacity(0.85) : (letter == "D" ? Sky.danger.opacity(0.9) : Sky.ink.opacity(0.65)))
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(onSelection ? Sky.onSelection.opacity(0.16) : Sky.ink.opacity(0.07)))
    }
}

/// Five ticks split between additions and removals, GitHub-style but in ink.
struct DiffBalanceBar: View {
    let insertions: Int
    let deletions: Int

    var body: some View {
        let total = max(insertions + deletions, 1)
        let added = Int((Double(insertions) / Double(total) * 5).rounded())
        HStack(spacing: 2) {
            ForEach(0 ..< 5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < added ? Sky.ink.opacity(0.7) : Sky.ink.opacity(0.18))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}
