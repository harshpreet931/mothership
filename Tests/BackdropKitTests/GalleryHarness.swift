import AppKit
import CoreText
import Foundation
import Testing
import ThemeKit
@testable import BackdropKit

/// Debug harness: renders every renderer, the brief's combinations and the built-in themes as
/// stills and as two live frames 1 s apart, plus contact sheets. Opt in:
///
///     BACKDROP_GALLERY=/path/to/dir swift test --filter GalleryHarness
///
/// `BACKDROP_GALLERY_ONLY=aurora` limits it to names containing that text.
@MainActor
@Suite(.serialized) struct GalleryHarness {
    nonisolated static let directory = ProcessInfo.processInfo.environment["BACKDROP_GALLERY"]
    nonisolated static let only = ProcessInfo.processInfo.environment["BACKDROP_GALLERY_ONLY"]
    static let size = CGSize(width: 960, height: 600)

    struct Entry {
        var group: String
        var name: String
        var still: CGImage?
        var first: CGImage?
        var second: CGImage?
        var motion: Double
        var layers: Int
    }

    @Test(.enabled(if: directory != nil)) func renderGallery() throws {
        let root = URL(fileURLWithPath: try #require(Self.directory))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var entries: [Entry] = []
        let groups: [(String, [(name: String, scene: Scene?)])] = [
            ("kinds", SampleScenes.perKind.map { ($0.name, Optional($0.scene)) }),
            ("combos", SampleScenes.combos.map { ($0.name, Optional($0.scene)) }),
            ("built-in", SampleScenes.builtIns),
        ]
        var report = "name\tlayers\tchanged pixels A→B\n"
        for (group, samples) in groups {
            let folder = root.appending(path: group)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for sample in samples where Self.only.map({ sample.name.contains($0) }) ?? true {
                var entry = Entry(group: group, name: sample.name, motion: 0, layers: 0)
                if let scene = sample.scene {
                    entry.still = OffscreenRenderer.still(of: scene, size: Self.size, scale: 1)
                    (entry.first, entry.second, entry.layers) = Self.capture(scene, size: Self.size)
                    entry.motion = Self.changedFraction(entry.first, entry.second)
                }
                for (suffix, image) in [("still", entry.still), ("a", entry.first), ("b", entry.second)] {
                    if let image { try Self.writePNG(image, to: folder.appending(path: "\(sample.name)-\(suffix).png")) }
                }
                report += "\(group)/\(sample.name)\t\(entry.layers)\t\(String(format: "%.1f %%", entry.motion * 100))\n"
                entries.append(entry)
            }
        }
        try report.write(to: root.appending(path: "motion.tsv"), atomically: true, encoding: .utf8)
        for group in ["kinds", "combos", "built-in"] {
            let members = entries.filter { $0.group == group }
            guard !members.isEmpty else { continue }
            if let sheet = Self.sheet(members.map { ($0.name, [$0.still]) }, columns: 4, title: "\(group): stills") {
                try Self.writePNG(sheet, to: root.appending(path: "gallery-\(group)-stills.png"))
            }
            if let sheet = Self.sheet(members.map { ("\($0.name)  (moved \(String(format: "%.1f", $0.motion * 100)) %)", [$0.first, $0.second]) }, columns: 2, title: "\(group): live frames 1 s apart") {
                try Self.writePNG(sheet, to: root.appending(path: "gallery-\(group)-motion.png"))
            }
        }
        print(report)
    }

    /// Two live frames 1 s apart, after letting the scene run for a few seconds.
    static func capture(_ scene: Scene, size: CGSize, warmUp: TimeInterval = 4) -> (CGImage?, CGImage?, Int) {
        let stage = Stage(purpose: .live)
        stage.layout(size: size, scale: 1, topBand: 0)
        stage.apply(scene, transition: 0)
        guard let target = OffscreenRenderer.Target(size: size, scale: 1) else { return (nil, nil, 0) }
        target.attach(stage.root)
        defer { target.detach() }
        func run(for seconds: TimeInterval) {
            let end = CACurrentMediaTime() + seconds
            while CACurrentMediaTime() < end {
                target.step()
                usleep(33_000)
            }
        }
        run(for: warmUp)
        let first = target.frame()
        run(for: 1)
        let second = target.frame()
        return (first, second, stage.layerCount)
    }

    /// Share of pixels that changed visibly between two frames.
    static func changedFraction(_ a: CGImage?, _ b: CGImage?) -> Double {
        guard let a, let b, let pa = pixels(a), let pb = pixels(b), pa.count == pb.count else { return 0 }
        var changed = 0
        for index in stride(from: 0, to: pa.count, by: 4) {
            let delta = abs(Int(pa[index]) - Int(pb[index])) + abs(Int(pa[index + 1]) - Int(pb[index + 1])) + abs(Int(pa[index + 2]) - Int(pb[index + 2]))
            if delta > 6 { changed += 1 }
        }
        return Double(changed) / Double(pa.count / 4)
    }

    static func pixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: Artwork.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }

    /// A labeled grid: each row item is a caption over one or more images side by side.
    static func sheet(_ items: [(caption: String, images: [CGImage?])], columns: Int, title: String) -> CGImage? {
        let cell = CGSize(width: 480, height: 300), gap = 16.0, caption = 26.0, header = 48.0
        let perItem = items.first?.images.count ?? 1
        let itemWidth = Double(perItem) * cell.width + Double(perItem - 1) * 8
        let rows = (items.count + columns - 1) / columns
        let width = Int(Double(columns) * (itemWidth + gap) + gap)
        let height = Int(header + Double(rows) * (cell.height + caption + gap) + gap)
        guard let context = Artwork.bitmap(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ string: String, at point: CGPoint, size: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.92, alpha: 1),
            ]
            context.textPosition = point
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes)), context)
        }
        text(title, at: CGPoint(x: gap, y: Double(height) - 32), size: 20)
        for (index, item) in items.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + Double(column) * (itemWidth + gap)
            let top = Double(height) - header - Double(row) * (cell.height + caption + gap)
            text(item.caption, at: CGPoint(x: x, y: top - 18), size: 14)
            for (offset, image) in item.images.enumerated() {
                let rect = CGRect(x: x + Double(offset) * (cell.width + 8), y: top - caption - cell.height, width: cell.width, height: cell.height)
                if let image {
                    context.draw(image, in: rect)
                } else {
                    context.setFillColor(CGColor(gray: 0.3, alpha: 1))
                    context.fill(rect)
                    text("no scene (desktop)", at: CGPoint(x: rect.minX + 12, y: rect.midY), size: 14)
                }
            }
        }
        return context.makeImage()
    }
}
