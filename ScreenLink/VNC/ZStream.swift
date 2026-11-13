import Foundation
import zlib

/// A persistent zlib inflate stream (VNC encodings keep one stream alive for
/// the whole session, so dictionary state carries across rectangles).
final class ZStream {
    private var stream = z_stream()
    private var initialized = false
    private(set) var output: UnsafeMutablePointer<UInt8>
    private var outputCap: Int

    init() {
        outputCap = 1 << 20
        output = .allocate(capacity: outputCap)
    }

    deinit {
        if initialized { inflateEnd(&stream) }
        output.deallocate()
    }

    func reset() {
        if initialized { inflateEnd(&stream) }
        initialized = false
    }

    private func ensureInit() throws {
        if !initialized {
            stream = z_stream()
            let r = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard r == Z_OK else { throw SocketError.io("zlib init failed (\(r))") }
            initialized = true
        }
    }

    private func ensureCapacity(_ n: Int) {
        if n > outputCap {
            output.deallocate()
            outputCap = max(n, outputCap * 2)
            output = .allocate(capacity: outputCap)
        }
    }

    /// Inflate `input` producing exactly `expected` bytes into `output`.
    func inflate(_ input: UnsafePointer<UInt8>, count: Int, expected: Int) throws {
        try ensureInit()
        ensureCapacity(max(expected, 1))
        stream.next_in = UnsafeMutablePointer(mutating: input)
        stream.avail_in = uInt(count)
        stream.next_out = output
        stream.avail_out = uInt(expected)
        while stream.avail_out > 0 {
            let r = zlib.inflate(&stream, Z_SYNC_FLUSH)
            if r == Z_BUF_ERROR && stream.avail_in == 0 { break }
            guard r == Z_OK || r == Z_STREAM_END else { throw SocketError.io("Decompression failed (\(r))") }
            if r == Z_STREAM_END { break }
        }
        let produced = expected - Int(stream.avail_out)
        if produced < expected { throw SocketError.io("Decompression produced too little data") }
    }

    /// Inflate all of `input` (unknown output size). Returns produced byte count.
    func inflateAll(_ input: UnsafePointer<UInt8>, count: Int) throws -> Int {
        try ensureInit()
        stream.next_in = UnsafeMutablePointer(mutating: input)
        stream.avail_in = uInt(count)
        var produced = 0
        while true {
            if outputCap - produced < 64 * 1024 {
                let newCap = outputCap * 2
                let n = UnsafeMutablePointer<UInt8>.allocate(capacity: newCap)
                n.update(from: output, count: produced)
                output.deallocate()
                output = n
                outputCap = newCap
            }
            stream.next_out = output + produced
            stream.avail_out = uInt(outputCap - produced)
            let before = Int(stream.avail_out)
            let r = zlib.inflate(&stream, Z_SYNC_FLUSH)
            produced += before - Int(stream.avail_out)
            if r == Z_BUF_ERROR || (r == Z_OK && stream.avail_in == 0 && stream.avail_out > 0) { break }
            guard r == Z_OK || r == Z_STREAM_END else { throw SocketError.io("Decompression failed (\(r))") }
            if r == Z_STREAM_END { break }
        }
        return produced
    }
}
