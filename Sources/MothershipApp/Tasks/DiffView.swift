import AppKit
import GitKit
import ShipModel
import SwiftUI

/// A run's changes (a page): files on the left, the unified diff on the right with line
/// numbers, calm add/remove tints, foldable files, ⌘F find and copy-path.
struct DiffView: View {
    /// Debug snapshots open the find bar with a query (object: String).
    static let debugFind = Notification.Name("MothershipDiffDebugFind")

    let model: AppModel
    @State private var diff: UnifiedDiff?
    @State private var loadedRun: TaskRun.ID?
    @State private var collapsed: Set<String> = []
    @State private var selectedFile: String?
    @State private var finding = false
    @State private var query = ""
    @State private var matchIndex = 0
    @State private var copiedPath: String?
    @FocusState private var findFocused: Bool

    var body: some View {
        Group {
            if let runID = model.diffRunID, let pair = model.taskAndRun(runID) {
                page(task: pair.0, run: pair.1)
                    .task(id: runID) { await load(runID) }
            } else {
                VStack(spacing: 12) {
                    Text("No diff to show.").font(Sky.Font.serifL).foregroundStyle(Sky.ink)
                    Button("Back") { model.goBack() }.buttonStyle(SecondaryPillStyle(height: 32))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.debugFind)) { note in
            finding = true
            query = note.object as? String ?? ""
        }
        .background {
            // ⌘F and ⌘G without a menu item; the page owns the keys while it's up.
            Button("") { openFind() }.keyboardShortcut("f", modifiers: .command).opacity(0)
            Button("") { step(1) }.keyboardShortcut("g", modifiers: .command).opacity(0)
            Button("") { step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift]).opacity(0)
        }
    }

    private func load(_ runID: TaskRun.ID) async {
        guard loadedRun != runID else { return }
        let text = await model.diffText(for: runID)
        diff = UnifiedDiff.parse(text)
        loadedRun = runID
        collapsed = []
        selectedFile = diff?.files.first?.path
    }

    // MARK: Page

