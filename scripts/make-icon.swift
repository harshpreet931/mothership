// Draws Mothership's app icon with CoreGraphics into an .iconset directory.
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
    let locations = stops.map(\.2)
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else {
        fatalError("could not build gradient")
    }
    return gradient
}

/// Squircle-ish rounded rect matching the macOS icon grid (824/1024 body, ~185 radius).
func bodyPath(in rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2245, cornerHeight: rect.width * 0.2245, transform: nil)
}

func draw(size: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = bodyPath(in: body)

    // Drop shadow under the body.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.45))
    context.addPath(path)
    context.setFillColor(color(0x0B0D1A))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()

    // Deep-space background.
    context.drawLinearGradient(
        gradient([(0x232A5C, 1, 0), (0x0F1230, 1, 0.55), (0x05060F, 1, 1)]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
    )
    // Nebula glow behind the planet.
    context.drawRadialGradient(
        gradient([(0x7C8CFF, 0.55, 0), (0x5B4FD6, 0.18, 0.45), (0x000000, 0, 1)]),
        startCenter: CGPoint(x: 540, y: 560), startRadius: 0,
        endCenter: CGPoint(x: 540, y: 560), endRadius: 470, options: []
    )
    context.drawRadialGradient(
        gradient([(0xF59E42, 0.22, 0), (0x000000, 0, 1)]),
        startCenter: CGPoint(x: 780, y: 300), startRadius: 0,
        endCenter: CGPoint(x: 780, y: 300), endRadius: 300, options: []
    )

    // Stars.
    let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (230, 800, 5, 0.9), (330, 870, 3, 0.6), (790, 830, 4, 0.8), (870, 700, 3, 0.55),
        (190, 560, 3, 0.5), (260, 330, 4, 0.7), (420, 200, 3, 0.45), (850, 470, 2.5, 0.5),
        (660, 880, 2.5, 0.5), (560, 760, 2, 0.35), (160, 420, 2, 0.4), (700, 190, 3, 0.5),
    ]
    for (x, y, r, a) in stars {
        context.setFillColor(color(0xFFFFFF, a))
        context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    let center = CGPoint(x: 512, y: 532)
    let tilt = -0.36
    let orbitRect = CGRect(x: center.x - 360, y: center.y - 118, width: 720, height: 236)

    func orbitPath() -> CGPath {
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt).translatedBy(x: -center.x, y: -center.y)
        return CGPath(ellipseIn: orbitRect, transform: &transform)
    }

    func strokeOrbit(front: Bool) {
        context.saveGState()
        // Clip to the half of the ellipse in front of / behind the planet.
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt).translatedBy(x: -center.x, y: -center.y)
        let half = front
            ? CGRect(x: orbitRect.minX - 40, y: orbitRect.minY - 40, width: orbitRect.width + 80, height: orbitRect.height / 2 + 40)
            : CGRect(x: orbitRect.minX - 40, y: center.y, width: orbitRect.width + 80, height: orbitRect.height / 2 + 40)
        context.addPath(CGPath(rect: half, transform: &transform))
        context.clip()
        context.addPath(orbitPath())
        context.setLineWidth(19)
        context.setLineCap(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(
            gradient(front
                ? [(0xE4E7FF, 1, 0), (0xA9B2FF, 1, 0.5), (0x7C8CFF, 0.9, 1)]
                : [(0x7C8CFF, 0.35, 0), (0xA9B2FF, 0.55, 1)]),
            start: CGPoint(x: orbitRect.minX, y: center.y), end: CGPoint(x: orbitRect.maxX, y: center.y), options: []
        )
        context.restoreGState()
    }

    // Back half of the ring, then the planet, then the front half.
    strokeOrbit(front: false)

    let planetRadius: CGFloat = 196
    let planet = CGRect(x: center.x - planetRadius, y: center.y - planetRadius, width: planetRadius * 2, height: planetRadius * 2)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 60, color: color(0x7C8CFF, 0.65))
    context.setFillColor(color(0x5A63F0))
    context.fillEllipse(in: planet)
    context.restoreGState()
    context.saveGState()
    context.addEllipse(in: planet)
    context.clip()
    context.drawLinearGradient(
        gradient([(0xB7BEFF, 1, 0), (0x7C8CFF, 1, 0.45), (0x3B3FB8, 1, 1)]),
        start: CGPoint(x: center.x - 120, y: planet.maxY), end: CGPoint(x: center.x + 110, y: planet.minY), options: []
    )
    // Terminator shading on the lower right.
    context.drawRadialGradient(
        gradient([(0x000000, 0, 0.55), (0x0A0B2A, 0.55, 1)]),
        startCenter: CGPoint(x: center.x - 70, y: center.y + 70), startRadius: 0,
        endCenter: CGPoint(x: center.x - 70, y: center.y + 70), endRadius: planetRadius * 1.45, options: []
    )
    // Prompt glyph: "›_" etched into the planet.
    context.setStrokeColor(color(0xFFFFFF, 0.92))
    context.setLineWidth(30)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: center.x - 92, y: center.y + 62))
    context.addLine(to: CGPoint(x: center.x - 18, y: center.y))
    context.addLine(to: CGPoint(x: center.x - 92, y: center.y - 62))
    context.strokePath()
    context.move(to: CGPoint(x: center.x + 18, y: center.y - 70))
    context.addLine(to: CGPoint(x: center.x + 100, y: center.y - 70))
    context.strokePath()
    // Specular highlight.
    context.drawRadialGradient(
        gradient([(0xFFFFFF, 0.55, 0), (0xFFFFFF, 0, 1)]),
        startCenter: CGPoint(x: center.x - 95, y: center.y + 110), startRadius: 0,
        endCenter: CGPoint(x: center.x - 95, y: center.y + 110), endRadius: 120, options: []
    )
    context.restoreGState()

    strokeOrbit(front: true)

    // The satellite: an agent out on the ring, in attention orange.
    let moonAngle: CGFloat = -0.32 * .pi
    let local = CGPoint(x: center.x + 360 * cos(moonAngle), y: center.y + 118 * sin(moonAngle))
    let moon = local.applying(
        CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt).translatedBy(x: -center.x, y: -center.y)
    )
    context.saveGState()
    context.setShadow(offset: .zero, blur: 40, color: color(0xF59E42, 0.95))
    context.setFillColor(color(0xFFB45E))
    context.fillEllipse(in: CGRect(x: moon.x - 38, y: moon.y - 38, width: 76, height: 76))
    context.restoreGState()
    context.setFillColor(color(0xFFE2B8, 0.9))
    context.fillEllipse(in: CGRect(x: moon.x - 20, y: moon.y + 2, width: 22, height: 22))

    // Glass edge: top sheen and a hairline.
    context.drawLinearGradient(
        gradient([(0xFFFFFF, 0.16, 0), (0xFFFFFF, 0, 0.35)]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: []
    )
    context.restoreGState()
    context.addPath(path)
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.setLineWidth(3)
    context.strokePath()
    return context.makeImage()
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    guard let image = draw(size: size),
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
