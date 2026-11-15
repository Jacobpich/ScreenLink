import Foundation
import ImageIO
import CoreGraphics

enum Encoding {
    static let raw: Int32 = 0
    static let copyRect: Int32 = 1
    static let rre: Int32 = 2
    static let hextile: Int32 = 5
    static let zlib: Int32 = 6
    static let tight: Int32 = 7
    static let zrle: Int32 = 16

    static let cursor: Int32 = -239
    static let desktopSize: Int32 = -223
    static let lastRect: Int32 = -224
    static let extendedDesktopSize: Int32 = -308
    static func jpegQuality(_ q: Int) -> Int32 { -32 + Int32(q) }      // q 0...9
    static func compressLevel(_ l: Int) -> Int32 { -256 + Int32(l) }   // l 0...9
}

/// Decodes rectangle payloads from the socket into the framebuffer.
/// Pixel format is fixed to 32bpp/depth 24 little-endian BGRX.
final class RectDecoder {
    private let s: TCPSocket
    var fb: Framebuffer

    private let zrleStream = ZStream()
    private let zlibStream = ZStream()
    private let tightStreams = [ZStream(), ZStream(), ZStream(), ZStream()]

    private var scratch: UnsafeMutablePointer<UInt32>
    private var scratchCap: Int
    private var bytes: UnsafeMutablePointer<UInt8>
    private var bytesCap: Int

    init(socket: TCPSocket, framebuffer: Framebuffer) {
        s = socket
        fb = framebuffer
        scratchCap = 64 * 64
        scratch = .allocate(capacity: scratchCap)
        bytesCap = 1 << 20
        bytes = .allocate(capacity: bytesCap)
    }

    deinit {
        scratch.deallocate()
        bytes.deallocate()
        zOut.deallocate()
    }

    private func scratchPixels(_ n: Int) -> UnsafeMutablePointer<UInt32> {
        if n > scratchCap {
            scratch.deallocate()
            scratchCap = n
            scratch = .allocate(capacity: n)
        }
        return scratch
    }

    private func scratchBytes(_ n: Int) -> UnsafeMutablePointer<UInt8> {
        if n > bytesCap {
            bytes.deallocate()
            bytesCap = n
            bytes = .allocate(capacity: n)
        }
        return bytes
    }

    @inline(__always)
    private func readPixel() throws -> UInt32 {
        let p = try s.peek(4)
        let v = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16
        s.skip(4)
        return v
    }

    // MARK: Raw

    func raw(x: Int, y: Int, w: Int, h: Int) throws {
        let rowsPerChunk = max(1, (256 * 1024) / max(1, w * 4))
        var row = 0
        while row < h {
            let n = min(rowsPerChunk, h - row)
            let buf = scratchPixels(w * n)
            try s.read(into: buf, count: w * n * 4)
            fb.put(x: x, y: y + row, w: w, h: n, from: buf)
            row += n
        }
    }

    // MARK: CopyRect

    func copyRect(x: Int, y: Int, w: Int, h: Int) throws {
        let sx = Int(try s.readU16())
        let sy = Int(try s.readU16())
        fb.copy(srcX: sx, srcY: sy, x: x, y: y, w: w, h: h)
    }

    // MARK: RRE

    func rre(x: Int, y: Int, w: Int, h: Int) throws {
        let n = Int(try s.readU32())
        let bg = try readPixel()
        fb.fill(x: x, y: y, w: w, h: h, color: bg)
        for _ in 0..<n {
            let c = try readPixel()
            let p = try s.peek(8)
            let sx = Int(p[0]) << 8 | Int(p[1]), sy = Int(p[2]) << 8 | Int(p[3])
            let sw = Int(p[4]) << 8 | Int(p[5]), sh = Int(p[6]) << 8 | Int(p[7])
            s.skip(8)
            fb.fill(x: x + sx, y: y + sy, w: sw, h: sh, color: c)
        }
    }

    // MARK: Hextile

