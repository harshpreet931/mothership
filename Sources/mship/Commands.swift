import Darwin
import Foundation
import ShipModel
import ShipProtocol

/// Every subcommand except `hook` and `mcp`, which have their own files.
enum Commands {
    static var caller: CallerContext { .fromEnvironment() }

    // MARK: Panes & workspaces

    static func split(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        var args = Arguments(arguments, command: "split")
        let directions: [(String, SplitDirection)] = [("--right", .right), ("--down", .down), ("--left", .left), ("--up", .up)]
        var direction = SplitDirection.right
        for (flag, value) in directions where args.flag(flag) { direction = value }
        let url = try args.option("--browser")
        let cwd = try args.option("--cwd").map(absolutePath)
        let focus = args.flag("--focus")
        let surface = try args.option("--surface").map { (raw) throws(CLIFailure) in try parseSurface(raw, command: "split") }
        let extra = try args.positionals()
        guard extra.isEmpty else { throw usageError("unexpected argument '\(extra[0])' (put the command after --)", command: "split") }
        if url != nil, args.hasTrailing {
            throw usageError("--browser and a command can't be combined", command: "split")
        }
        let params = SplitParams(
            surface: surface ?? caller.surface, direction: direction, kind: url == nil ? .terminal : .browser,
            cwd: cwd ?? currentDirectory, command: args.trailingCommand, url: url, focus: focus
        )
        let result: SurfaceResult = try callApp(.surfaceSplit, params)
        Output.line(result.surface.description)
        return ExitCode.success
    }

    static func newWorkspace(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        var args = Arguments(arguments, command: "new")
        let name = try args.option("--name", "-n")
        let cwd = try args.option("--cwd").map(absolutePath)
        let background = args.flag("--background", "-b")
        let extra = try args.positionals()
        guard extra.isEmpty else { throw usageError("unexpected argument '\(extra[0])' (put the command after --)", command: "new") }
        let params = NewWorkspaceParams(name: name, cwd: cwd ?? currentDirectory, command: args.trailingCommand, focus: !background)
        let result: SurfaceResult = try callApp(.workspaceNew, params)
        Output.line(result.surface.description)
        return ExitCode.success
    }

    static func close(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        var args = Arguments(arguments, command: "close")
        let surface = try args.option("--surface", "-s").map { (raw) throws(CLIFailure) in try parseSurface(raw, command: "close") }
        let positionals = try args.positionals()
        let target = try positionals.first.map { (raw) throws(CLIFailure) in try parseSurface(raw, command: "close") } ?? surface ?? caller.surface
        guard let target else { throw usageError("which pane? pass a surface id", command: "close") }
        let _: OKResult = try callApp(.surfaceClose, SurfaceTarget(surface: target))
        return ExitCode.success
    }

    static func focus(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        let positionals = try Arguments(arguments, command: "focus").positionals()
        guard positionals.count == 1 else { throw usageError("expected one surface id", command: "focus") }
        let _: OKResult = try callApp(.surfaceFocus, SurfaceTarget(surface: try parseSurface(positionals[0], command: "focus")))
        return ExitCode.success
    }

    static func send(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        var args = Arguments(arguments, command: "send")
        let surfaceArgument = try args.option("--surface", "-s")
        let submit = args.flag("--submit", "-r")
        let keys = try args.options("--key")
        var words = try args.positionals() + args.trailing
        if words == ["-"] || (words.isEmpty && keys.isEmpty && !Input.stdinIsTerminal) {
            words = [String(decoding: Input.readAll(idle: .seconds(5), total: .seconds(60)), as: UTF8.self)]
        }
        guard !words.isEmpty || !keys.isEmpty else { throw usageError("nothing to send", command: "send") }
        let surface: SurfaceID
        if let surfaceArgument {
            surface = try parseSurface(surfaceArgument, command: "send")
        } else if let own = caller.surface {
            surface = own
        } else {
            throw usageError("--surface is required outside a Mothership pane", command: "send")
        }
        let _: OKResult = try callApp(.surfaceSendText, SendTextParams(surface: surface, text: words.joined(separator: " "), submit: submit, keys: keys.isEmpty ? nil : keys))
        return ExitCode.success
    }

