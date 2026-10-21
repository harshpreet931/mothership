// Draws Mothership's "Arch M" app icon (docs/DESIGN.md §11) into an .iconset directory.
// Usage: swift scripts/make-icon.swift <output.iconset>
// Then:  iconutil -c icns <output.iconset> -o AppIcon.icns

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha]
    ) ?? CGColor(gray: 0, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    let colors = stops.map { color($0.0, $0.1) } as CFArray
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: stops.map(\.2)) else {
        fatalError("could not build gradient")
    }
    return gradient
}

/// Renders one size. `pixels` is the bitmap edge; drawing happens in a 1024 canvas.
func draw(pixels: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    // macOS 26 icon grid: an 824-pt rounded-rect body inset 100 in the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.addPath(tile)
    context.clip()
    // Ink tile.
    context.setFillColor(color(0x0D0E11))
    context.fill(body)
    // Top radial highlight, white @ 14 %.
    context.drawRadialGradient(
        gradient([(0xFFFFFF, 0.14, 0), (0xFFFFFF, 0, 1)]),
        startCenter: CGPoint(x: 512, y: body.maxY), startRadius: 0,
        endCenter: CGPoint(x: 512, y: body.maxY), endRadius: 620, options: []
    )

    // The mark fills ~62 % of the tile width: its ink spans 84 of 120 units.
    let unit = body.width * 0.62 / 84
    // Spec y runs down; CoreGraphics runs up. The mark (y 33…89) is shifted up 1 unit so
    // its optical center (60) lands on the tile's center.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: 512 + (x - 60) * unit, y: 512 - (y - 1 - 60) * unit)
    }
    let small = pixels <= 32
    let stroke: CGFloat = small ? 12 : 10
    let discHeight: CGFloat = small ? 11 : 9

    // Disc: rect x18 y80 w84 h9 rx4.5, gradient #5B8FD6 → #C6DBFF left to right.
    let discOrigin = p(18, 80 + discHeight)
    let disc = CGRect(x: discOrigin.x, y: discOrigin.y, width: 84 * unit, height: discHeight * unit)
    context.saveGState()
    context.addPath(CGPath(roundedRect: disc, cornerWidth: discHeight / 2 * unit, cornerHeight: discHeight / 2 * unit, transform: nil))
    context.clip()
    context.drawLinearGradient(
        gradient([(0x5B8FD6, 1, 0), (0xC6DBFF, 1, 1)]),
        start: CGPoint(x: disc.minX, y: disc.midY), end: CGPoint(x: disc.maxX, y: disc.midY), options: []
    )
    context.restoreGState()

    // Arches: M28 68 V54 A16 16 0 0 1 60 54 V68 M60 54 A16 16 0 0 1 92 54 V68.
    let arches = CGMutablePath()
    arches.move(to: p(28, 68))
    arches.addLine(to: p(28, 54))
    arches.addArc(center: p(44, 54), radius: 16 * unit, startAngle: .pi, endAngle: 0, clockwise: true)
    arches.addLine(to: p(60, 68))
    arches.move(to: p(60, 54))
    arches.addArc(center: p(76, 54), radius: 16 * unit, startAngle: .pi, endAngle: 0, clockwise: true)
    arches.addLine(to: p(92, 68))
    context.addPath(arches)
    context.setStrokeColor(color(0xF4F5F7))
    context.setLineWidth(stroke * unit)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()

    // Inner top hairline, white @ 12 %, fading down the tile.
    context.saveGState()
    context.addPath(tile)
    context.setLineWidth(max(2, 3))
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
        gradient([(0xFFFFFF, 0.12, 0), (0xFFFFFF, 0, 1)]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.midY), options: []
    )
    context.restoreGState()
    return context.makeImage()
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    guard let image = draw(pixels: pixels),
          let destination = CGImageDestinationCreateWithURL(
              output.appending(path: "\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil
          )
    else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
