import Darwin
import ShipModel
import ShipProtocol

// Kept synchronous (no top-level await) so the `hook` path starts without spinning up the
// concurrency runtime's main executor; `mcp` parks the main thread in dispatchMain itself.

let argv = Array(CommandLine.arguments.dropFirst())
let command = argv.first ?? "help"
let rest = Array(argv.dropFirst())

if command == "hook" { HookCommand.run(rest) }
if command == "mcp" { MCPCommand.run(rest) }

let wantsHelp = rest.contains("--help") || rest.contains("-h")
let commands: [String: ([String]) throws(CLIFailure) -> Int32] = [
    "split": Commands.split,
    "new": Commands.newWorkspace,
    "focus": Commands.focus,
    "send": Commands.send,
    "screen": Commands.screen,
    "open": Commands.open,
    "browser": Commands.browser,
    "notify": Commands.notify,
    "status": Commands.status,
    "ping": Commands.ping,
]

switch command {
case "help", "--help", "-h":
    if let topic = rest.first {
        guard let text = Help.command(topic) else {
            Output.error("no help for '\(topic)'. Commands: \(Help.commands.keys.sorted().joined(separator: ", "))")
            exit(ExitCode.usage)
        }
        Output.write(text)
    } else {
        Output.write(Help.overview(Style(enabled: Output.useColor)))
    }
    exit(ExitCode.success)
case "version", "--version", "-v":
    Output.line("mship \(ShipInfo.version)")
    exit(ExitCode.success)
default:
    guard let run = commands[command] else {
        Output.error("unknown command '\(command)'. Run `mship help` for the list.")
        exit(ExitCode.usage)
    }
    if wantsHelp, let text = Help.command(command) {
        Output.write(text)
        exit(ExitCode.success)
    }
    do throws(CLIFailure) {
        exit(try run(rest))
    } catch {
        switch error {
        case .usage(let message, let name):
            Output.error(message)
            if let name { Output.write("Run `mship help \(name)` for usage.\n", to: STDERR_FILENO) }
            exit(ExitCode.usage)
        case .exit(let code):
            exit(code)
        }
    }
}
