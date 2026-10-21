import Foundation
import Testing
import AttentionKit
import BrowserKit
import ShipModel

// WKWebView needs the main thread; the self-test drives a real web view end to end
// (snapshot refs, React-style fill, click, eval, console capture, screenshot, picker).
@MainActor
@Test func browserSelfTestPasses() async {
    let report = await BrowserSelfTest.run()
    #expect(report.passed, "\(report.failures.map { "\($0.name): \($0.detail)" })")
}

@Test func permissionNotificationNamesAgentAndWorkspace() {
    let session = AgentSessionKey(kind: .claude, sessionID: "s1")
    let request = PermissionRequest(
        session: session, surface: SurfaceID(), toolName: "Bash", summary: "npm run migrate",
        expiresAt: Date().addingTimeInterval(600)
    )
    let event = AttentionEvent(
        kind: .permission(request), session: session, surface: request.surface,
        title: "Permission", body: "npm run migrate", shouldNotify: true
    )
    let content = NotificationContent.make(for: event, workspaceName: "api-server")
    let rendered = "\(content)"
    #expect(rendered.contains("Claude Code"))
    #expect(rendered.contains("api-server"))
}
