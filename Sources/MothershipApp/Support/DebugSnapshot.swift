import AppKit
import Observation
import SwiftUI

/// While a debug snapshot renders, glass drops its material (which `cacheDisplay` draws as
/// an opaque fallback) and shows only its true tint.
@MainActor
@Observable
final class SnapshotMode {
    static let shared = SnapshotMode()
    var active = false
    private init() {}
}

/// `MOTHERSHIP_SNAPSHOT=/path.png`: a PNG of the main window shortly after launch, for
/// verifying UI without screen-recording permission.
///
/// `cacheDisplay` can't see the Metal sky, Metal-presented terminal frames, materials or
/// layer shadows, so the image is composited layer by layer: the sky (rendered with
/// `ImageRenderer`), the pane canvas with each terminal's IOSurface frame and the attention
/// halos, then every SwiftUI chrome layer in z-order. Glass shows its tint without blur,
/// which over a soft sky is a faithful stand-in.
@MainActor
enum DebugSnapshot {
    /// `MOTHERSHIP_SNAPSHOT_VIEW`: home | fleet | palette | settings[:agents|appearance|notifications|keys].
    static func prepareView(_ view: String?, model: AppModel) {
        SkyMotion.shared.forcePaused = true
        guard let view, !view.isEmpty else { return }
        let parts = view.split(separator: ":").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            switch parts[0] {
            case "home": model.show(.home)
            case "fleet": model.show(.fleet)
            case "palette": model.isPalettePresented = true
            case "settings": model.openSettings(parts.count > 1 ? SettingsTab(rawValue: parts[1]) : .agents)
            default: break
            }
        }
    }

    static func schedule(to path: String, after delay: TimeInterval = 2.4, window: MainWindowController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.4) {
            SnapshotMode.shared.active = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
            guard let window else { return }
            NSLog("Mothership: snapshot %@", capture(window, to: URL(fileURLWithPath: path)) ? path : "failed")
            SnapshotMode.shared.active = false
            logGeometry(window)
            if let focused = window.model.focusedSurface, let text = focused.terminal?.readScreenText(scrollbackLines: 0) {
                NSLog("Mothership: focused pane %@ screen:\n%@", focused.id.description, text)
            }
        }
    }

    static func capture(_ controller: MainWindowController, to url: URL) -> Bool {
        guard let window = controller.window, let root = window.contentView as? RootView else { return false }
        root.layoutSubtreeIfNeeded()
        let bounds = root.bounds
        let scale = window.backingScaleFactor
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }
        // The context takes its point→pixel scale from the rep's size, so set it first.
        output.size = bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: output) else { return false }
        let model = controller.model
        // Root is flipped (top-left origin); the bitmap context isn't.
        let height = bounds.height
        func cg(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            // 1. Sky.
            drawSky(model: model, size: bounds.size, dark: root.effectiveAppearance.isDark)

            // 2. Canvas: halos, cards, the terminals' own frames, dim, ring, in-card chrome.
            if !root.canvas.isHidden, let workspace = model.selectedWorkspace, let view = root.canvas.selectedWorkspaceView {
                for (id, frame) in view.paneFrames() {
                    let rect = cg(view.convert(frame, to: root))
                    let path = NSBezierPath(roundedRect: rect, xRadius: Sky.radiusPane, yRadius: Sky.radiusPane)
                    if model.paneNeedsAttention(id) {
                        NSGraphicsContext.saveGraphicsState()
                        let glow = NSShadow()
                        glow.shadowColor = NSColor.skyAttention.withAlphaComponent(0.85)
                        glow.shadowBlurRadius = 18
                        glow.set()
                        NSColor.skyAttention.setFill()
                        path.fill()
                        NSGraphicsContext.restoreGraphicsState()
                    } else if !root.effectiveAppearance.isDark {
                        // Day elevation: 0 8 24 ink @ 8 %.
                        NSGraphicsContext.saveGraphicsState()
                        let shadow = NSShadow()
                        shadow.shadowColor = NSColor.skyInk.withAlphaComponent(id == workspace.focusedSurface?.id ? 0.16 : 0.08)
                        shadow.shadowBlurRadius = 24
                        shadow.shadowOffset = NSSize(width: 0, height: -8)
                        shadow.set()
                        NSColor.black.setFill()
                        path.fill()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    drawCached(view: view, rect: frame, at: rect)
                    guard let surface = workspace.surfaces[id], let terminal = surface.terminal else { continue }
                    if let image = terminal.snapshotImage() {
                        NSGraphicsContext.saveGraphicsState()
                        path.addClip()
                        image.draw(in: cg(terminal.view.convert(terminal.view.bounds, to: root)))
                        if workspace.visibleSurfaceIDs.count > 1, id != workspace.focusedSurface?.id {
                            NSColor.black.withAlphaComponent(0.14).setFill()
                            rect.fill(using: .sourceOver)
                        }
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    for subview in terminal.view.superview?.subviews ?? [] where subview is NSHostingView<ResumeBanner> || subview is NSHostingView<PaneChrome> {
                        guard !subview.isHidden, subview.alphaValue > 0.01 else { continue }
                        drawCached(view: subview, rect: subview.bounds, at: cg(subview.convert(subview.bounds, to: root)))
                    }
                    if workspace.visibleSurfaceIDs.count > 1, id == workspace.focusedSurface?.id {
                        NSColor.skyInk.withAlphaComponent(0.18).setStroke()
                        let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Sky.radiusPane, yRadius: Sky.radiusPane)
                        ring.lineWidth = 1
                        ring.stroke()
                    }
                }
            }

            // 3. Chrome layers in z-order.
            for layer in root.chromeLayers where !layer.isHidden && layer.alphaValue > 0.01 && layer.frame.maxX > 0 {
                drawCached(view: layer, rect: layer.bounds, at: cg(layer.frame))
            }

            // 4. The window buttons, where AppKit put them.
            drawWindowButtons(window: window, in: root, convert: cg)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = output.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private static func drawSky(model: AppModel, size: NSSize, dark: Bool) {
        let preset = model.resolvedSky
        guard preset != .desktop else {
            NSColor(white: dark ? 0.16 : 0.82, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            return
        }
        let renderer = ImageRenderer(content: SkyBackdrop(preset: preset, frozenTime: 0).frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        NSImage(cgImage: image, size: size).draw(in: NSRect(origin: .zero, size: size))
    }

    /// `cacheDisplay` of `view` (its `rect`), drawn at `target` (bitmap coordinates).
    private static func drawCached(view: NSView, rect: NSRect, at target: NSRect) {
        guard rect.width > 0, rect.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        guard let image = rep.cgImage else { return }
        NSImage(cgImage: image, size: rect.size).draw(in: target)
    }

    /// The traffic lights live outside contentView; draw them where AppKit put them.
    private static func drawWindowButtons(window: NSWindow, in root: NSView, convert: (NSRect) -> NSRect) {
        let buttons: [(NSWindow.ButtonType, NSColor)] = [
            (.closeButton, NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1)),
            (.miniaturizeButton, NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1)),
            (.zoomButton, NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)),
        ]
        for (type, color) in buttons {
            guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
            let frame = convert(root.convert(superview.convert(button.frame, to: nil), from: nil))
            color.setFill()
            let side = min(frame.width, frame.height) - 2
            NSBezierPath(ovalIn: NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)).fill()
        }
    }

    /// Where the window buttons ended up, and whether a click in the top bar reaches our
    /// views rather than the titlebar.
    private static func logGeometry(_ controller: MainWindowController) {
        guard let window = controller.window, let root = window.contentView, let themeFrame = root.superview,
              let close = window.standardWindowButton(.closeButton), let superview = close.superview else { return }
        let frame = root.convert(superview.convert(close.frame, to: nil), from: nil)
        NSLog("Mothership: close button center (%.1f, %.1f) in root (flipped)", frame.midX, frame.midY)
        for x in [100.0, Double(root.bounds.midX), Double(root.bounds.width - 60)] {
            let windowPoint = root.convert(NSPoint(x: x, y: 26), to: nil)
            let hit = themeFrame.hitTest(themeFrame.convert(windowPoint, from: nil))
            NSLog("Mothership: top-bar hit at x=%.0f → %@", x, hit.map { String(describing: type(of: $0)) } ?? "nil")
        }
    }
}