    static func screen(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        var args = Arguments(arguments, command: "screen")
        let surface = try args.option("--surface", "-s").map { (raw) throws(CLIFailure) in try parseSurface(raw, command: "screen") }
        let lines = try args.intOption("--lines", "-n") ?? 0
        guard try args.positionals().isEmpty else { throw usageError("unexpected argument", command: "screen") }
        let result: ReadScreenResult = try callApp(.surfaceReadScreen, ReadScreenParams(surface: surface ?? caller.surface, scrollbackLines: lines))
        Output.write(result.text.hasSuffix("\n") ? result.text : result.text + "\n")
        return ExitCode.success
    }

    // MARK: Browser

    static func open(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        var args = Arguments(arguments, command: "open")
        var placement = BrowserPlacement.reuse
        if args.flag("--split") { placement = .split }
        if args.flag("--new-workspace", "--workspace") { placement = .newWorkspace }
        let positionals = try args.positionals()
        guard positionals.count == 1 else { throw usageError("expected one URL", command: "open") }
        let result: SurfaceResult = try callApp(.browserOpen, BrowserOpenParams(url: positionals[0], surface: caller.surface, placement: placement), timeout: .seconds(60))
        Output.line(result.surface.description)
        return ExitCode.success
    }

    static func browser(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        guard let subcommand = arguments.first else { throw usageError("missing subcommand", command: "browser") }
        var args = Arguments(Array(arguments.dropFirst()), command: "browser")
        let browser = try args.option("--browser").map { (raw) throws(CLIFailure) in try parseSurface(raw, command: "browser") }
        switch subcommand {
        case "snapshot":
            guard try args.positionals().isEmpty else { throw usageError("snapshot takes no arguments", command: "browser") }
            let result: BrowserSnapshotResult = try callApp(.browserSnapshot, BrowserTarget(browser: browser))
            let style = Style(enabled: Output.useColor)
            Output.line(style.bold(result.title.isEmpty ? "(untitled)" : result.title) + "  " + style.dim(result.url))
            Output.line(result.outline)
        case "click":
            let positionals = try args.positionals()
            guard positionals.count == 1 else { throw usageError("usage: mship browser click <ref>", command: "browser") }
            let _: OKResult = try callApp(.browserClick, BrowserElementParams(browser: browser, ref: positionals[0]))
        case "fill":
            let submit = args.flag("--submit")
            let positionals = try args.positionals() + args.trailing
            guard positionals.count >= 2 else { throw usageError("usage: mship browser fill <ref> <text> [--submit]", command: "browser") }
            let text = positionals.dropFirst().joined(separator: " ")
            let _: OKResult = try callApp(.browserFill, BrowserFillParams(browser: browser, ref: positionals[0], text: text, submit: submit))
        case "eval":
            var words = try args.positionals() + args.trailing
            if words == ["-"] || (words.isEmpty && !Input.stdinIsTerminal) {
                words = [String(decoding: Input.readAll(idle: .seconds(5), total: .seconds(60)), as: UTF8.self)]
            }
            guard !words.isEmpty else { throw usageError("usage: mship browser eval <javascript>", command: "browser") }
            let result: JSONValue = try callApp(.browserEval, BrowserEvalParams(browser: browser, script: words.joined(separator: " ")), timeout: .seconds(60))
            if case .string(let text) = result {
                Output.line(text)
            } else {
                Output.line(result.prettyText ?? "null")
            }
        case "console":
            let errorsOnly = args.flag("--errors")
            let json = args.flag("--json")
            guard try args.positionals().isEmpty else { throw usageError("console takes no arguments", command: "browser") }
            let result: BrowserConsoleResult = try callApp(.browserConsole, BrowserTarget(browser: browser))
            let errorLevels: Set<String> = ["error", "exception", "network", "rejection"]
            let entries = result.entries.filter { !errorsOnly || errorLevels.contains($0.level) }
            if json {
                Output.line((try? JSONValue(encoding: BrowserConsoleResult(entries: entries)))?.prettyText ?? "{}")
            } else {
                let style = Style(enabled: Output.useColor)
                for entry in entries {
                    let level: String = switch entry.level {
                    case "error", "exception", "rejection", "network": style.red(entry.level)
                    case "warn", "warning": style.yellow(entry.level)
                    default: style.dim(entry.level)
                    }
                    Output.line("\(style.dim(MCPToolCatalog.clockTime(entry.date))) \(level) \(entry.message)")
                }
            }
        case "screenshot":
            guard try args.positionals().isEmpty else { throw usageError("screenshot takes no arguments", command: "browser") }
            let result: BrowserScreenshotResult = try callApp(.browserScreenshot, BrowserTarget(browser: browser))
            Output.line(result.path)
        default:
            throw usageError("unknown browser subcommand '\(subcommand)'", command: "browser")
        }
        return ExitCode.success
    }