    private func page(task: AgentTask, run: TaskRun) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(task: task, run: run)
            if let diff {
                if diff.files.isEmpty {
                    VStack(spacing: 8) {
                        Text("No changes yet.").font(Sky.Font.serifL).foregroundStyle(Sky.ink)
                        Text("\(run.agent.shortName) hasn't touched the worktree.").font(Sky.Font.body).foregroundStyle(Sky.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        fileList(diff)
                            .frame(width: 260)
                        diffPane(diff)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 6)
    }

    private func header(task: AgentTask, run: TaskRun) -> some View {
        HStack(alignment: .center, spacing: 14) {
            CircleButton(symbol: "chevron.left", size: 36, label: "Back (Esc)") { model.goBack() }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    AgentMark(kind: run.agent, size: 16)
                    Text("\(run.agent.shortName)'s changes")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Sky.ink)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text("\(run.branch) → \(task.baseBranch)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let diff {
                        Text("·")
                        Text(diff.files.count == 1 ? "1 file" : "\(diff.files.count) files")
                        DiffStatText(insertions: diff.insertions, deletions: diff.deletions, size: 11.5)
                    }
                }
                .font(Sky.Font.meta)
                .foregroundStyle(Sky.secondary)
            }
            Spacer(minLength: 12)
            Button { openFind() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                    Text("Find")
                    Text("⌘F").font(Sky.Font.meta).foregroundStyle(Sky.tertiary)
                }
            }
            .buttonStyle(GhostPillStyle(height: 30, foreground: Sky.ink.opacity(0.8)))
            Button("Open pane") { model.openRunPane(run) }
                .buttonStyle(SecondaryPillStyle(height: 30))
        }
        .help(task.prompt)
    }

    // MARK: Files

    private func fileList(_ diff: UnifiedDiff) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(diff.files) { file in
                    let selected = selectedFile == file.path
                    Button {
                        selectedFile = file.path
                        collapsed.remove(file.path)
                        scrollTarget = file.path
                    } label: {
                        HStack(spacing: 8) {
                            StatusLetter(letter: file.letter, onSelection: selected)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((file.path as NSString).lastPathComponent)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(selected ? Sky.onSelection : Sky.ink)
                                    .lineLimit(1)
                                let directory = (file.path as NSString).deletingLastPathComponent
                                if !directory.isEmpty {
                                    Text(directory)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(selected ? Sky.onSelection.opacity(0.6) : Sky.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                            Spacer(minLength: 4)
                            DiffStatText(insertions: file.insertions, deletions: file.deletions, onSelection: selected, size: 10)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background {
                            let shape = RoundedRectangle(cornerRadius: Sky.radiusControl, style: .continuous)
                            if selected { shape.fill(Sky.selection).overlay(shape.strokeBorder(Sky.selectionStroke, lineWidth: 1)) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(file.path)
                }
            }
            .padding(8)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
        .glassPanel(radius: Sky.radiusPane)
    }

    // MARK: Diff

    @State private var scrollTarget: String?

    private func diffPane(_ diff: UnifiedDiff) -> some View {
        let matches = matchLineIDs(diff)
        let current = matches.isEmpty ? nil : matches[min(matchIndex, matches.count - 1)]
        return VStack(spacing: 0) {
            if finding {
                findBar(count: matches.count)
                Rectangle().fill(Sky.hairline).frame(height: 1)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(diff.files) { file in
                            Section {
                                if !collapsed.contains(file.path) {
                                    FileBody(file: file, query: finding ? query : "", currentMatch: current)
                                }
                            } header: {
                                fileHeader(file)
                                    .id(file.path)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.automatic)
                .onChange(of: scrollTarget) {
                    guard let target = scrollTarget else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .top) }
                    scrollTarget = nil
                }
                .onChange(of: current) {
                    guard let current else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Sky.radiusPane, style: .continuous).fill(Sky.bubble))
        .clipShape(RoundedRectangle(cornerRadius: Sky.radiusPane, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Sky.radiusPane, style: .continuous).strokeBorder(Sky.cardStroke, lineWidth: 1))
    }

    private func fileHeader(_ file: UnifiedDiff.File) -> some View {
        let isCollapsed = collapsed.contains(file.path)
        return HStack(spacing: 8) {
            Button {
                withAnimation(Sky.spring) {
                    if isCollapsed { collapsed.remove(file.path) } else { collapsed.insert(file.path) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Sky.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand" : "Collapse")
            StatusLetter(letter: file.letter)
            Group {
                if let old = file.oldPath, file.change == .renamed, old != file.path {
                    Text("\(old) → \(file.path)")
                } else {
                    Text(file.path)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(Sky.ink)
            .lineLimit(1)
            .truncationMode(.head)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
                copiedPath = file.path
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    if copiedPath == file.path { copiedPath = nil }
                }
            } label: {
                Image(systemName: copiedPath == file.path ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Sky.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy path")
            Spacer(minLength: 8)
            if file.change == .binary {
                Text("binary").font(Sky.Font.meta).foregroundStyle(Sky.tertiary)
            } else {
                DiffStatText(insertions: file.insertions, deletions: file.deletions, size: 11)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: 38)
        .background(Sky.bubble)
        .overlay(alignment: .bottom) { Rectangle().fill(Sky.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(Sky.spring) {
                if isCollapsed { collapsed.remove(file.path) } else { collapsed.insert(file.path) }
            }
        }
    }

    // MARK: Find

    private func findBar(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Sky.tertiary)
            TextField("Find in diff", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Sky.ink)
                .focused($findFocused)
                .onSubmit { step(1) }
                .onChange(of: query) { matchIndex = 0 }
                .onExitCommand { closeFind() }
            if !query.isEmpty {
                Text(count == 0 ? "No matches" : "\(min(matchIndex, count - 1) + 1) of \(count)")
                    .font(Sky.Font.meta)
                    .foregroundStyle(count == 0 ? Sky.tertiary : Sky.secondary)
                    .monospacedDigit()
            }
            findButton("chevron.up", "Previous (⇧⌘G)") { step(-1) }
            findButton("chevron.down", "Next (⌘G)") { step(1) }
            findButton("xmark", "Done (Esc)") { closeFind() }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Sky.bubble)
    }

    private func findButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Sky.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func openFind() {
        withAnimation(Sky.hover) { finding = true }
        DispatchQueue.main.async { findFocused = true }
    }

    private func closeFind() {
        withAnimation(Sky.hover) { finding = false }
        query = ""
    }

    private func step(_ delta: Int) {
        guard let diff else { return }
        let count = matchLineIDs(diff).count
        guard count > 0 else { return }
        if !finding { openFind() }
        matchIndex = ((matchIndex + delta) % count + count) % count
    }

    /// Lines containing the query (case-insensitive), in order; collapsed files are opened
    /// by searching only what's visible.
    private func matchLineIDs(_ diff: UnifiedDiff) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard finding, !needle.isEmpty else { return [] }
        var ids: [String] = []
        for file in diff.files where !collapsed.contains(file.path) {
            for hunk in file.hunks {
                for line in hunk.lines where line.text.range(of: needle, options: .caseInsensitive) != nil {
                    ids.append(line.id)
                }
            }
        }
        return ids
    }
}

/// One file's hunks: a hunk header, then numbered lines.
private struct FileBody: View {
    let file: UnifiedDiff.File
    let query: String
    let currentMatch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if file.change == .binary {
                Text("Binary file not shown.")
                    .font(.system(size: 12))
                    .foregroundStyle(Sky.tertiary)
                    .padding(14)
            }
            ForEach(file.hunks) { hunk in
                HStack(spacing: 8) {
                    Text(hunkRange(hunk.header))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Sky.tertiary)
                    if !hunk.context.isEmpty {
                        Text(hunk.context)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Sky.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 104)
                .padding(.trailing, 14)
                .frame(height: 26)
                .background(Sky.recess)
                ForEach(hunk.lines) { line in
                    DiffLineRow(line: line, query: query, isCurrent: line.id == currentMatch)
                        .id(line.id)
                }
            }
        }
    }

    private func hunkRange(_ header: String) -> String {
        guard let end = header.range(of: "@@", range: header.index(header.startIndex, offsetBy: 2) ..< header.endIndex) else { return header }
        return String(header[..<end.upperBound])
    }
}

private struct DiffLineRow: View {
    let line: UnifiedDiff.Line
    let query: String
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(sign)
                .foregroundStyle(signColor)
                .frame(width: 18, alignment: .center)
            Text(highlighted)
                .foregroundStyle(line.kind == .note ? Sky.tertiary : Sky.ink.opacity(0.9))
                .italic(line.kind == .note)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
        .lineSpacing(2)
        .padding(.vertical, 1.5)
        .padding(.trailing, 14)
        .background(fill)
        .overlay(alignment: .leading) {
            if line.kind == .added || line.kind == .removed {
                Rectangle().fill(signColor.opacity(0.55)).frame(width: 2)
            }
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(line.kind == .context ? Sky.tertiary : signColor.opacity(0.75))
            .frame(width: 42, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var sign: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context, .note: " "
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .added: Sky.diffAddMark
        case .removed: Sky.diffRemoveMark
        case .context, .note: Sky.tertiary
        }
    }

    private var fill: Color {
        if isCurrent { return Sky.findMatch.opacity(0.38) }
        switch line.kind {
        case .added: return Sky.diffAddFill
        case .removed: return Sky.diffRemoveFill
        case .context, .note: return .clear
        }
    }

    /// The query's occurrences get a soft amber wash.
    private var highlighted: AttributedString {
        // Tabs at four columns read like an editor rather than eight-wide gaps.
        var text = AttributedString(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return text }
        var searchStart = text.startIndex
        while searchStart < text.endIndex, let range = text[searchStart...].range(of: needle, options: .caseInsensitive) {
            text[range].backgroundColor = Sky.findMatch
            searchStart = range.upperBound
        }
        return text
    }
}
