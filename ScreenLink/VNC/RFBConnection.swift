import Foundation

struct ConnectionConfig {
    var host: String
    /// Tried first with a short timeout; `host` is the fallback (see SavedHost.homeAddress).
    var homeHost: String? = nil
    var port: Int
    var username: String
    var password: String
    var quality: StreamQuality
}

enum StreamQuality: String, CaseIterable, Identifiable, Codable {
    case lossless, balanced, lowBandwidth
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lossless: return "Sharp (lossless)"
        case .balanced: return "Balanced"
        case .lowBandwidth: return "Low bandwidth"
        }
    }
    var detail: String {
        switch self {
        case .lossless: return "Crisp text. Best on Wi-Fi."
        case .balanced: return "Lossless with heavier compression."
        case .lowBandwidth: return "JPEG compression for cellular."
        }
    }
}

protocol RFBConnectionDelegate: AnyObject {
    /// All delegate calls arrive on the connection thread.
    func rfbDidConnect(_ c: RFBConnection, name: String, framebuffer: Framebuffer)
    func rfbDidResize(_ c: RFBConnection, framebuffer: Framebuffer)
    func rfb(_ c: RFBConnection, didUpdate framebuffer: Framebuffer, dirty: [CGRect])
    func rfb(_ c: RFBConnection, cursorChanged cursor: CursorImage?)
    func rfb(_ c: RFBConnection, clipboard text: String)
    func rfb(_ c: RFBConnection, didFail error: Error?)
    /// Display layout reported by the server (only if it supports ExtendedDesktopSize).
    func rfb(_ c: RFBConnection, screens: [CGRect])
}

extension RFBConnectionDelegate {
    func rfb(_ c: RFBConnection, screens: [CGRect]) {}
}

/// RFB 3.8 client tuned for macOS Screen Sharing.
final class RFBConnection {
    weak var delegate: RFBConnectionDelegate?
    let config: ConnectionConfig

    private let socket = TCPSocket()
    private var thread: Thread?
    private var stopped = false
    private var decoder: RectDecoder!
    private(set) var framebuffer: Framebuffer?

    private var buttonMask: UInt8 = 0          // guarded by `out`

    // Outgoing traffic (see "Outgoing messages")
    private let out = NSCondition()
    private var outQueue: [UInt8] = []
    private var pendingMove: (x: UInt16, y: UInt16)?
    private var pendingScroll = (dx: 0, dy: 0)
    private var scrollSent = 0, scrollDropped = 0          // guarded by `out`; for the stats line
    private var scrollAt: (x: UInt16, y: UInt16) = (0, 0)
    private var writerRunning = false

    // Input flow control: a tiny request the Mac must answer immediately ("ping"). Because the
    // Mac handles messages in order, its reply time shows how far behind it is on our input.
    private var pingOutstanding = false        // guarded by `out`
    private var pingSent: CFAbsoluteTime = 0
    private var pingRTT: Double = 0.05
    private var pingPoint = (x: 0, y: 0)
    /// A pixel that's on a real display (guarded by `out`). With displays of different sizes the
    /// picture has filler macOS never sends, and a 1-pixel request there is never answered.
    private var pingTarget: (x: Int, y: Int)?
    private var updateRegion: CGRect?         // guarded by `out`

    // Health watchdog
    private var lastProgressBytes = -1
    private var lastProgressTime = CFAbsoluteTimeGetCurrent()
    private var probeTime: CFAbsoluteTime?
    private var stallError: Error?

    // Stats
    private(set) var framesReceived = 0
    /// macOS Screen Sharing announces protocol 3.889; anything else (like ScreenLink Receiver
    /// on Windows) is treated as a PC: Windows shortcuts instead of Mac ones.
    private(set) var serverIsApple = true
    private var lastRequest = CFAbsoluteTimeGetCurrent()
    private(set) var lastRoundTrip: Double = 0
    var bytesReceived: Int { socket.bytesReceived }

    init(config: ConnectionConfig) {
        self.config = config
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "ScreenLink.RFB"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        stopped = true
        out.lock(); out.broadcast(); out.unlock()
        socket.close()
    }

    var isRunning: Bool { !stopped && socket.isOpen }

