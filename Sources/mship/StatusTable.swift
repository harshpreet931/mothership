import Foundation
import ShipModel
import ShipProtocol

/// `mship status`: a compact fleet table, colored on a TTY.
///
///     WORKSPACE    AGENT        STATE                           CWD           SUMMARY
///     api-server   Claude Code  ● needs permission: Bash npm…   ~/src/api     Refactor auth middleware
///     (VS Code)    Codex        ● working (Edit)                ~/src/web     Add dark mode
enum StatusTable {
    struct Row {
        var workspace: String
        var agent: String
        var state: String
        var stateColor: (Style, String) -> String
        var cwd: String
        var summary: String
        var priority: Int
    }

    static func render(_ status: StatusResult, style: Style, width: Int) -> String {
        let rows = status.sessions.map { row(for: $0, in: status) }
            .enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .map(\.element)

        var output = ""
        if rows.isEmpty {
            output += style.dim("No agent sessions.") + "\n"
        } else {
            let headers = ["WORKSPACE", "AGENT", "STATE", "CWD", "SUMMARY"]
            let caps = [22, 14, 44, 32]
            var widths = (0..<4).map { column in
                min(caps[column], max(headers[column].count, rows.map { cells($0)[column].count }.max() ?? 0))
            }
            // Give the state column back what the summary can't use on narrow terminals.
            let fixed = widths.reduce(0, +) + 2 * 4
            if fixed > width - 12 { widths[2] = max(16, widths[2] - (fixed - (width - 12))) }
            let summaryWidth = max(8, width - (widths.reduce(0, +) + 2 * 4))

            output += style.dim(zip(headers, widths + [summaryWidth]).map { pad($0, $1) }.joined(separator: "  ").trimmingTrailing()) + "\n"
            for row in rows {
                let values = cells(row)
                var line = ""
                for column in 0..<4 {
                    let text = pad(truncate(values[column], widths[column]), widths[column])
                    switch column {
                    case 0: line += style.bold(text)
                    case 2: line += row.stateColor(style, text)
                    case 3: line += style.dim(text)
                    default: line += text
                    }
                    line += "  "
                }
                line += truncate(row.summary, summaryWidth)
                output += line.trimmingTrailing() + "\n"
            }
        }

        let attention = status.sessions.filter { $0.state.needsAttention }.count
        let live = status.sessions.filter { $0.state.isLive }.count
        var footer = "\(status.workspaces.count) workspace\(status.workspaces.count == 1 ? "" : "s") · \(live) live agent\(live == 1 ? "" : "s")"
        if attention > 0 { footer += " · " + style.orange("\(attention) need\(attention == 1 ? "s" : "") you") }
        output += style.dim(footer) + "\n"
        return output
    }

    private static func cells(_ row: Row) -> [String] {
        [row.workspace, row.agent, row.state, row.cwd, row.summary]
    }

    static func row(for session: AgentSession, in status: StatusResult) -> Row {
        let workspace = StatusFormatter.workspace(of: session, in: status)?.name
            ?? "(\(session.hostApp ?? "external"))"
        let text = StatusFormatter.stateText(session.state, pending: session.pendingPermission)
        let (dot, color, priority): (String, (Style, String) -> String, Int) = switch session.state {
        case .needsInput(.permission): ("●", { $0.orange($1) }, 0)
        case .needsInput: ("●", { $0.yellow($1) }, 1)
        case .error: ("●", { $0.red($1) }, 1)
        case .working: ("●", { $0.cyan($1) }, 2)
        case .starting: ("○", { $0.blue($1) }, 3)
        case .idle: ("○", { $0.green($1) }, 3)
        case .ended: ("·", { $0.dim($1) }, 5)
        }
        let summary = session.summary ?? session.title ?? session.lastUserPrompt ?? ""
        return Row(
            workspace: workspace, agent: session.kind.displayName, state: "\(dot) \(text)", stateColor: color,
            cwd: abbreviateHome(session.cwd), summary: summary.replacingOccurrences(of: "\n", with: " "),
            priority: session.surface == nil ? priority + 10 : priority
        )
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func truncate(_ text: String, _ width: Int) -> String {
        guard text.count > width else { return text }
        guard width > 1 else { return String(text.prefix(width)) }
        return String(text.prefix(width - 1)) + "…"
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}

extension String {
    func trimmingTrailing() -> String {
        var copy = self
        while copy.last == " " { copy.removeLast() }
        return copy
    }
}