    // MARK: Agents & attention

    static func notify(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        var args = Arguments(arguments, command: "notify")
        let surface = try args.option("--surface", "-s").map { (raw) throws(CLIFailure) in try parseSurface(raw, command: "notify") }
        let words = try args.positionals() + args.trailing
        guard let title = words.first, !title.isEmpty else { throw usageError("missing title", command: "notify") }
        let body = words.dropFirst().joined(separator: " ")
        let _: OKResult = try callApp(.notify, NotifyParams(title: title, body: body, surface: surface ?? caller.surface))
        return ExitCode.success
    }

    static func approve(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        try resolvePermission(arguments, allow: true, command: "approve")
    }

    static func deny(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        try resolvePermission(arguments, allow: false, command: "deny")
    }

    private static func resolvePermission(_ arguments: [String], allow: Bool, command: String) throws(CLIFailure) -> Int32 {
        var args = Arguments(arguments, command: command)
        let surface = try args.option("--surface", "-s").map { (raw) throws(CLIFailure) in try parseSurface(raw, command: command) }
        let reason = allow ? nil : try args.option("--reason", "-m")
        let positionals = try args.positionals()
        guard positionals.count <= 1 else { throw usageError("expected at most one request id", command: command) }
        let id: PermissionRequestID?
        if let raw = positionals.first {
            guard let parsed = PermissionRequestID(string: raw) else { throw usageError("not a request id: \(raw)", command: command) }
            id = parsed
        } else {
            id = nil
        }
        let params = ResolvePermissionParams(id: id, surface: surface ?? caller.surface, allow: allow, reason: reason)
        let result: ResolvePermissionResult = try callApp(.permissionResolve, params)
        let request = result.request
        Output.line("\(allow ? "Allowed" : "Denied") \(request.toolName): \(request.summary)")
        return ExitCode.success
    }

    static func status(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        var args = Arguments(arguments, command: "status")
        let json = args.flag("--json")
        guard try args.positionals().isEmpty else { throw usageError("unexpected argument", command: "status") }
        let result: StatusResult = try callApp(.status, StatusParams(includeExternal: true), timeout: .seconds(10))
        if json {
            Output.line((try? JSONValue(encoding: result))?.prettyText ?? "{}")
        } else {
            Output.write(StatusTable.render(result, style: Style(enabled: Output.useColor), width: Output.stdoutIsTerminal ? Output.terminalWidth : 200))
        }
        return ExitCode.success
    }

    static func ping(_ arguments: [String]) throws(CLIFailure) -> Int32 {
        var args = Arguments(arguments, command: "ping")
        let quiet = args.flag("-q", "--quiet")
        guard try args.positionals().isEmpty else { throw usageError("unexpected argument", command: "ping") }
        if !quiet {
            let start = ContinuousClock.now
            let result: PingResult = try callApp(.ping, OKResult(), timeout: .seconds(2))
            let elapsed = ContinuousClock.now - start
            let micros = elapsed.components.seconds * 1_000_000 + elapsed.components.attoseconds / 1_000_000_000_000
            Output.line("Mothership \(result.version) is running (pid \(result.pid), round trip \(micros) µs)")
            return ExitCode.success
        }
        let client = ControlClient(socketPath: socketPath)
        defer { client.close() }
        do throws(ControlClientError) {
            _ = try client.request(ControlMethod.ping.rawValue, timeout: .seconds(2))
            return ExitCode.success
        } catch {
            return error.isAppNotRunning ? ExitCode.notRunning : ExitCode.failure
        }
    }
}
