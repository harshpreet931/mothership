import AppKit
import Foundation
import ShipModel

/// An end-to-end exercise of `BrowserSession` against a local fixture page: snapshot, refs,
/// click, fill (including a React-style value tracker), select, checkbox, eval, console
/// capture, screenshot and the element picker. Wire it to a debug menu item, or run it from a
/// test target that links BrowserKit. Needs a main run loop (an app, or a test process).
@MainActor
public enum BrowserSelfTest {
    public struct Check: Sendable, Equatable {
        public var name: String
        public var passed: Bool
        public var detail: String
    }

    public struct Report: Sendable, CustomStringConvertible {
        public var checks: [Check]
        public var snapshot: String
        public var passed: Bool { checks.allSatisfy(\.passed) }
        public var failures: [Check] { checks.filter { !$0.passed } }

        public var description: String {
            checks.map { "\($0.passed ? "✓" : "✗") \($0.name)\($0.detail.isEmpty ? "" : " — \($0.detail)")" }.joined(separator: "\n")
        }
    }

    public static let fixture = #"""
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Self Test</title>
    <style>body { font: 14px -apple-system; margin: 0; } #swatch { width: 120px; height: 60px; background: rgb(255, 0, 0); }</style>
    </head><body>
    <header><h1>Acme</h1><nav aria-label="Main"><a href="#docs">Docs</a> <a href="https://example.com/about">About</a></nav></header>
    <main>
      <form id="login" onsubmit="event.preventDefault(); document.getElementById('status').textContent = 'submitted:' + document.getElementById('email').value;">
        <label for="email">Email</label> <input id="email" type="email" placeholder="you@example.com">
        <label>Password <input id="pw" type="password" value="hunter2"></label>
        <label><input id="remember" type="checkbox"> Remember me</label>
        <select id="plan" aria-label="Plan"><option value="free">Free</option><option value="pro">Pro</option></select>
        <button type="submit">Sign in</button>
      </form>
      <p id="status">idle</p>
      <div id="clicky" style="cursor: pointer" onclick="this.textContent = 'clicked'">Click me</div>
      <div hidden>Secret hidden text</div>
      <div style="display: none"><button>Invisible button</button></div>
      <div id="swatch" class="swatch primary"></div>
    </main>
    <script>
      // React tracks input values with an instance property; a plain `el.value = x` in the page
      // world updates the tracker and React never sees a change. This reproduces that check.
      const email = document.getElementById('email');
      const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
      let tracked = email.value;
      Object.defineProperty(email, 'value', { configurable: true,
        get() { return native.get.call(this); }, set(v) { tracked = String(v); native.set.call(this, v); } });
      window.reactSawChange = false;
      window.inputEvents = 0;
      email.addEventListener('input', () => {
        window.inputEvents++;
        const actual = native.get.call(email);
        if (actual !== tracked) { tracked = actual; window.reactSawChange = true; }
      });
      window.planChanges = 0;
      document.getElementById('plan').addEventListener('change', () => window.planChanges++);
      console.log('hello', { a: 1 });
      console.warn('careful');
      setTimeout(() => { throw new Error('boom'); }, 0);
      Promise.reject(new Error('nope'));
      fetch('http://127.0.0.1:9/unreachable').catch(() => {});
    </script>
    </body></html>
    """#

    /// Runs every check. `showWindow` puts the pane in a visible window instead of an off-screen one.
    public static func run(showWindow: Bool = false) async -> Report {
        _ = NSApplication.shared
        var checks: [Check] = []
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            checks.append(Check(name: name, passed: condition, detail: condition ? "" : detail()))
        }

        let session = BrowserSession(workspace: nil, dataStore: .ephemeral)
        let view = BrowserSurfaceView(session: session)
        let window = NSWindow(
            contentRect: NSRect(x: showWindow ? 200 : -20_000, y: showWindow ? 200 : -20_000, width: 1000, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        if showWindow { window.makeKeyAndOrderFront(nil) } else { window.orderBack(nil) }
        defer { window.close() }

        await session.loadHTML(fixture, baseURL: URL(string: "http://selftest.localhost/"))
        try? await Task.sleep(for: .milliseconds(150))  // let the fixture's timers and rejections fire

        // Snapshot
        var outline = ""
        do {
            outline = try await session.snapshot().outline
        } catch {
            check("snapshot", false, error.localizedDescription)
            return Report(checks: checks, snapshot: "")
        }
        check("snapshot: heading", outline.contains(#"heading "Acme" [level=1]"#), outline)
        check("snapshot: labelled textbox", outline.contains(#"textbox "Email""#), outline)
        check("snapshot: button", outline.contains(#"button "Sign in""#), outline)
        check("snapshot: checkbox", outline.contains(#"checkbox "Remember me""#), outline)
        check("snapshot: select", outline.contains(#"combobox "Plan" value="Free""#), outline)
        check("snapshot: link with href", outline.contains(#"link "Docs" (/#docs)"#), outline)
        check("snapshot: JS-clickable div", outline.contains(#"clickable "Click me""#), outline)
        check("snapshot: landmark", outline.contains(#"navigation "Main""#), outline)
        check("snapshot: text", outline.contains(#"text: "idle""#), outline)
        check("snapshot: hidden content skipped", !outline.contains("Secret hidden text") && !outline.contains("Invisible button"), outline)
        check("snapshot: password masked", !outline.contains("hunter2") && outline.contains(#"value="[hidden]""#), outline)

        let emailRef = ref(in: outline, after: #"textbox "Email""#)
        let buttonRef = ref(in: outline, after: #"button "Sign in""#)
        check("snapshot: refs assigned", emailRef != nil && buttonRef != nil, outline)
        let again = (try? await session.snapshot().outline) ?? ""
        check("snapshot: refs stable", emailRef != nil && ref(in: again, after: #"textbox "Email""#) == emailRef, again)

        // Fill
        do {
            try await session.fill(ref: emailRef ?? "#email", text: "a@b.co")
            check("fill: value set", try await session.evaluate("document.getElementById('email').value") == .string("a@b.co"))
            check("fill: React-style tracker saw the change", try await session.evaluate("window.reactSawChange") == .bool(true))
            try await session.fill(ref: "#plan", text: "Pro")
            check("fill: select by label", try await session.evaluate("[document.getElementById('plan').value, window.planChanges]") == .array([.string("pro"), .number(1)]))
            try await session.fill(ref: "#remember", text: "true")
            check("fill: checkbox", try await session.evaluate("document.getElementById('remember').checked") == .bool(true))
        } catch {
            check("fill", false, error.localizedDescription)
        }

        // Click
        do {
            try await session.click(ref: buttonRef ?? "button[type=submit]")
            check("click: submit button submits", try await session.evaluate("document.getElementById('status').textContent") == .string("submitted:a@b.co"))
            try await session.click(ref: "#clicky")
            check("click: JS handler on div", try await session.evaluate("document.getElementById('clicky').textContent") == .string("clicked"))
        } catch {
            check("click", false, error.localizedDescription)
        }

        // Errors the agent can act on
        do {
            try await session.click(ref: "e99999")
            check("error: unknown ref", false, "no error thrown")
        } catch {
            check("error: unknown ref", error.localizedDescription.contains("No element with ref e99999"), error.localizedDescription)
        }
        do {
            try await session.fill(ref: "#status", text: "x")
            check("error: not fillable", false, "no error thrown")
        } catch {
            check("error: not fillable", error.localizedDescription.contains("isn't a form field"), error.localizedDescription)
        }

        // Evaluate
        do {
            check("eval: expression", try await session.evaluate("document.title") == .string("Self Test"))
            check("eval: body with return", try await session.evaluate("const x = 2; return { a: x, b: [true, null] };")
                == .object(["a": .number(2), "b": .array([.bool(true), .null])]))
            check("eval: await", try await session.evaluate("await new Promise(r => setTimeout(() => r(42), 10))") == .number(42))
            check("eval: undefined is null", try await session.evaluate("undefined") == .null)
            check("eval: DOM node serialized", (try await session.evaluate("document.getElementById('status')")).stringValue?.contains("<p id=\"status\">") == true)
        } catch {
            check("eval", false, error.localizedDescription)
        }
        do {
            _ = try await session.evaluate("throw new Error('kaput')")
            check("eval: exceptions surface", false, "no error thrown")
        } catch {
            check("eval: exceptions surface", error.localizedDescription.contains("kaput"), error.localizedDescription)
        }

        // Console
        try? await Task.sleep(for: .milliseconds(300))
        let console = session.consoleEntries()
        let lines = console.map { "[\($0.level)] \($0.message)" }.joined(separator: "\n")
        check("console: log", console.contains { $0.level == "log" && $0.message == #"hello {"a":1}"# }, lines)
        check("console: warn", console.contains { $0.level == "warn" && $0.message == "careful" }, lines)
        check("console: uncaught exception", console.contains { $0.level == "exception" && $0.message.contains("boom") }, lines)
        check("console: unhandled rejection", console.contains { $0.level == "rejection" && $0.message.contains("nope") }, lines)
        check("console: failed fetch", console.contains { $0.level == "network" && $0.message.contains("127.0.0.1:9") }, lines)

        // Screenshot
        do {
            let url = try await session.screenshot()
            let data = try Data(contentsOf: url)
            check("screenshot: PNG written", data.starts(with: [0x89, 0x50, 0x4E, 0x47]) && data.count > 1000, url.path)
        } catch {
            check("screenshot", false, error.localizedDescription)
        }

        // Element picker: drive it with synthetic pointer events from the page.
        let picked = PickBox()
        session.onElementPicked = { picked.element = $0 }
        await session.setPicking(true)
        check("picker: active", session.isPicking)
        _ = try? await session.evaluate("""
            const el = document.getElementById('swatch');
            const r = el.getBoundingClientRect();
            const at = { bubbles: true, cancelable: true, composed: true, clientX: r.left + 10, clientY: r.top + 10 };
            el.dispatchEvent(new MouseEvent('mousemove', at));
            el.dispatchEvent(new MouseEvent('click', at));
            return true;
            """)
        for _ in 0..<100 where picked.element == nil { try? await Task.sleep(for: .milliseconds(20)) }
        if let element = picked.element {
            check("picker: selector", element.selector == "#swatch", element.selector)
            check("picker: styles", element.styles["background-color"] == "rgb(255, 0, 0)", "\(element.styles)")
            check("picker: rect", abs(element.rect.width - 120) < 1 && abs(element.rect.height - 60) < 1, "\(element.rect)")
            check("picker: stopped after pick", !session.isPicking)
            if let path = element.screenshotPath, let image = NSImage(contentsOfFile: path) {
                check("picker: crop is the element", isMostlyRed(image), path)
            } else {
                check("picker: crop", false, "no screenshot")
            }
        } else {
            check("picker: picked an element", false, "onElementPicked never fired")
        }
        await session.setPicking(false)

        // URL normalization
        check("url: localhost:3000", BrowserURL.normalize("localhost:3000")?.absoluteString == "http://localhost:3000")
        check("url: :5173", BrowserURL.normalize(":5173")?.absoluteString == "http://localhost:5173")
        check("url: example.com", BrowserURL.normalize("example.com/docs")?.absoluteString == "https://example.com/docs")
        check("url: search", BrowserURL.normalize("swift concurrency")?.host() == "www.google.com")

        return Report(checks: checks, snapshot: outline)
    }

    private final class PickBox {
        var element: PickedElement?
    }

    private static func ref(in outline: String, after marker: String) -> String? {
        guard let line = outline.split(separator: "\n").first(where: { $0.contains(marker) }),
              let match = line.firstMatch(of: /\[ref=(e\d+)\]/) else { return nil }
        return String(match.1)
    }

    /// The crop includes 8 pt of padding around the swatch; most pixels should be red.
    private static func isMostlyRed(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return false }
        var red = 0
        var total = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                if color.redComponent > 0.85 && color.greenComponent < 0.25 && color.blueComponent < 0.25 { red += 1 }
            }
        }
        return total > 0 && Double(red) / Double(total) > 0.4
    }
}