    func hextile(x: Int, y: Int, w: Int, h: Int) throws {
        var bg: UInt32 = 0, fg: UInt32 = 0
        var ty = y
        while ty < y + h {
            let th = min(16, y + h - ty)
            var tx = x
            while tx < x + w {
                let tw = min(16, x + w - tx)
                let sub = try s.readU8()
                if sub & 1 != 0 {
                    let buf = scratchPixels(tw * th)
                    try s.read(into: buf, count: tw * th * 4)
                    fb.put(x: tx, y: ty, w: tw, h: th, from: buf)
                } else {
                    if sub & 2 != 0 { bg = try readPixel() }
                    fb.fill(x: tx, y: ty, w: tw, h: th, color: bg)
                    if sub & 4 != 0 { fg = try readPixel() }
                    if sub & 8 != 0 {
                        let count = Int(try s.readU8())
                        let colored = sub & 16 != 0
                        for _ in 0..<count {
                            let c = colored ? try readPixel() : fg
                            let p = try s.peek(2)
                            let sx = Int(p[0] >> 4), sy = Int(p[0] & 15)
                            let sw = Int(p[1] >> 4) + 1, sh = Int(p[1] & 15) + 1
                            s.skip(2)
                            fb.fill(x: tx + sx, y: ty + sy, w: sw, h: sh, color: c)
                        }
                    }
                }
                tx += 16
            }
            ty += 16
        }
    }

    // MARK: Zlib

    func zlibRect(x: Int, y: Int, w: Int, h: Int) throws {
        let len = Int(try s.readU32())
        let input = scratchBytes(len)
        try s.read(into: input, count: len)
        try zlibStream.inflate(input, count: len, expected: w * h * 4)
        zlibStream.output.withMemoryRebound(to: UInt32.self, capacity: w * h) {
            fb.put(x: x, y: y, w: w, h: h, from: $0)
        }
    }

    // MARK: ZRLE

    /// Called while a large rectangle is still arriving, with the part already decoded, so the
    /// screen paints in progressively instead of staying black until the whole frame is in.
    var onProgress: ((CGRect) -> Void)?

    private var zOut = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
    private var zOutCap = 1 << 20

    /// ZRLE is decoded as it streams in: compressed data is read in chunks and tiles are drawn
    /// as soon as their bytes have arrived (a full 5K+ desktop can be tens of megabytes).
    func zrle(x: Int, y: Int, w: Int, h: Int) throws {
        var remaining = Int(try s.readU32())
        let chunkCap = 256 * 1024
        let chunk = scratchBytes(chunkCap)
        var outLen = 0, parsePos = 0

        // Brings in more decompressed data. Returns false when the rectangle's data is used up.
        func pull() throws -> Bool {
            if parsePos > 0 {
                let keep = outLen - parsePos
                if keep > 0 { memmove(zOut, zOut + parsePos, keep) }
                outLen = keep
                parsePos = 0
            }
            if zrleStream.pendingInput == 0 {
                guard remaining > 0 else { return false }
                let n = min(remaining, chunkCap)
                try s.read(into: chunk, count: n)
                remaining -= n
                try zrleStream.feed(chunk, count: n)
            }
            if zOutCap - outLen < 64 * 1024 {
                let cap = zOutCap * 2
                let bigger = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
                bigger.update(from: zOut, count: outLen)
                zOut.deallocate()
                zOut = bigger
                zOutCap = cap
            }
            outLen = try zrleStream.inflateSome(into: zOut, cap: zOutCap, len: outLen)
            return true
        }

        var palette = [UInt32](repeating: 0, count: 128)
        var notifiedY = y
        var lastNotify = CFAbsoluteTimeGetCurrent()
        var ty = y
        while ty < y + h {
            let th = min(64, y + h - ty)
            var tx = x
            while tx < x + w {
                let tw = min(64, x + w - tx)
                while true {
                    var r = ByteReader(base: zOut + parsePos, count: outLen - parsePos)
                    do {
                        try zrleTile(&r, tx: tx, ty: ty, tw: tw, th: th, palette: &palette)
                        parsePos += r.pos
                        break
                    } catch is NeedMoreData {
                        guard try pull() else { throw SocketError.io("Truncated compressed data") }
                    }
                }
                tx += 64
            }
            ty += 64
            if let onProgress, CFAbsoluteTimeGetCurrent() - lastNotify > 0.1 {
                let bottom = min(ty, y + h)
                onProgress(CGRect(x: x, y: notifiedY, width: w, height: bottom - notifiedY))
                notifiedY = bottom
                lastNotify = CFAbsoluteTimeGetCurrent()
            }
        }
        // Use up the rest so the persistent zlib stream stays in step with the server.
        parsePos = outLen
        while try pull() { parsePos = outLen }
    }

