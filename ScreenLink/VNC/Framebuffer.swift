import Foundation
import CoreGraphics

/// Remote screen pixels, 32-bit BGRX (little-endian 0x00RRGGBB).
final class Framebuffer {
    let width: Int
    let height: Int
    let pixels: UnsafeMutablePointer<UInt32>

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        pixels = .allocate(capacity: self.width * self.height)
        pixels.initialize(repeating: 0xFF20_2020, count: self.width * self.height)
    }

    deinit { pixels.deallocate() }

    @inline(__always)
    func clip(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (Int, Int, Int, Int)? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        if x1 <= x0 || y1 <= y0 { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    func fill(x: Int, y: Int, w: Int, h: Int, color: UInt32) {
        guard let (cx, cy, cw, ch) = clip(x, y, w, h) else { return }
        for row in cy..<(cy + ch) {
            (pixels + row * width + cx).update(repeating: color, count: cw)
        }
    }

    /// Copy `w*h` packed 32-bit pixels into the rect.
    func put(x: Int, y: Int, w: Int, h: Int, from src: UnsafePointer<UInt32>) {
        guard w > 0, h > 0 else { return }
        let x0 = max(0, x), x1 = min(width, x + w)
        guard x1 > x0 else { return }
        for row in 0..<h {
            let ty = y + row
            if ty < 0 || ty >= height { continue }
            (pixels + ty * width + x0).update(from: src + row * w + (x0 - x), count: x1 - x0)
        }
    }

    func copy(srcX: Int, srcY: Int, x: Int, y: Int, w: Int, h: Int) {
        guard let (_, _, _, _) = clip(x, y, w, h), clip(srcX, srcY, w, h) != nil else { return }
        let cw = min(w, width - max(x, srcX))
        guard cw > 0 else { return }
        let rows = Array(0..<h)
        let order = srcY < y ? rows.reversed() : rows
        for r in order {
            let sy = srcY + r, dy = y + r
            if sy < 0 || sy >= height || dy < 0 || dy >= height { continue }
            memmove(pixels + dy * width + x, pixels + sy * width + srcX, cw * 4)
        }
    }
}

/// A cursor image (premultiplied BGRA) plus hotspot.
struct CursorImage {
    var width: Int
    var height: Int
    var hotX: Int
    var hotY: Int
    var pixels: [UInt32]
}

extension CursorImage {
    /// True when this looks like the macOS text cursor (I-beam): a tall, narrow shape whose
    /// top and bottom rows (the serifs) are wider than its middle, with the hotspot near the
    /// centre. Works at any scale, since Retina Macs send 2x cursors.
    var isTextCursor: Bool {
        guard width > 0, height > 0, pixels.count >= width * height else { return false }
        var rowWidth = [Int](repeating: 0, count: height)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            var lo = width, hi = -1
            for x in 0..<width where pixels[y * width + x] >> 24 != 0 {
                if x < lo { lo = x }
                hi = x
            }
            guard hi >= 0 else { continue }
            rowWidth[y] = hi - lo + 1
            minX = min(minX, lo); maxX = max(maxX, hi)
            minY = min(minY, y); maxY = y
        }
        guard maxX >= 0 else { return false }
        let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
        guard bh >= 10, bw <= bh * 0.6 else { return false }
        let mid = Double(rowWidth[(minY + maxY) / 2])
        let top = Double(rowWidth[minY]), bottom = Double(rowWidth[maxY])
        guard mid > 0, mid <= bw * 0.6, top > mid, bottom > mid else { return false }
        let cx = Double(minX + maxX) / 2, cy = Double(minY + maxY) / 2
        return abs(Double(hotX) - cx) <= bw * 0.5 && abs(Double(hotY) - cy) <= bh * 0.3
    }
}
