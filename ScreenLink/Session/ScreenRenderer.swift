import MetalKit
import UIKit

private struct QuadUniforms {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float> = SIMD4(0, 0, 1, 1)
    var opaque: Float
    var pad: SIMD3<Float> = .zero
}

/// Draws the remote framebuffer and a locally-rendered cursor with Metal.
/// Framebuffer uploads happen on the network thread (only dirty rects);
/// drawing happens on the main thread whenever the view or content changes.
final class ScreenRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let nearestSampler: MTLSamplerState

    private let lock = NSLock()
    private var texture: MTLTexture?
    private var needsMipmaps = false
    private var lastMipmapTime: CFTimeInterval = 0
    /// Set by the view controller: false when zoomed in enough that mipmaps aren't sampled.
    var mipmapsWanted = true
    private var cursorTexture: MTLTexture?
    private var cursorSize = CGSize.zero
    private var cursorHot = CGPoint.zero

    /// Set by the view controller on the main thread before each draw.
    var contentRect: CGRect = .zero        // where the visible part of the framebuffer is drawn, in view points
    var textureRect = CGRect(x: 0, y: 0, width: 1, height: 1)  // which part of the framebuffer (normalized)
    var cursorPoint: CGPoint?              // cursor tip in view points
    var cursorScale: CGFloat = 0.5         // points per cursor pixel
    var useNearestFiltering = false
    /// Called at the start of each frame on the main thread (drives animations/momentum).
    var onDraw: (() -> Void)?

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: ScreenRenderer.shaderSource, options: nil) else { return nil }
        self.device = device
        self.queue = queue

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "quad_vertex")
        desc.fragmentFunction = library.makeFunction(name: "quad_fragment")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        let ca = desc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let p = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        pipeline = p

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!
        sd.magFilter = .nearest
        nearestSampler = device.makeSamplerState(descriptor: sd)!

        super.init()
        view.device = device
        view.delegate = self
    }

    // MARK: Uploads (any thread)

    func upload(_ fb: Framebuffer, dirty: [CGRect]) {
        lock.lock(); defer { lock.unlock() }
        var full = false
        if texture == nil || texture!.width != fb.width || texture!.height != fb.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: fb.width,
                                                             height: fb.height, mipmapped: true)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            texture = device.makeTexture(descriptor: d)
            full = true
        }
        guard let tex = texture else { return }
        let rects = full ? [CGRect(x: 0, y: 0, width: fb.width, height: fb.height)] : dirty
        for r in rects {
            let x = max(0, Int(r.minX)), y = max(0, Int(r.minY))
            let w = min(fb.width - x, Int(r.width)), h = min(fb.height - y, Int(r.height))
            guard w > 0, h > 0 else { continue }
            tex.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0,
                        withBytes: fb.pixels + y * fb.width + x, bytesPerRow: fb.width * 4)
        }
        needsMipmaps = true
    }

    func setCursor(_ c: CursorImage?) {
        lock.lock(); defer { lock.unlock() }
        guard let c, c.width > 0, c.height > 0 else {
            cursorTexture = nil
            cursorSize = .zero
            return
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: c.width,
                                                         height: c.height, mipmapped: false)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return }
        c.pixels.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, c.width, c.height), mipmapLevel: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: c.width * 4)
        }
        cursorTexture = t
        cursorSize = CGSize(width: c.width, height: c.height)
        cursorHot = CGPoint(x: c.hotX, y: c.hotY)
    }

    var hasTexture: Bool { lock.lock(); defer { lock.unlock() }; return texture != nil }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        onDraw?()
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        // Rebuilding mipmaps for a multi-display retina image is heavy; do it at most
        // ~30×/s and only when the picture is actually shown downscaled.
        let now = CACurrentMediaTime()
        lock.lock()
        let tex = texture
        let regen = needsMipmaps && mipmapsWanted && now - lastMipmapTime > 1.0 / 30
        if regen {
            needsMipmaps = false
            lastMipmapTime = now
        }
        let ctex = cursorTexture
        let csize = cursorSize
        let chot = cursorHot
        lock.unlock()

        if regen, let tex, tex.mipmapLevelCount > 1, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
        }

        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)

        let bounds = view.bounds.size
        func ndc(_ r: CGRect) -> SIMD4<Float> {
            let x0 = Float(r.minX / bounds.width * 2 - 1)
            let x1 = Float(r.maxX / bounds.width * 2 - 1)
            let y0 = Float(1 - r.minY / bounds.height * 2)
            let y1 = Float(1 - r.maxY / bounds.height * 2)
            return SIMD4(x0, y0, x1, y1)
        }

        if let tex, contentRect.width > 0 {
            let t = textureRect
            var u = QuadUniforms(rect: ndc(contentRect),
                                 uv: SIMD4(Float(t.minX), Float(t.minY), Float(t.maxX), Float(t.maxY)), opaque: 1)
            enc.setVertexBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(useNearestFiltering ? nearestSampler : sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if let p = cursorPoint, let ctex, csize.width > 0 {
            let r = CGRect(x: p.x - chot.x * cursorScale, y: p.y - chot.y * cursorScale,
                           width: csize.width * cursorScale, height: csize.height * cursorScale)
            var u = QuadUniforms(rect: ndc(r), opaque: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            enc.setFragmentTexture(ctex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    /// Compiled at runtime so the project builds without the Metal toolchain.
    static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct QuadUniforms {
    float4 rect;   // x0, y0, x1, y1 in normalized device coordinates
    float4 uv;     // u0, v0, u1, v1 texture sub-rectangle
    float opaque;  // 1 = ignore texture alpha
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut quad_vertex(uint vid [[vertex_id]], constant QuadUniforms &u [[buffer(0)]]) {
    float2 uv = float2(vid & 1, vid >> 1);
    float x = mix(u.rect.x, u.rect.z, uv.x);
    float y = mix(u.rect.y, u.rect.w, uv.y);
    VOut o;
    o.position = float4(x, y, 0, 1);
    o.uv = mix(u.uv.xy, u.uv.zw, uv);
    return o;
}

fragment float4 quad_fragment(VOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]],
                              constant QuadUniforms &u [[buffer(0)]]) {
    float4 c = tex.sample(smp, in.uv);
    if (u.opaque > 0.5) { c.a = 1.0; }
    return c;
}
"""

    /// A simple arrow used until the Mac sends its real cursor shape.
    static func defaultCursor() -> CursorImage {
        let w = 24, h = 36
        var px = [UInt32](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 2, y: 2))
            path.addLine(to: CGPoint(x: 2, y: 28))
            path.addLine(to: CGPoint(x: 8, y: 22))
            path.addLine(to: CGPoint(x: 12.5, y: 32))
            path.addLine(to: CGPoint(x: 16.5, y: 30))
            path.addLine(to: CGPoint(x: 12, y: 20.5))
            path.addLine(to: CGPoint(x: 20, y: 20.5))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineJoin(.round)
            ctx.drawPath(using: .fillStroke)
        }
        return CursorImage(width: w, height: h, hotX: 2, hotY: 2, pixels: px)
    }
}
