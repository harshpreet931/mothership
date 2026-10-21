import Foundation
import ShipModel

/// Writes `mothership.js` into `<home>/.config/opencode/plugins/`. The plugin forwards a
/// filtered set of OpenCode bus events to `mship hook opencode <event>` and, for
/// `permission.asked`, waits for the app's decision and replies through OpenCode's API.
public struct OpenCodePluginInstaller: IntegrationInstaller {
    public let kind = AgentKind.opencode
    public static let marker = "mothership-opencode-plugin"
    public static let version = 1
    /// Seconds the plugin waits for a permission decision before giving up.
    public var permissionTimeout: Int

    public init(permissionTimeout: Int = 630) {
        self.permissionTimeout = permissionTimeout
    }

    public func configURL(home: URL) -> URL {
        home.appending(path: ".config/opencode/plugins/mothership.js")
    }

    public func plannedContents(_ context: IntegrationContext) throws -> String? {
        let file = configURL(home: context.home)
        let contents = Self.pluginSource(shim: context.shimPath, permissionTimeoutMs: permissionTimeout * 1000)
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            guard existing.contains(Self.marker) else { throw IntegrationError.notOurs(path: file.path) }
            if existing == contents { return nil }
        }
        return contents
    }

    @discardableResult
    public func install(_ context: IntegrationContext) throws -> InstallOutcome {
        let file = configURL(home: context.home)
        guard let contents = try plannedContents(context) else {
            try saveRecord(context, file: file, created: InstallRecordStore.record(kind, in: context.stateDirectory)?.createdFile ?? false)
            return InstallOutcome(changed: false, configPath: file)
        }
        let existed = FileManager.default.fileExists(atPath: file.path)
        let backup = try ConfigFiles.backup(file, kind: kind, context: context)
        try ConfigFiles.write(contents, to: file)
        try saveRecord(context, file: file, created: !existed)
        return InstallOutcome(changed: true, configPath: file, backup: backup)
    }

    private func saveRecord(_ context: IntegrationContext, file: URL, created: Bool) throws {
        let record = InstallRecord(
            installedAt: context.now, configPath: file.path, shimPath: context.shimPath, items: ["plugin"],
            createdFile: created, hadHooksKey: false
        )
        try InstallRecordStore.save(record, for: kind, in: context.stateDirectory)
    }

    @discardableResult
    public func uninstall(_ context: IntegrationContext) throws -> InstallOutcome {
        let file = configURL(home: context.home)
        defer { try? InstallRecordStore.save(nil, for: kind, in: context.stateDirectory) }
        guard let existing = try? String(contentsOf: file, encoding: .utf8) else {
            return InstallOutcome(changed: false, configPath: file)
        }
        guard existing.contains(Self.marker) else { throw IntegrationError.notOurs(path: file.path) }
        let backup = try ConfigFiles.backup(file, kind: kind, context: context)
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw IntegrationError.writeFailed(path: file.path, reason: error.localizedDescription)
        }
        return InstallOutcome(changed: true, configPath: file, backup: backup)
    }

    public func inspect(_ context: IntegrationContext) -> IntegrationInspection {
        let file = configURL(home: context.home)
        let record = InstallRecordStore.record(kind, in: context.stateDirectory)
        guard let existing = try? String(contentsOf: file, encoding: .utf8) else {
            return IntegrationInspection(health: record == nil ? .notInstalled : .overwritten, configPath: file.path)
        }
        guard existing.contains(Self.marker) else {
            return IntegrationInspection(health: record == nil ? .notInstalled : .overwritten, configPath: file.path, notes: ["mothership.js was replaced by another file"])
        }
        let expected = Self.pluginSource(shim: context.shimPath, permissionTimeoutMs: permissionTimeout * 1000)
        if existing == expected { return IntegrationInspection(health: .installed(count: Self.forwardedEvents.count), configPath: file.path) }
        return IntegrationInspection(health: .stale("plugin is from another Mothership version or mship path"), configPath: file.path)
    }

    static let forwardedEvents = [
        "session.created", "session.updated", "session.deleted", "session.status", "session.idle", "session.error",
        "session.compacted", "message.updated", "message.part.updated", "permission.asked", "permission.replied",
        "question.asked", "question.replied", "question.rejected",
    ]

    static func jsString(_ value: String) -> String {
        OrderedJSON.quote(value)
    }

    /// The plugin source. Plain ESM JavaScript (OpenCode runs plugins on Bun). Never throws into
    /// OpenCode; if the shim is missing it does nothing.
    public static func pluginSource(shim: String, permissionTimeoutMs: Int) -> String {
        let events = forwardedEvents.map(jsString).joined(separator: ", ")
        return """
            // \(marker) v\(version)
            // Generated by Mothership. Forwards OpenCode session events to the Mothership app via
            // `mship hook opencode <event>` and relays permission decisions made in the app.
            // Safe to delete; reinstall from Mothership > Settings > Integrations.
            import { spawn } from "node:child_process";
            import { existsSync } from "node:fs";

            const SHIM = \(jsString(shim));
            const PERMISSION_TIMEOUT_MS = \(permissionTimeoutMs);
            const FORWARDED = new Set([\(events)]);

            function send(event, body, wantReply) {
              return new Promise((resolve) => {
                if (!existsSync(SHIM)) return resolve("");
                let output = "";
                let settled = false;
                let child;
                const settle = (value) => {
                  if (settled) return;
                  settled = true;
                  clearTimeout(timer);
                  resolve(value);
                };
                const timer = setTimeout(() => {
                  try { child && child.kill(); } catch {}
                  settle("");
                }, wantReply ? PERMISSION_TIMEOUT_MS : 5000);
                try {
                  child = spawn(SHIM, ["hook", "opencode", event], {
                    stdio: ["pipe", wantReply ? "pipe" : "ignore", "ignore"],
                    env: process.env,
                  });
                } catch {
                  return settle("");
                }
                child.on("error", () => settle(""));
                if (wantReply && child.stdout) child.stdout.on("data", (chunk) => { output += chunk; });
                child.on("close", () => settle(output));
                try { child.stdin.end(JSON.stringify(body)); } catch { settle(""); }
              });
            }

            function summarizeInput(input) {
              if (!input || typeof input !== "object") return undefined;
              const out = {};
              for (const key of ["command", "filePath", "file_path", "path", "pattern", "url", "query", "description"]) {
                if (typeof input[key] === "string") out[key] = input[key].slice(0, 500);
              }
              return out;
            }

            function trimPart(part) {
              const state = part.state || {};
              return {
                id: part.id, sessionID: part.sessionID, messageID: part.messageID, type: part.type,
                callID: part.callID, tool: part.tool,
                state: { status: state.status, title: state.title, input: summarizeInput(state.input) },
              };
            }

            function trimInfo(info) {
              if (!info || typeof info !== "object") return info;
              const keep = ["id", "sessionID", "parentID", "role", "title", "directory", "modelID", "providerID", "cost", "tokens", "finish", "time"];
              const out = {};
              for (const key of keep) if (info[key] !== undefined) out[key] = info[key];
              if (info.error) out.error = { name: info.error.name };
              return out;
            }

            export const MothershipPlugin = async ({ client, directory, serverUrl }) => {
              let queue = Promise.resolve();
              const toolStatus = new Map();
              const userMessages = new Set();
              const sentParts = new Set();
              const remember = (collection, key) => {
                collection.add(key);
                if (collection.size > 1000) collection.delete(collection.values().next().value);
              };
              const forward = (event, properties) => {
                const body = { type: event, properties, directory, pid: process.pid };
                queue = queue.then(() => send(event, body, false)).catch(() => {});
              };

              async function reply(properties, decision, message) {
                const response = decision === "allow" ? "once" : "reject";
                try {
                  if (client && client.permission && typeof client.permission.reply === "function") {
                    await client.permission.reply({ requestID: properties.id, reply: response, message });
                    return;
                  }
                } catch {}
                try {
                  if (client && typeof client.postSessionIdPermissionsPermissionId === "function") {
                    await client.postSessionIdPermissionsPermissionId({
                      path: { id: properties.sessionID, permissionID: properties.id },
                      body: { response },
                    });
                    return;
                  }
                } catch {}
                try {
                  if (serverUrl) {
                    await fetch(new URL(`/permission/${encodeURIComponent(properties.id)}/reply`, serverUrl), {
                      method: "POST",
                      headers: { "content-type": "application/json" },
                      body: JSON.stringify({ reply: response, message }),
                    });
                  }
                } catch {}
              }

              async function onPermission(properties) {
                const body = { type: "permission.asked", properties, directory, pid: process.pid };
                const output = await send("permission.asked", body, true);
                let decision;
                let message;
                try {
                  const parsed = JSON.parse(output || "{}");
                  decision = parsed.decision;
                  message = parsed.message;
                } catch {}
                if (decision === "allow" || decision === "deny") await reply(properties, decision, message);
              }

              return {
                event: async ({ event }) => {
                  try {
                    if (!event || typeof event.type !== "string") return;
                    const type = event.type;
                    const p = event.properties || {};
                    if (type === "message.updated") {
                      const info = p.info || {};
                      if (info.role === "user" && info.id) remember(userMessages, info.id);
                      if (info.role !== "assistant" || !(info.time && info.time.completed)) return;
                      forward(type, { sessionID: info.sessionID, info: trimInfo(info) });
                      return;
                    }
                    if (type === "message.part.updated") {
                      const part = p.part || {};
                      if (part.type === "text" && userMessages.has(part.messageID) && !sentParts.has(part.id) && part.text) {
                        remember(sentParts, part.id);
                        forward("message.user", { sessionID: part.sessionID, text: String(part.text).slice(0, 2000) });
                        return;
                      }
                      if (part.type !== "tool") return;
                      const status = part.state && part.state.status;
                      const key = part.callID || part.id;
                      if (!key || toolStatus.get(key) === status) return;
                      toolStatus.set(key, status);
                      if (toolStatus.size > 1000) toolStatus.delete(toolStatus.keys().next().value);
                      forward(type, { sessionID: part.sessionID, part: trimPart(part) });
                      return;
                    }
                    if (!FORWARDED.has(type)) return;
                    if (type === "permission.asked") {
                      void onPermission(p);
                      return;
                    }
                    const properties = p.info ? { ...p, info: trimInfo(p.info) } : p;
                    forward(type, properties);
                  } catch {}
                },
              };
            };

            """
    }
}
