// swift-tools-version: 6.2
import PackageDescription

// One package, many modules. Dependency arrows point down only:
//   MothershipApp → feature modules → ShipProtocol → ShipModel
// The `mship` CLI links only ShipProtocol + ShipModel so hook calls stay fast.
let package = Package(
    name: "Mothership",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "2.2.2026101901"),
    ],
    targets: [
        // Shared contracts: pure value types and service protocols. Foundation only.
        .target(name: "ShipModel"),
        // Wire format for the control socket (JSON-RPC 2.0, newline-delimited).
        .target(name: "ShipProtocol", dependencies: ["ShipModel"]),

        // libproc / sysctl / kqueue / FSEvents wrappers.
        .target(name: "SystemProbe", dependencies: ["ShipModel"]),
        // Agent adapters, signal reducer, transcript tailing, hook installers.
        .target(name: "AgentKit", dependencies: ["ShipModel", "ShipProtocol", "SystemProbe"]),
        // Unix-socket JSON-RPC server + MCP tool definitions.
        .target(name: "ControlPlane", dependencies: ["ShipModel", "ShipProtocol"]),
        // WKWebView surface, automation (snapshot/click/fill/eval/console), element picker.
        .target(name: "BrowserKit", dependencies: ["ShipModel"]),
        // UNUserNotificationCenter, actionable notifications, Dock badge.
        .target(name: "AttentionKit", dependencies: ["ShipModel"]),
        // Git: repo info, worktrees, diffs, GitHub PR status via `gh`.
        .target(name: "GitKit", dependencies: ["ShipModel"]),
        // Session host protocol + client: PTYs owned by `mshipd` so shells outlive the app.
        .target(name: "SessionHost", dependencies: ["ShipModel"]),
        // On-device intelligence (Apple Foundation Models): titles and summaries.
        .target(name: "Intelligence", dependencies: ["ShipModel"]),
        // libghostty surface wrapper behind a small protocol.
        .target(
            name: "TerminalEngine",
            dependencies: [
                "ShipModel", "SessionHost",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
            ]
        ),

        // The app (bundled into Mothership.app by scripts/bundle.sh).
        .executableTarget(
            name: "MothershipApp",
            dependencies: [
                "ShipModel", "ShipProtocol", "SystemProbe", "AgentKit",
                "ControlPlane", "BrowserKit", "AttentionKit", "TerminalEngine",
                "GitKit", "SessionHost", "Intelligence",
            ]
        ),
        // The CLI used by agent hooks, scripts, and `mship mcp`.
        .executableTarget(name: "mship", dependencies: ["ShipModel", "ShipProtocol"]),
        // Session daemon: owns PTYs and output buffers; the app attaches and renders.
        .executableTarget(name: "mshipd", dependencies: ["ShipModel", "SessionHost"]),
        // Dev tool: dump what the agent engine sees on this machine.
        .executableTarget(name: "mship-probe", dependencies: ["ShipModel", "SystemProbe", "AgentKit"]),

        .testTarget(name: "ShipModelTests", dependencies: ["ShipModel", "ShipProtocol"]),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit", "ShipModel", "ShipProtocol"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SystemProbeTests", dependencies: ["SystemProbe"]),
        .testTarget(name: "ControlPlaneTests", dependencies: ["ControlPlane", "ShipProtocol", "ShipModel"]),
        .testTarget(name: "BrowserKitTests", dependencies: ["BrowserKit", "AttentionKit", "ShipModel"]),
        .testTarget(name: "TerminalEngineTests", dependencies: ["TerminalEngine"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "SessionHostTests", dependencies: ["SessionHost"]),
    ],
    swiftLanguageModes: [.v6]
)