    private func zrleTile(_ r: inout ByteReader, tx: Int, ty: Int, tw: Int, th: Int, palette: inout [UInt32]) throws {
        let sub = Int(try r.u8())
        let n = tw * th
        let tile = scratchPixels(n)

        if sub == 0 {
            for i in 0..<n { tile[i] = try r.cpixel() }
        } else if sub == 1 {
            let c = try r.cpixel()
            fb.fill(x: tx, y: ty, w: tw, h: th, color: c)
            return
        } else if sub >= 2 && sub <= 16 {
            for i in 0..<sub { palette[i] = try r.cpixel() }
            let bits = sub == 2 ? 1 : (sub <= 4 ? 2 : 4)
            let mask = (1 << bits) - 1
            for row in 0..<th {
                var byte = 0, nbits = 0
                for col in 0..<tw {
                    if nbits == 0 { byte = Int(try r.u8()); nbits = 8 }
                    nbits -= bits
                    tile[row * tw + col] = palette[(byte >> nbits) & mask]
                }
            }
        } else if sub == 128 {
            var i = 0
            while i < n {
                let c = try r.cpixel()
                var run = 1
                while true { let b = Int(try r.u8()); run += b; if b != 255 { break } }
                let end = min(n, i + run)
                (tile + i).update(repeating: c, count: end - i)
                i = end
            }
        } else if sub >= 130 {
            let psize = sub - 128
            for i in 0..<psize { palette[i] = try r.cpixel() }
            var i = 0
            while i < n {
                let idx = Int(try r.u8())
                let c = palette[idx & 127]
                var run = 1
                if idx & 128 != 0 {
                    while true { let b = Int(try r.u8()); run += b; if b != 255 { break } }
                }
                let end = min(n, i + run)
                (tile + i).update(repeating: c, count: end - i)
                i = end
            }
        } else {
            throw SocketError.io("Bad ZRLE subencoding \(sub)")
        }
        fb.put(x: tx, y: ty, w: tw, h: th, from: tile)
    }

    // MARK: Tight

    private func compactLength() throws -> Int {
        var b = Int(try s.readU8())
        var len = b & 0x7f
        if b & 0x80 != 0 {
            b = Int(try s.readU8())
            len |= (b & 0x7f) << 7
            if b & 0x80 != 0 {
                b = Int(try s.readU8())
                len |= b << 14
            }
        }
        return len
    }

