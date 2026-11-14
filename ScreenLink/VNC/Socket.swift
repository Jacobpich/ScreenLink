import Foundation
import Darwin

enum SocketError: LocalizedError {
    case resolve(String)
    case connect(String)
    case timeout
    case closed
    case io(String)

    var errorDescription: String? {
        switch self {
        case .resolve(let h): return "Couldn't find \(h). If this is a Tailscale name, make sure Tailscale is connected on this phone."
        case .connect(let m): return "Couldn't connect: \(m)"
        case .timeout: return "Connection timed out. Is the Mac awake and is Tailscale connected?"
        case .closed: return "The connection was closed by the Mac."
        case .io(let m): return m
        }
    }
}

/// Blocking TCP socket with an internal read buffer. All reads happen on the
/// connection's dedicated thread; writes are serialized with a lock so the UI
/// thread can send input events without hopping queues (lowest latency).
final class TCPSocket {
    private var fd: Int32 = -1
    private let writeLock = NSLock()

    private var buf: UnsafeMutablePointer<UInt8>
    private let cap = 1 << 20
    private var pos = 0
    private var end = 0

    private(set) var bytesReceived: Int = 0

    init() {
        buf = .allocate(capacity: cap)
    }

    deinit {
        close()
        buf.deallocate()
    }

    func connect(host: String, port: Int, timeout: TimeInterval) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            ConnLog.write("resolve \(host) failed: \(String(cString: gai_strerror(rc)))")
            throw SocketError.resolve(host)
        }
        defer { freeaddrinfo(res) }

        var lastError: Error = SocketError.connect("no addresses")
        var ai: UnsafeMutablePointer<addrinfo>? = first
        let deadline = Date().addingTimeInterval(timeout)
        while let a = ai {
            ai = a.pointee.ai_next
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s < 0 { continue }
            var one: Int32 = 1
            setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var bufSize: Int32 = 4 << 20
            setsockopt(s, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

            let flags = fcntl(s, F_GETFL, 0)
            _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
            let r = Darwin.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen)
            if r == 0 || errno == EINPROGRESS {
                var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                let remaining = max(0.1, deadline.timeIntervalSinceNow)
                let pr = poll(&pfd, 1, Int32(remaining * 1000))
                if pr == 1 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0 {
                        ConnLog.write("tcp connected \(Self.describe(a.pointee.ai_addr)):\(port)")
                        _ = fcntl(s, F_SETFL, flags & ~O_NONBLOCK)
                        // Report "writable" only while little is waiting to go out, so the
                        // sender can tell when the Mac (or network) is falling behind.
                        var low: Int32 = 1024
                        setsockopt(s, Int32(IPPROTO_TCP), TCP_NOTSENT_LOWAT, &low, socklen_t(MemoryLayout<Int32>.size))
                        fd = s
                        return
                    }
                    lastError = SocketError.connect(String(cString: strerror(err)))
                    ConnLog.write("tcp \(Self.describe(a.pointee.ai_addr)):\(port) error: \(String(cString: strerror(err)))")
                } else {
                    lastError = SocketError.timeout
                    ConnLog.write("tcp \(Self.describe(a.pointee.ai_addr)):\(port) timed out")
                }
            } else {
                lastError = SocketError.connect(String(cString: strerror(errno)))
                ConnLog.write("tcp \(Self.describe(a.pointee.ai_addr)):\(port) error: \(String(cString: strerror(errno)))")
            }
            Darwin.close(s)
        }
        throw lastError
    }

    func close() {
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }

    var isOpen: Bool { fd >= 0 }

    // MARK: Reading

    private func fill(atLeast n: Int) throws {
        if pos > 0 && (cap - pos) < n {
            // compact
            let avail = end - pos
            if avail > 0 { memmove(buf, buf + pos, avail) }
            pos = 0
            end = avail
        }
        while end - pos < n {
            guard fd >= 0 else { throw SocketError.closed }
            let r = recv(fd, buf + end, cap - end, 0)
            if r > 0 {
                end += r
                bytesReceived &+= r
            } else if r == 0 {
                throw SocketError.closed
            } else if errno == EINTR {
                continue
            } else {
                throw SocketError.io(String(cString: strerror(errno)))
            }
        }
    }

    /// Returns a pointer valid until the next read call.
    @inline(__always)
    func peek(_ n: Int) throws -> UnsafePointer<UInt8> {
        precondition(n <= cap)
        if end - pos < n { try fill(atLeast: n) }
        return UnsafePointer(buf + pos)
    }

    @inline(__always)
    func skip(_ n: Int) { pos += n }

    func readU8() throws -> UInt8 {
        let p = try peek(1); let v = p[0]; pos += 1; return v
    }

    func readU16() throws -> UInt16 {
        let p = try peek(2); let v = UInt16(p[0]) << 8 | UInt16(p[1]); pos += 2; return v
    }

    func readU32() throws -> UInt32 {
        let p = try peek(4)
        let v = UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
        pos += 4
        return v
    }

    func readS32() throws -> Int32 { Int32(bitPattern: try readU32()) }

    /// Read exactly `count` bytes into `dest`, bypassing the buffer for large reads.
    func read(into dest: UnsafeMutableRawPointer, count: Int) throws {
        var copied = 0
        let avail = min(end - pos, count)
        if avail > 0 {
            memcpy(dest, buf + pos, avail)
            pos += avail
            copied = avail
        }
        while copied < count {
            let remaining = count - copied
            if remaining < 64 * 1024 {
                let p = try peek(remaining)
                memcpy(dest + copied, p, remaining)
                pos += remaining
                return
            }
            guard fd >= 0 else { throw SocketError.closed }
            let r = recv(fd, dest + copied, remaining, 0)
            if r > 0 { copied += r; bytesReceived &+= r }
            else if r == 0 { throw SocketError.closed }
            else if errno != EINTR { throw SocketError.io(String(cString: strerror(errno))) }
        }
    }

    func readBytes(_ n: Int) throws -> [UInt8] {
        if n == 0 { return [] }
        var out = [UInt8](repeating: 0, count: n)
        try out.withUnsafeMutableBytes { try read(into: $0.baseAddress!, count: n) }
        return out
    }

    // MARK: Writing

    /// True when almost nothing is waiting in the send buffer (see TCP_NOTSENT_LOWAT).
    func sendBacklogIsLow() -> Bool {
        guard fd >= 0 else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&p, 1, 0) == 1 && (p.revents & Int16(POLLOUT)) != 0
    }

    func write(_ data: [UInt8]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard fd >= 0 else { throw SocketError.closed }
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let r = send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if r > 0 { off += r }
                else if r < 0 && errno == EINTR { continue }
                else { throw SocketError.io("Send failed: \(String(cString: strerror(errno)))") }
            }
        }
    }

    static func describe(_ sa: UnsafeMutablePointer<sockaddr>?) -> String {
        guard let sa else { return "?" }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return String(cString: host)
    }

    /// Quick reachability probe used by the host list.
    static func probe(host: String, port: Int, timeout: TimeInterval) -> Bool {
        let s = TCPSocket()
        do {
            try s.connect(host: host, port: port, timeout: timeout)
            s.close()
            return true
        } catch {
            return false
        }
    }
}

extension Array where Element == UInt8 {
    mutating func appendU16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func appendU32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xff)); append(UInt8((v >> 8) & 0xff)); append(UInt8(v & 0xff))
    }
    mutating func appendS32(_ v: Int32) { appendU32(UInt32(bitPattern: v)) }
}
