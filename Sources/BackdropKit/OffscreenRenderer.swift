import AppKit
import Metal
import ThemeKit

/// Renders a stage without a window through `CARenderer`, which draws what the window server
/// would: masks, filters and perspective (which `CALayer.render(in:)` skips), and emitters.
/// Falls back to `render(in:)` without Metal.
@MainActor
enum OffscreenRenderer {
    /// Where stills freeze the scene clock: any fixed time works; this one catches the
    /// aurora mid-ripple and clouds well spread.
    static let stillTime: CFTimeInterval = 47.3

    static func still(of scene: Scene, size: CGSize, scale: CGFloat, topBand: CGFloat = 0) -> CGImage? {
        guard size.width >= 1, size.height >= 1, scale > 0 else { return nil }
        let stage = Stage(purpose: .thumbnail)
        stage.layout(size: size, scale: scale, topBand: topBand)
        stage.freeze(at: stillTime)
        stage.apply(scene, transition: 0)
        return render(stage.root, size: size, scale: scale)
    }

    /// One frame of `layer` (a tree root, not in a window) at `time`.
    static func render(_ layer: CALayer, size: CGSize, scale: CGFloat, time: CFTimeInterval = CACurrentMediaTime()) -> CGImage? {
        guard let target = Target(size: size, scale: scale) else { return fallback(layer, size: size, scale: scale) }
        target.attach(layer)
        defer { target.detach() }
        return target.frame(at: time)
    }

    /// A renderer bound to one layer tree: render repeatedly to let emitters run in real time.
    final class Target {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let texture: MTLTexture
        let renderer: CARenderer
        let scale: CGFloat
        private let wrapper = CALayer()
        private var content: CALayer?

        init?(size: CGSize, scale: CGFloat) {
            let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
            guard width > 0, height > 0, width <= 16384, height <= 16384,
                  let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            self.device = device
            self.queue = queue
            self.texture = texture
            self.scale = scale
            renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue, kCARendererColorSpace: Artwork.sRGB])
            CALayer.quietly {
                wrapper.anchorPoint = .zero
                wrapper.frame = CGRect(x: 0, y: 0, width: width, height: height)
            }
            renderer.layer = wrapper
            renderer.bounds = wrapper.frame
        }

        /// Draws `layer` scaled to pixels.
        func attach(_ layer: CALayer) {
            CALayer.quietly {
                layer.anchorPoint = .zero
                layer.position = .zero
                layer.transform = CATransform3DMakeScale(scale, scale, 1)
                wrapper.addSublayer(layer)
            }
            content = layer
            CATransaction.flush()
        }

        func detach() {
            CALayer.quietly {
                content?.removeFromSuperlayer()
                content?.transform = CATransform3DIdentity
            }
            content = nil
        }

        func frame(at time: CFTimeInterval = CACurrentMediaTime()) -> CGImage? {
            clear()
            renderer.beginFrame(atTime: time, timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            guard let buffer = queue.makeCommandBuffer() else { return nil }
            buffer.commit()
            buffer.waitUntilCompleted()
            return image()
        }

        private func clear() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.endEncoding()
            buffer.commit()
        }

        /// The texture's rows run bottom-up (layer space); images run top-down.
        private func image() -> CGImage? {
            let width = texture.width, height = texture.height, rowBytes = width * 4
            var bytes = [UInt8](repeating: 0, count: rowBytes * height)
            texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            var flipped = [UInt8](repeating: 0, count: bytes.count)
            for row in 0 ..< height {
                let source = row * rowBytes, destination = (height - 1 - row) * rowBytes
                flipped.replaceSubrange(destination ..< destination + rowBytes, with: bytes[source ..< source + rowBytes])
            }
            guard let provider = CGDataProvider(data: Data(flipped) as CFData) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: Artwork.sRGB,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }
    }

    /// Without Metal: masks, filters and 3D transforms are skipped; better than nothing.
    private static func fallback(_ layer: CALayer, size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let context = Artwork.bitmap(width: width, height: height) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }
}
