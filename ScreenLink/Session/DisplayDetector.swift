import CoreGraphics
import Foundation

/// macOS Screen Sharing sends all displays as one big image. This finds the
/// individual displays in it by looking for the seams between them: full-length
/// lines where the picture changes abruptly, or where the black filler that
/// pads differently-sized displays begins.
enum DisplayDetector {
    static func detect(_ fb: Framebuffer) -> [CGRect] {
        let full = CGRect(x: 0, y: 0, width: fb.width, height: fb.height)
        var regions = split(fb, full, depth: 0)
            .map { trimBlack(fb, $0) }
            .filter { $0.width >= 320 && $0.height >= 240 }
        if regions.isEmpty { regions = [full] }

        // Same-size displays side by side with similar content can hide the seam;
        // fall back to the overall shape, which no single display has.
        if regions.count == 1 {
            let r = regions[0]
            let aspect = r.width / r.height
            if aspect > 4.6 { regions = even(r, columns: 3, rows: 1) }
            else if aspect > 2.9 { regions = even(r, columns: 2, rows: 1) }
        }
        return regions.sorted { abs($0.minY - $1.minY) > 200 && abs($0.minX - $1.minX) < 200 ? $0.minY < $1.minY : $0.minX < $1.minX }
    }

    static func even(_ r: CGRect, columns: Int, rows: Int) -> [CGRect] {
        var out: [CGRect] = []
        let w = (r.width / CGFloat(columns)).rounded(.down), h = (r.height / CGFloat(rows)).rounded(.down)
        for row in 0..<rows {
            for col in 0..<columns {
                out.append(CGRect(x: r.minX + CGFloat(col) * w, y: r.minY + CGFloat(row) * h, width: w, height: h))
            }
        }
        return out
    }

    // MARK: Splitting

    private static func plausible(_ r: CGRect) -> Bool {
        guard r.width >= 320, r.height >= 240 else { return false }
        let a = r.width / r.height
        return (a >= 1.2 && a <= 2.6) || (a >= 0.45 && a <= 0.85)
    }

    private static func split(_ fb: Framebuffer, _ r: CGRect, depth: Int) -> [CGRect] {
        guard depth < 3 else { return [r] }
        if let x = bestSeam(fb, r, vertical: true) {
            let a = CGRect(x: r.minX, y: r.minY, width: CGFloat(x) - r.minX, height: r.height)
            let b = CGRect(x: CGFloat(x), y: r.minY, width: r.maxX - CGFloat(x), height: r.height)
            return split(fb, a, depth: depth + 1) + split(fb, b, depth: depth + 1)
        }
        if let y = bestSeam(fb, r, vertical: false) {
            let a = CGRect(x: r.minX, y: r.minY, width: r.width, height: CGFloat(y) - r.minY)
            let b = CGRect(x: r.minX, y: CGFloat(y), width: r.width, height: r.maxY - CGFloat(y))
            return split(fb, a, depth: depth + 1) + split(fb, b, depth: depth + 1)
        }
        return [r]
    }

    @inline(__always)
    private static func isBlack(_ p: UInt32) -> Bool { p & 0x00FC_FCFC == 0 }

    @inline(__always)
    private static func diff(_ a: UInt32, _ b: UInt32) -> Int {
        let dr = abs(Int((a >> 16) & 0xff) - Int((b >> 16) & 0xff))
        let dg = abs(Int((a >> 8) & 0xff) - Int((b >> 8) & 0xff))
        let db = abs(Int(a & 0xff) - Int(b & 0xff))
        return dr + dg + db
    }

    /// Finds a line across the whole region where nearly every sample changes sharply.
    private static func bestSeam(_ fb: Framebuffer, _ r: CGRect, vertical: Bool) -> Int? {
        let x0 = Int(r.minX), y0 = Int(r.minY), x1 = Int(r.maxX), y1 = Int(r.maxY)
        let length = vertical ? (y1 - y0) : (x1 - x0)
        let span = vertical ? (x1 - x0) : (y1 - y0)
        guard span > 640, length > 240 else { return nil }
        let step = max(1, length / 400)
        let samples = length / step
        let px = fb.pixels, w = fb.width

        var best = -1, bestScore = 0.0
        let start = vertical ? x0 + span * 15 / 100 : y0 + span * 15 / 100
        let end = vertical ? x0 + span * 85 / 100 : y0 + span * 85 / 100
        for c in start..<end {
            var hits = 0
            var i = 0
            var t = vertical ? y0 : x0
            while i < samples {
                let a: UInt32, b: UInt32
                if vertical { a = px[t * w + c - 1]; b = px[t * w + c] }
                else { a = px[(c - 1) * w + t]; b = px[c * w + t] }
                if isBlack(a) != isBlack(b) || diff(a, b) > 60 { hits += 1 }
                i += 1
                t += step
            }
            let score = Double(hits) / Double(max(1, samples))
            if score > bestScore {
                // Both halves must look like real displays.
                let ra: CGRect, rb: CGRect
                if vertical {
                    ra = trimBlack(fb, CGRect(x: r.minX, y: r.minY, width: CGFloat(c) - r.minX, height: r.height))
                    rb = trimBlack(fb, CGRect(x: CGFloat(c), y: r.minY, width: r.maxX - CGFloat(c), height: r.height))
                } else {
                    ra = trimBlack(fb, CGRect(x: r.minX, y: r.minY, width: r.width, height: CGFloat(c) - r.minY))
                    rb = trimBlack(fb, CGRect(x: r.minX, y: CGFloat(c), width: r.width, height: r.maxY - CGFloat(c)))
                }
                if score > 0.72 && plausible(ra) && plausible(rb) {
                    bestScore = score
                    best = c
                }
            }
        }
        return best >= 0 ? best : nil
    }

    /// Removes rows/columns at the edges that are (almost) entirely black filler.
    static func trimBlack(_ fb: Framebuffer, _ r: CGRect) -> CGRect {
        var x0 = Int(r.minX), y0 = Int(r.minY), x1 = Int(r.maxX), y1 = Int(r.maxY)
        let px = fb.pixels, w = fb.width

        func colBlack(_ x: Int) -> Bool {
            let step = max(1, (y1 - y0) / 200)
            var black = 0, n = 0
            var y = y0
            while y < y1 { if isBlack(px[y * w + x]) { black += 1 }; n += 1; y += step }
            return Double(black) >= Double(n) * 0.97
        }
        func rowBlack(_ y: Int) -> Bool {
            let step = max(1, (x1 - x0) / 200)
            var black = 0, n = 0
            var x = x0
            while x < x1 { if isBlack(px[y * w + x]) { black += 1 }; n += 1; x += step }
            return Double(black) >= Double(n) * 0.97
        }
        while x1 - x0 > 8 && colBlack(x0) { x0 += 1 }
        while x1 - x0 > 8 && colBlack(x1 - 1) { x1 -= 1 }
        while y1 - y0 > 8 && rowBlack(y0) { y0 += 1 }
        while y1 - y0 > 8 && rowBlack(y1 - 1) { y1 -= 1 }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