    // MARK: Main loop

    private func run() {
        do {
            ConnLog.write("connect \(config.host):\(config.port) home=\(config.homeHost ?? "-") user=\(config.username.isEmpty ? "-" : "set")")
            var viaHome = false
            if let home = config.homeHost, home != config.host {
                do {
                    try socket.connect(host: home, port: config.port, timeout: 1.5)
                    viaHome = true
                    ConnLog.write("using home address \(home)")
                } catch {
                    ConnLog.write("home address \(home) didn't answer; using \(config.host)")
                    if stopped { throw error }
                }
            }
            if !viaHome {
                try socket.connect(host: config.host, port: config.port, timeout: 10)
            }
            try handshake()
            while !stopped {
                try readServerMessage()
            }
        } catch {
            let wasStopped = stopped
            stopped = true
            out.lock(); out.broadcast(); out.unlock()
            socket.close()
            ConnLog.write("session ended\(wasStopped ? " (closed by app)" : ""): \((stallError ?? error).localizedDescription) [\(error)]")
            if !wasStopped { delegate?.rfb(self, didFail: stallError ?? error) }
        }
    }

    private func handshake() throws {
        let versionBytes = try socket.readBytes(12)
        let version = String(bytes: versionBytes, encoding: .ascii) ?? ""
        ConnLog.write("server version \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
        serverIsApple = version.hasPrefix("RFB 003.889")
        guard version.hasPrefix("RFB ") else { throw SocketError.io("Not a Screen Sharing server (\(version.trimmingCharacters(in: .whitespacesAndNewlines))).") }
        // macOS reports "RFB 003.889"; we speak 3.8.
        try socket.write(Array("RFB 003.008\n".utf8))

        let count = Int(try socket.readU8())
        if count == 0 {
            let len = Int(try socket.readU32())
            let reason = String(bytes: try socket.readBytes(len), encoding: .utf8) ?? ""
            throw AuthError.failed(reason)
        }
        let types = try socket.readBytes(count)
        ConnLog.write("security types \(types)")

        // ScreenLink Receiver only checks the password, so any username will do there.
        let username = config.username.isEmpty && !serverIsApple ? "screenlink" : config.username
        let hasUser = !username.isEmpty
        let choice: UInt8
        if types.contains(30) && hasUser { choice = 30 }
        else if types.contains(2) && !config.password.isEmpty { choice = 2 }
        else if types.contains(1) { choice = 1 }
        else if types.contains(30) { throw AuthError.needsUsername }
        else if types.contains(2) { throw AuthError.needsPassword }
        else { throw AuthError.unsupported(types) }

        try socket.write([choice])

        switch choice {
        case 30:
            let gen = try socket.readBytes(2)
            let keyLen = Int(try socket.readU16())
            let prime = try socket.readBytes(keyLen)
            let serverKey = try socket.readBytes(keyLen)
            let resp = try AppleAuth.response(generator: gen, prime: prime, serverPublic: serverKey,
                                              username: username, password: config.password)
            try socket.write(resp)
        case 2:
            let challenge = try socket.readBytes(16)
            try socket.write(try VNCAuth.response(challenge: challenge, password: config.password))
        default:
            break
        }

        let result = try socket.readU32()
        ConnLog.write("auth type \(choice) result \(result)")
        if result != 0 {
            var reason = ""
            if let len = try? socket.readU32(), len < 4096,
               let b = try? socket.readBytes(Int(len)) {
                reason = String(bytes: b, encoding: .utf8) ?? ""
            }
            throw AuthError.failed(reason)
        }

        // ClientInit: shared session so the Mac's own display stays live.
        try socket.write([1])

        let w = Int(try socket.readU16())
        let h = Int(try socket.readU16())
        _ = try socket.readBytes(16) // server pixel format; we override it below
        let nameLen = Int(try socket.readU32())
        let name = String(bytes: try socket.readBytes(nameLen), encoding: .utf8) ?? config.host
        ConnLog.write("connected to \(name) \(w)x\(h)")

        let fb = Framebuffer(width: w, height: h)
        framebuffer = fb
        decoder = RectDecoder(socket: socket, framebuffer: fb)
        decoder.onProgress = { [weak self] rect in
            guard let self, let fb = self.framebuffer else { return }
            self.delegate?.rfb(self, didUpdate: fb, dirty: [rect])
        }
        connectedAt = CFAbsoluteTimeGetCurrent()
        bytesAtConnect = socket.bytesReceived

        try sendPixelFormat()
        try sendEncodings()
        startWriter()
        delegate?.rfbDidConnect(self, name: name, framebuffer: fb)
        requestUpdate(incremental: false)
    }

    private func sendPixelFormat() throws {
        var m: [UInt8] = [0, 0, 0, 0]
        m += [32, 24, 0, 1]        // bpp, depth, big-endian=false, true-color
        m.appendU16(255); m.appendU16(255); m.appendU16(255)
        m += [16, 8, 0]            // shifts → memory order B,G,R,X
        m += [0, 0, 0]
        try socket.write(m)
    }

    private func sendEncodings() throws {
        var encs: [Int32] = [Encoding.copyRect]
        switch config.quality {
        case .lossless:
            encs += [Encoding.zrle, Encoding.hextile, Encoding.tight, Encoding.zlib, Encoding.rre, Encoding.raw]
            encs += [Encoding.compressLevel(1)]
        case .balanced:
            encs += [Encoding.zrle, Encoding.tight, Encoding.hextile, Encoding.zlib, Encoding.rre, Encoding.raw]
            encs += [Encoding.compressLevel(6)]
        case .lowBandwidth:
            encs += [Encoding.tight, Encoding.zrle, Encoding.hextile, Encoding.zlib, Encoding.rre, Encoding.raw]
            encs += [Encoding.jpegQuality(6), Encoding.compressLevel(9)]
        }
        encs += [Encoding.cursor, Encoding.extendedDesktopSize, Encoding.desktopSize, Encoding.lastRect]
        var m: [UInt8] = [2, 0]
        m.appendU16(UInt16(encs.count))
        for e in encs { m.appendS32(e) }
        try socket.write(m)
    }

    private func requestUpdate(incremental: Bool) {
        guard let fb = framebuffer else { return }
        let full = CGRect(x: 0, y: 0, width: fb.width, height: fb.height)
        out.lock(); let shown = incremental ? updateRegion : nil; out.unlock()
        let r = shown.map { $0.intersection(full) }.flatMap { $0.isEmpty ? nil : $0 } ?? full
        lastRequest = CFAbsoluteTimeGetCurrent()
        enqueue(updateRequest(incremental: incremental, r))
    }

    private func updateRequest(incremental: Bool, _ r: CGRect) -> [UInt8] {
        var m: [UInt8] = [3, incremental ? 1 : 0]
        m.appendU16(UInt16(r.minX)); m.appendU16(UInt16(r.minY))
        m.appendU16(UInt16(r.width)); m.appendU16(UInt16(r.height))
        return m
    }

    /// Only ask a Mac for changes inside this rectangle (the one display being shown), or the
    /// whole picture when nil. macOS sends every display otherwise, so showing one display of
    /// two still paid for both. Asks once for a fresh copy of the newly shown area, since changes
    /// outside the old region weren't sent.
    func setUpdateRegion(_ region: CGRect?) {
        guard serverIsApple, let fb = framebuffer else { return }
        let full = CGRect(x: 0, y: 0, width: fb.width, height: fb.height)
        let r = region.map { $0.integral.intersection(full) }.flatMap { $0.isEmpty || $0 == full ? nil : $0 }
        out.lock()
        let changed = r != updateRegion
        updateRegion = r
        out.unlock()
        guard changed else { return }
        ConnLog.write("update region \(r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "all")")
        enqueue(updateRequest(incremental: false, r ?? full))
    }

    private func readServerMessage() throws {
        let type = try socket.readU8()
        switch type {
        case 0: try readFramebufferUpdate()
        case 1: // SetColourMapEntries (ignored; we use true colour)
            _ = try socket.readU8()
            _ = try socket.readU16()
            let n = Int(try socket.readU16())
            _ = try socket.readBytes(n * 6)
        case 2: break // Bell
        case 3:
            _ = try socket.readBytes(3)
            let len = Int(try socket.readU32())
            let data = try socket.readBytes(len)
            let text = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
            if !text.isEmpty { delegate?.rfb(self, clipboard: text) }
        default:
            throw SocketError.io("Unexpected message from server (\(type)).")
        }
    }

    // Until a complete picture has arrived we keep asking for the full screen (non-incremental).
    // macOS may answer the first request with only the cursor and screen layout and no pixels;
    // asking for changes after that would leave the screen black until something moved.
    private var fullFramePending = true
    private var fullFrameArea = 0
    private var statRects = 0, statPixels = 0
    /// macOS answers a full-screen request with one rectangle per display (the black filler
    /// between differently sized displays is never sent), so those rectangles are the layout.
    private var appleDisplayRects: [CGRect] = []
    /// False until the first complete picture of the desktop has arrived (read from the UI).
    private(set) var hasFullPicture = false
    private var connectedAt = CFAbsoluteTimeGetCurrent()
    private var bytesAtConnect = 0
    /// Bytes received since the session started (for the loading indicator).
    var bytesSinceConnect: Int { socket.bytesReceived - bytesAtConnect }

    private func reportAppleDisplays() {
        let rects = appleDisplayRects
        appleDisplayRects = []
        guard serverIsApple, rects.count > 1, let fb = framebuffer else { return }
        let full = CGRect(x: 0, y: 0, width: fb.width, height: fb.height)
        // Must look like separate whole displays: inside the picture, not overlapping, display-shaped.
        for (i, r) in rects.enumerated() {
            let a = r.width / r.height
            guard full.contains(r), (a >= 1.2 && a <= 2.6) || (a >= 0.45 && a <= 0.85) else { return }
            for o in rects[(i + 1)...] where r.intersects(o) { return }
        }
        let sorted = rects.sorted { abs($0.minY - $1.minY) > 200 && abs($0.minX - $1.minX) < 200 ? $0.minY < $1.minY : $0.minX < $1.minX }
        ConnLog.write("displays from the Mac's update: \(sorted.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })")
        delegate?.rfb(self, screens: sorted)
    }

    // Rolling performance stats, logged every few seconds (connection.log / ScreenLink.log).
    private var st = (start: CFAbsoluteTimeGetCurrent(), updates: 0, rects: 0, pixels: 0, bytes: 0, wait: 0.0, read: 0.0)

    private func noteStats(t0: CFAbsoluteTime, bytes0: Int, rects: Int, pixels: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        st.updates += 1; st.rects += rects; st.pixels += pixels
        st.bytes += socket.bytesReceived - bytes0
        st.wait += max(0, t0 - lastRequest); st.read += now - t0
        let span = now - st.start
        guard span >= 3 else { return }
        let u = Double(max(1, st.updates))
        ConnLog.write(String(format: "stats %.1fs: %d updates (%.1f/s), %.1f rects and %.2f Mpx each, %.0f KB each, %.1f MB/s, wait %.0f ms, read+decode %.0f ms",
                             span, st.updates, Double(st.updates) / span, Double(st.rects) / u, Double(st.pixels) / u / 1e6,
                             Double(st.bytes) / u / 1024, Double(st.bytes) / span / 1e6, st.wait / u * 1000, st.read / u * 1000)
                     + scrollStatsLine(span))
        st = (now, 0, 0, 0, 0, 0, 0)
    }

    private func scrollStatsLine(_ span: Double) -> String {
        out.lock()
        let sent = scrollSent, dropped = scrollDropped
        scrollSent = 0; scrollDropped = 0
        out.unlock()
        guard sent + dropped > 0 else { return "" }
        return String(format: ", scroll %d notches (%.0f/s), %d dropped, ping %.0f ms", sent, Double(sent) / span, dropped, pingRTT * 1000)
    }

    private func readFramebufferUpdate() throws {
        let t0 = CFAbsoluteTimeGetCurrent(), bytes0 = socket.bytesReceived
        defer { noteStats(t0: t0, bytes0: bytes0, rects: statRects, pixels: statPixels) }
        statRects = 0; statPixels = 0
        _ = try socket.readU8()
        let n = Int(try socket.readU16())
        // ScreenLink Receiver: ask for the next frame now, so it's prepared while this one
        // downloads (one frame in flight). macOS gets the strict one-at-a-time flow control.
        let pipelined = !serverIsApple && hasFullPicture && !fullFramePending
        if pipelined { requestUpdate(incremental: true) }
        var dirty: [CGRect] = []
        var resized = false
        var coversPing = false
        let logThis = framesReceived < 6
        var encs: [Int32: Int] = [:]

        for _ in 0..<n {
            let x = Int(try socket.readU16())
            let y = Int(try socket.readU16())
            let w = Int(try socket.readU16())
            let h = Int(try socket.readU16())
            let enc = try socket.readS32()
            if logThis { encs[enc, default: 0] += 1 }
            if !hasFullPicture && dirty.count < 6 {
                ConnLog.write("rect enc \(enc) \(w)x\(h) at \(x),\(y) (\(bytesSinceConnect / 1024) KB in, \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - connectedAt))s)")
            }

            switch enc {
            case Encoding.raw: try decoder.raw(x: x, y: y, w: w, h: h)
            case Encoding.copyRect: try decoder.copyRect(x: x, y: y, w: w, h: h)
            case Encoding.rre: try decoder.rre(x: x, y: y, w: w, h: h)
            case Encoding.hextile: try decoder.hextile(x: x, y: y, w: w, h: h)
            case Encoding.zlib: try decoder.zlibRect(x: x, y: y, w: w, h: h)
            case Encoding.tight: try decoder.tight(x: x, y: y, w: w, h: h)
            case Encoding.zrle: try decoder.zrle(x: x, y: y, w: w, h: h)
            case Encoding.cursor:
                let c = try decoder.cursor(hotX: x, hotY: y, w: w, h: h)
                delegate?.rfb(self, cursorChanged: c)
                continue
            case Encoding.desktopSize:
                let fb = Framebuffer(width: w, height: h)
                framebuffer = fb
                decoder.fb = fb
                resized = true
                fullFramePending = true
                fullFrameArea = 0
                appleDisplayRects = []
                delegate?.rfbDidResize(self, framebuffer: fb)
                continue
            case Encoding.extendedDesktopSize:
                let count = Int(try socket.readU8())
                _ = try socket.readBytes(3)
                var screens: [CGRect] = []
                for _ in 0..<count {
                    let b = try socket.readBytes(16)
                    func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
                    screens.append(CGRect(x: u16(4), y: u16(6), width: u16(8), height: u16(10)))
                }
                ConnLog.write("extended desktop size \(w)x\(h) screens \(screens.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })")
                if let fb = framebuffer, fb.width != w || fb.height != h, w > 0, h > 0 {
                    let nfb = Framebuffer(width: w, height: h)
                    framebuffer = nfb
                    decoder.fb = nfb
                    resized = true
                    fullFramePending = true
                    fullFrameArea = 0
                    appleDisplayRects = []
                    delegate?.rfbDidResize(self, framebuffer: nfb)
                }
                delegate?.rfb(self, screens: screens)
                continue
            case Encoding.lastRect:
                break
            default:
                throw SocketError.io("Server used an unsupported encoding (\(enc)).")
            }
            if enc == Encoding.lastRect { break }
            dirty.append(CGRect(x: x, y: y, width: w, height: h))
            statRects += 1; statPixels += w * h
            if fullFramePending {
                fullFrameArea += w * h
                let r = CGRect(x: x, y: y, width: w, height: h)
                if serverIsApple && w >= 320 && h >= 240 && !appleDisplayRects.contains(r) {
                    appleDisplayRects.append(r)
                    if appleDisplayRects.count == 1 {   // the first display macOS sends: aim the pings there
                        out.lock(); pingTarget = (x + w - 1, y + h - 1); out.unlock()
                    }
                }
            }
            if pingPoint.x >= x && pingPoint.x < x + w && pingPoint.y >= y && pingPoint.y < y + h { coversPing = true }
        }

        if logThis {
            let area = dirty.reduce(0) { $0 + Int($1.width * $1.height) }
            ConnLog.write("update #\(framesReceived + 1): \(n) rects, encodings \(encs.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }), pixels \(area)\(resized ? ", resized" : "")")
        }
        lastRoundTrip = CFAbsoluteTimeGetCurrent() - lastRequest
        framesReceived += 1
        if coversPing {
            out.lock()
            if pingOutstanding {
                let rtt = CFAbsoluteTimeGetCurrent() - pingSent
                pingRTT = rtt < pingRTT ? rtt : pingRTT * 0.9 + rtt * 0.1
                pingOutstanding = false
                out.signal()
            }
            out.unlock()
        }
        // Only ask for the next frame once this one is fully read. This is the protocol's flow
        // control: the Mac never has more than one frame queued for us, so it can't get stuck
        // waiting on a slow phone (which would freeze Screen Sharing for every viewer).
        if fullFramePending, let fb = framebuffer, fullFrameArea >= fb.width * fb.height {
            fullFramePending = false
            reportAppleDisplays()
            if !hasFullPicture {
                hasFullPicture = true
                ConnLog.write("full picture received after \(framesReceived) updates, \(bytesSinceConnect / 1024) KB in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - connectedAt))s")
            } else {
                ConnLog.write("full picture received after \(framesReceived) updates")
            }
        }
        if !pipelined { requestUpdate(incremental: !fullFramePending) }
        if let fb = framebuffer {
            if resized { dirty = [CGRect(x: 0, y: 0, width: fb.width, height: fb.height)] }
            if !dirty.isEmpty { delegate?.rfb(self, didUpdate: fb, dirty: dirty) }
        }
    }

    // MARK: Outgoing messages
    //
    // Everything we send goes through one writer thread. The reading thread and the UI only
    // add to a queue, so neither can ever block on the network. Pointer motion is collapsed
    // to the latest position and scroll-wheel steps are paced, so a busy Mac is never flooded.

    // macOS moves only a few pixels per VNC wheel notch, so a normal trackpad swipe is dozens
    // of notches. They go out in batches once per display frame: about a third of what's waiting
    // each tick, so a swipe arrives within ~50 ms and still eases out smoothly. (The old pace of
    // one notch per tick, with a 16-notch queue, cut swipes short and made scrolling crawl.)
    private static let maxScrollBacklog = 64               // notches; extra is dropped, not queued
    // ScreenLink Receiver (Windows) handles input apart from the picture, so input never waits
    // behind a frame there: no ping gating, a deeper scroll queue, several notches per tick.
    private var scrollCap: Int { serverIsApple ? Self.maxScrollBacklog : 96 }
    private func notchesThisTick(_ pending: Int) -> Int {
        let n = abs(pending)
        guard serverIsApple else { return min(n, 6) }
        return min(n, max(1, (n + 2) / 3), 16)
    }
    private static let inputInterval: TimeInterval = 0.004 // pointer/scroll paced to ≤ 250 updates/s
    private static let appleMoveInterval: TimeInterval = 1.0 / 60
    private static let minPingInterval: TimeInterval = 0.1
    private static let appleScrollInterval: TimeInterval = 1.0 / 60

    private func startWriter() {
        out.lock(); writerRunning = true; out.unlock()
        let t = Thread { [weak self] in self?.writerLoop() }
        t.name = "ScreenLink.RFB.write"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func enqueue(_ bytes: [UInt8]) {
        out.lock()
        flushMoveLocked()
        outQueue += bytes
        out.signal()
        out.unlock()
    }

    /// Caller holds `out`. Turns a pending pointer move into a real message so ordering is kept.
    private func flushMoveLocked() {
        if let m = pendingMove {
            outQueue += pointerMessage(m.x, m.y, buttonMask)
            pendingMove = nil
        }
    }

    /// Non-incremental request for one pixel in the bottom-right corner. Caller holds `out`.
    private func pingMessageLocked() -> [UInt8]? {
        guard let fb = framebuffer else { return nil }
        if let t = pingTarget, t.x < fb.width, t.y < fb.height { pingPoint = t } else { pingPoint = (fb.width - 1, fb.height - 1) }
        var m: [UInt8] = [3, 0]
        m.appendU16(UInt16(pingPoint.x)); m.appendU16(UInt16(pingPoint.y))
        m.appendU16(1); m.appendU16(1)
        return m
    }

    private func pointerMessage(_ x: UInt16, _ y: UInt16, _ mask: UInt8) -> [UInt8] {
        var m: [UInt8] = [5, mask]
        m.appendU16(x); m.appendU16(y)
        return m
    }

    private func clampPoint(_ x: Int, _ y: Int) -> (x: UInt16, y: UInt16) {
        let fb = framebuffer
        return (UInt16(clamping: max(0, min(x, (fb?.width ?? 1) - 1))),
                UInt16(clamping: max(0, min(y, (fb?.height ?? 1) - 1))))
    }

    private func writerLoop() {
        var lastMove: CFAbsoluteTime = 0, lastScroll: CFAbsoluteTime = 0
        out.lock()
        while true {
            if stopped { out.unlock(); return }
            let now = CFAbsoluteTimeGetCurrent()
            // Pointer motion to a Mac goes out at display rate (only the latest position matters).
            // It is NOT paced by pings: a 1-pixel "forced" request answered right away makes macOS
            // reply with just that pixel, and a steady stream of them starved the real picture
            // (measured: 20-70 updates/s, nearly all empty, while dragging).
            let moveInterval = serverIsApple ? Self.appleMoveInterval : Self.inputInterval
            let hasMove = pendingMove != nil
            let hasScroll = pendingScroll.dx != 0 || pendingScroll.dy != 0
            let moveDue = hasMove && now - lastMove >= moveInterval
            let scrollInterval = serverIsApple ? Self.appleScrollInterval : Self.inputInterval
            let scrollDue = hasScroll && now - lastScroll >= scrollInterval
            if outQueue.isEmpty && !moveDue && !scrollDue {
                if hasMove || hasScroll {
                    let next = min(hasMove ? lastMove + moveInterval : .infinity,
                                   hasScroll ? lastScroll + scrollInterval : .infinity)
                    _ = out.wait(until: Date(timeIntervalSinceNow: max(0.0005, next - now)))
                } else {
                    out.wait()
                }
                continue
            }

            // Requests, clicks and keys always go straight out, in order.
            var batch = outQueue
            outQueue.removeAll(keepingCapacity: true)

            // Motion and scrolling are held back while data is still piling up unsent; then only
            // the latest position is sent. This keeps the Mac's input queue short.
            let backlogLow = (moveDue || scrollDue) && socket.sendBacklogIsLow()
            if moveDue {
                lastMove = now
                if backlogLow, let m = pendingMove {
                    batch += pointerMessage(m.x, m.y, buttonMask)
                    pendingMove = nil
                }
            }
            if scrollDue {
                lastScroll = now
                // Scrolling is what can flood a busy Mac (each notch is slow for it to handle), so it
                // still waits for a ping when the Mac is behind; pings go out at most 10 times a second.
                if pingOutstanding && now - pingSent > 1.0 { pingOutstanding = false }   // reply lost; carry on
                let allowance = max(0.08, pingRTT * 3)
                let macIsBehind = serverIsApple && pingOutstanding && now - pingSent > allowance
                if backlogLow && !macIsBehind {
                    let (sx, sy) = scrollAt
                    let ny = notchesThisTick(pendingScroll.dy), nx = notchesThisTick(pendingScroll.dx)
                    scrollSent += ny + nx
                    for _ in 0..<ny {
                        let bit: UInt8 = pendingScroll.dy > 0 ? 16 : 8
                        batch += pointerMessage(sx, sy, buttonMask | bit) + pointerMessage(sx, sy, buttonMask)
                        pendingScroll.dy -= pendingScroll.dy.signum()
                    }
                    for _ in 0..<nx {
                        let bit: UInt8 = pendingScroll.dx > 0 ? 64 : 32
                        batch += pointerMessage(sx, sy, buttonMask | bit) + pointerMessage(sx, sy, buttonMask)
                        pendingScroll.dx -= pendingScroll.dx.signum()
                    }
                    if serverIsApple, !pingOutstanding, now - pingSent >= Self.minPingInterval, let ping = pingMessageLocked() {
                        batch += ping
                        pingOutstanding = true
                        pingSent = now
                    }
                }
            }
            out.unlock()
            if !batch.isEmpty {
                do { try socket.write(batch) } catch { return }   // reader notices the closed socket
            }
            out.lock()
        }
    }

    // MARK: Input (callable from any thread, never blocks)

    /// Move the pointer (or, with `buttons`, also set the button state).
    func sendPointer(x: Int, y: Int, buttons: UInt8? = nil) {
        let p = clampPoint(x, y)
        out.lock()
        if let b = buttons {
            flushMoveLocked()
            buttonMask = b
            outQueue += pointerMessage(p.x, p.y, buttonMask)
        } else {
            pendingMove = p          // only the latest position matters
        }
        out.signal()
        out.unlock()
    }

    func setButton(_ bit: UInt8, down: Bool, x: Int, y: Int) {
        let p = clampPoint(x, y)
        out.lock()
        flushMoveLocked()
        buttonMask = down ? (buttonMask | bit) : (buttonMask & ~bit)
        outQueue += pointerMessage(p.x, p.y, buttonMask)
        out.signal()
        out.unlock()
    }

    /// Scroll wheel notches. dy > 0 = wheel down, dx > 0 = wheel right.
    func scroll(dx: Int, dy: Int, x: Int, y: Int) {
        guard dx != 0 || dy != 0 else { return }
        let p = clampPoint(x, y)
        let cap = scrollCap
        out.lock()
        flushMoveLocked()
        scrollAt = p
        // Changing direction cancels whatever was still queued the other way.
        if dy != 0 && pendingScroll.dy.signum() == -dy.signum() { pendingScroll.dy = 0 }
        if dx != 0 && pendingScroll.dx.signum() == -dx.signum() { pendingScroll.dx = 0 }
        let wantY = pendingScroll.dy + dy, wantX = pendingScroll.dx + dx
        pendingScroll.dy = max(-cap, min(cap, wantY))
        pendingScroll.dx = max(-cap, min(cap, wantX))
        scrollDropped += abs(wantY - pendingScroll.dy) + abs(wantX - pendingScroll.dx)
        out.signal()
        out.unlock()
    }

    func key(_ keysym: UInt32, down: Bool) {
        var m: [UInt8] = [4, down ? 1 : 0, 0, 0]
        m.appendU32(serverIsApple ? Keysym.forMac(keysym) : keysym)
        enqueue(m)
    }

    func tapKey(_ keysym: UInt32, modifiers: [UInt32] = []) {
        for mod in modifiers { key(mod, down: true) }
        key(keysym, down: true)
        key(keysym, down: false)
        for mod in modifiers.reversed() { key(mod, down: false) }
    }

    func sendClipboard(_ text: String) {
        // macOS Screen Sharing expects Latin-1; ScreenLink Receiver also takes UTF-8 (emoji, accents).
        let data = serverIsApple ? Array(text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data())
                                 : Array(text.utf8)
        var m: [UInt8] = [6, 0, 0, 0]
        m.appendU32(UInt32(data.count))
        m += data
        enqueue(m)
    }

    func refresh() {
        requestUpdate(incremental: false)
    }

    // MARK: Health

    /// Call about once a second. If nothing has arrived for a while, sends a tiny request the
    /// Mac must answer right away; if that goes unanswered too, the connection is declared
    /// stalled and closed (the app then reconnects automatically).
    func checkHealth() {
        guard !stopped, writerRunning else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let bytes = socket.bytesReceived
        if bytes != lastProgressBytes {
            lastProgressBytes = bytes
            lastProgressTime = now
            probeTime = nil
            return
        }
        if probeTime == nil {
            if now - lastProgressTime > 4 {
                probeTime = now
                out.lock(); let p = pingTarget ?? (0, 0); out.unlock()
                var m: [UInt8] = [3, 0]   // non-incremental, 1×1 on a display
                m.appendU16(UInt16(p.x)); m.appendU16(UInt16(p.y))
                m.appendU16(1); m.appendU16(1)
                enqueue(m)
            }
        } else if let p = probeTime, now - p > 6 {
            stallError = SocketError.io("The Mac stopped responding.")
            ConnLog.write("watchdog: no data for \(Int(now - lastProgressTime))s, closing")
            socket.close()
        }
    }
}