    @inline(__always)
    private func tpixel(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2])
    }

    func tight(x: Int, y: Int, w: Int, h: Int) throws {
        let ctl = Int(try s.readU8())
        for i in 0..<4 where ctl & (1 << i) != 0 { tightStreams[i].reset() }
        let comp = ctl >> 4

        if comp == 8 { // fill
            let p = try s.peek(3)
            let c = tpixel(p)
            s.skip(3)
            fb.fill(x: x, y: y, w: w, h: h, color: c)
            return
        }
        if comp == 9 { // JPEG
            let len = try compactLength()
            let data = try s.readBytes(len)
            try drawJPEG(data, x: x, y: y, w: w, h: h)
            return
        }
        guard comp <= 7 else { throw SocketError.io("Bad Tight compression \(comp)") }

        let streamId = comp & 3
        var filter = 0
        if comp & 4 != 0 { filter = Int(try s.readU8()) }

        var palette = [UInt32](repeating: 0, count: 256)
        var numColors = 0
        var rowBytes = w * 3
        if filter == 1 {
            numColors = Int(try s.readU8()) + 1
            let p = try s.peek(numColors * 3)
            for i in 0..<numColors { palette[i] = tpixel(p + i * 3) }
            s.skip(numColors * 3)
            rowBytes = numColors == 2 ? (w + 7) / 8 : w
        } else if filter != 0 && filter != 2 {
            throw SocketError.io("Bad Tight filter \(filter)")
        }

        let dataSize = rowBytes * h
        let data: UnsafePointer<UInt8>
        if dataSize < 12 {
            let buf = scratchBytes(dataSize)
            try s.read(into: buf, count: dataSize)
            data = UnsafePointer(buf)
        } else {
            let len = try compactLength()
            let input = scratchBytes(len)
            try s.read(into: input, count: len)
            try tightStreams[streamId].inflate(input, count: len, expected: dataSize)
            data = UnsafePointer(tightStreams[streamId].output)
        }

        let out = scratchPixels(w * h)
        switch filter {
        case 1:
            if numColors == 2 {
                for row in 0..<h {
                    for col in 0..<w {
                        let b = data[row * rowBytes + col / 8]
                        out[row * w + col] = palette[Int((b >> (7 - UInt8(col & 7))) & 1)]
                    }
                }
            } else {
                for i in 0..<(w * h) { out[i] = palette[Int(data[i])] }
            }
        case 2:
            var prev = [Int](repeating: 0, count: w * 3)
            var cur = [Int](repeating: 0, count: w * 3)
            for row in 0..<h {
                for col in 0..<w {
                    for c in 0..<3 {
                        let left = col > 0 ? cur[(col - 1) * 3 + c] : 0
                        let up = prev[col * 3 + c]
                        let upLeft = col > 0 ? prev[(col - 1) * 3 + c] : 0
                        let est = min(255, max(0, left + up - upLeft))
                        cur[col * 3 + c] = (Int(data[row * rowBytes + col * 3 + c]) + est) & 0xff
                    }
                    out[row * w + col] = UInt32(cur[col * 3]) << 16 | UInt32(cur[col * 3 + 1]) << 8 | UInt32(cur[col * 3 + 2])
                }
                swap(&prev, &cur)
            }
        default:
            for i in 0..<(w * h) { out[i] = tpixel(data + i * 3) }
        }
        fb.put(x: x, y: y, w: w, h: h, from: out)
    }

    private func drawJPEG(_ data: [UInt8], x: Int, y: Int, w: Int, h: Int) throws {
        guard let src = CGImageSourceCreateWithData(Data(data) as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let buf = scratchPixels(w * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        fb.put(x: x, y: y, w: w, h: h, from: buf)
    }

    // MARK: Cursor pseudo-encoding

    func cursor(hotX: Int, hotY: Int, w: Int, h: Int) throws -> CursorImage? {
        let pix = try s.readBytes(w * h * 4)
        let maskRow = (w + 7) / 8
        let mask = try s.readBytes(maskRow * h)
        guard w > 0, h > 0 else { return nil }
        var out = [UInt32](repeating: 0, count: w * h)
        for row in 0..<h {
            for col in 0..<w {
                let visible = (mask[row * maskRow + col / 8] >> (7 - UInt8(col & 7))) & 1 == 1
                if visible {
                    let i = (row * w + col) * 4
                    out[row * w + col] = UInt32(pix[i]) | UInt32(pix[i + 1]) << 8 | UInt32(pix[i + 2]) << 16 | 0xFF00_0000
                }
            }
        }
        return CursorImage(width: w, height: h, hotX: hotX, hotY: hotY, pixels: out)
    }
}

/// Bounds-checked reader over decompressed data.
/// Thrown by ByteReader when a ZRLE tile's bytes haven't all arrived yet.
struct NeedMoreData: Error {}

struct ByteReader {
    let base: UnsafePointer<UInt8>
    let count: Int
    var pos = 0

    init(base: UnsafeMutablePointer<UInt8>, count: Int) {
        self.base = UnsafePointer(base)
        self.count = count
    }

    @inline(__always)
    mutating func u8() throws -> UInt8 {
        guard pos < count else { throw NeedMoreData() }
        let v = base[pos]; pos += 1; return v
    }

    /// ZRLE compressed pixel: 3 bytes (B, G, R) for our 32bpp/depth 24 format.
    @inline(__always)
    mutating func cpixel() throws -> UInt32 {
        guard pos + 3 <= count else { throw NeedMoreData() }
        let v = UInt32(base[pos]) | UInt32(base[pos + 1]) << 8 | UInt32(base[pos + 2]) << 16
        pos += 3
        return v
    }
}
