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
    private var scrollAt: (x: UInt16, y: UInt16) = (0, 0)
    private var writerRunning = false

    // Input flow control: a tiny request the Mac must answer immediately ("ping"). Because the
    // Mac handles messages in order, its reply time shows how far behind it is on our input.
    private var pingOutstanding = false        // guarded by `out`
    private var pingSent: CFAbsoluteTime = 0
    private var pingRTT: Double = 0.05
    private var pingPoint = (x: 0, y: 0)

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
        var m: [UInt8] = [3, incremental ? 1 : 0, 0, 0, 0, 0]
        m.appendU16(UInt16(fb.width)); m.appendU16(UInt16(fb.height))
        lastRequest = CFAbsoluteTimeGetCurrent()
        enqueue(m)
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
    /// False until the first complete picture of the desktop has arrived (read from the UI).
    private(set) var hasFullPicture = false
    private var connectedAt = CFAbsoluteTimeGetCurrent()
    private var bytesAtConnect = 0
    /// Bytes received since the session started (for the loading indicator).
    var bytesSinceConnect: Int { socket.bytesReceived - bytesAtConnect }

    private func readFramebufferUpdate() throws {
        _ = try socket.readU8()
        let n = Int(try socket.readU16())
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
            if fullFramePending { fullFrameArea += w * h }
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
            if !hasFullPicture {
                hasFullPicture = true
                ConnLog.write("full picture received after \(framesReceived) updates, \(bytesSinceConnect / 1024) KB in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - connectedAt))s")
            } else {
                ConnLog.write("full picture received after \(framesReceived) updates")
            }
        }
        requestUpdate(incremental: !fullFramePending)
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

    private static let maxScrollBacklog = 16               // notches; extra is dropped, not queued
    private static let inputInterval: TimeInterval = 0.004 // pointer/scroll paced to ≤ 250 updates/s

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
        pingPoint = (fb.width - 1, fb.height - 1)
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
        var lastInput: CFAbsoluteTime = 0
        out.lock()
        while true {
            if stopped { out.unlock(); return }
            let now = CFAbsoluteTimeGetCurrent()
            let hasInput = pendingMove != nil || pendingScroll.dx != 0 || pendingScroll.dy != 0
            let inputDue = hasInput && now - lastInput >= Self.inputInterval
            if outQueue.isEmpty && !inputDue {
                if hasInput {
                    _ = out.wait(until: Date(timeIntervalSinceNow: max(0.0005, lastInput + Self.inputInterval - now)))
                } else {
                    out.wait()
                }
                continue
            }

            // Requests, clicks and keys always go straight out, in order.
            var batch = outQueue
            outQueue.removeAll(keepingCapacity: true)

            // Pointer motion and scrolling are paced, and held back entirely while data is
            // still piling up unsent — then only the latest position is sent. This keeps the
            // Mac's input queue short, so frame requests never wait behind a backlog.
            if inputDue {
                lastInput = now
                if pingOutstanding && now - pingSent > 1.0 { pingOutstanding = false }   // reply lost; carry on
                let allowance = max(0.04, pingRTT * 2)
                let macIsBehind = pingOutstanding && now - pingSent > allowance
                if !macIsBehind && socket.sendBacklogIsLow() {
                    if let m = pendingMove {
                        batch += pointerMessage(m.x, m.y, buttonMask)
                        pendingMove = nil
                    }
                    let (sx, sy) = scrollAt
                    if pendingScroll.dy != 0 {
                        let bit: UInt8 = pendingScroll.dy > 0 ? 16 : 8
                        batch += pointerMessage(sx, sy, buttonMask | bit) + pointerMessage(sx, sy, buttonMask)
                        pendingScroll.dy -= pendingScroll.dy.signum()
                    }
                    if pendingScroll.dx != 0 {
                        let bit: UInt8 = pendingScroll.dx > 0 ? 64 : 32
                        batch += pointerMessage(sx, sy, buttonMask | bit) + pointerMessage(sx, sy, buttonMask)
                        pendingScroll.dx -= pendingScroll.dx.signum()
                    }
                    if !pingOutstanding, let ping = pingMessageLocked() {
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
        let cap = Self.maxScrollBacklog
        out.lock()
        flushMoveLocked()
        scrollAt = p
        // Changing direction cancels whatever was still queued the other way.
        if dy != 0 && pendingScroll.dy.signum() == -dy.signum() { pendingScroll.dy = 0 }
        if dx != 0 && pendingScroll.dx.signum() == -dx.signum() { pendingScroll.dx = 0 }
        pendingScroll.dy = max(-cap, min(cap, pendingScroll.dy + dy))
        pendingScroll.dx = max(-cap, min(cap, pendingScroll.dx + dx))
        out.signal()
        out.unlock()
    }

    func key(_ keysym: UInt32, down: Bool) {
        var m: [UInt8] = [4, down ? 1 : 0, 0, 0]
        m.appendU32(keysym)
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
                var m: [UInt8] = [3, 0, 0, 0, 0, 0]   // non-incremental, 1×1 at the origin
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
