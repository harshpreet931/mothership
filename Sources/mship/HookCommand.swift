import Darwin
import Foundation
import ShipModel
import ShipProtocol

/// `mship hook <agent> <event> [json-arg]`: the hot path agents run on every event.
///
/// Rules: never slow an agent down, never fail one. Anything unexpected (app not running,
/// timeout, bad args) exits 0 with no output so the agent proceeds as if no hook ran. Only a
/// reply from the app can change stdout or the exit code.
enum HookCommand {
    /// Permission prompts may be held while the user decides; the engine bounds the hold, this
    /// is a backstop slightly above it.
    static let permissionTimeout: Duration = .seconds(660)
    /// Everything else is fire-and-forget from the agent's point of view.
    static let defaultTimeout: Duration = .seconds(2)

    static func run(_ arguments: [String]) -> Never {
        let debug = getenv("MOTHERSHIP_DEBUG") != nil
        guard arguments.count >= 2, !arguments[0].isEmpty, !arguments[1].isEmpty else {
            Output.write("usage: mship hook <agent> <event> [json]\n", to: STDERR_FILENO)
            exit(0)
        }
        let event = arguments[1]

        // Codex `notify` passes the JSON as the last argv; everyone else writes it to stdin.
        let payload: Data
        if arguments.count >= 3 {
            payload = Data(arguments[2].utf8)
        } else if !Input.stdinIsTerminal {
            payload = Input.readAll()
        } else {
            payload = Data()
        }

        // Connect before building anything: when the app isn't running this is the whole cost.
        // (stdin was drained first so the agent's write never hits a closed pipe.)
        let started = ContinuousClock.now
        let caller = CallerContext.fromEnvironment()
        let client = ControlClient(socketPath: socketPath, caller: caller)
        do throws(ControlClientError) {
            try client.connect(timeout: .milliseconds(500))
        } catch {
            if debug { Output.error("hook \(event): \(error.description)") }
            exit(0)
        }

        let envelope = HookEnvelope(
            agent: AgentKind(rawValue: arguments[0]), event: event, payload: payload,
            surface: caller.surface, workspace: caller.workspace, agentPID: getppid(),
            cwd: currentDirectory, sentAt: Date()
        )
        let budget = isPermissionEvent(event) ? permissionTimeout : defaultTimeout
        let reply: HookReply
        do throws(ControlClientError) {
            let result = try client.request(ControlMethod.hook.rawValue, params: envelope.wireJSON, timeout: budget - (ContinuousClock.now - started))
            guard let decoded = try? result.decode(HookReply.self) else {
                if debug { Output.error("hook \(event): unexpected reply \(result.compactText ?? "")") }
                exit(0)
            }
            reply = decoded
        } catch {
            if debug { Output.error("hook \(event): \(error.description)") }
            exit(0)
        }
        if let stdout = reply.stdout, !stdout.isEmpty { Output.write(stdout) }
        exit(reply.exitCode)
    }

    /// Events an agent blocks on waiting for a decision ("PermissionRequest", "permission.asked", …).
    static func isPermissionEvent(_ event: String) -> Bool {
        event.range(of: "permission", options: .caseInsensitive) != nil
    }
}
