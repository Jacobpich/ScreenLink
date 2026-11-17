import AppKit
import MetalKit

// MARK: - Keyboard capture

/// While a connected session window is in front, every key goes to the remote computer,
/// including ⌘-shortcuts (⌘C, ⌘W, ⌘Q…) that this app's own menus would otherwise take.
enum KeyCapture {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { e in
            guard let s = e.window?.windowController as? SessionController, s.capturesKeys else { return e }
            if s.handleDisplayShortcut(e) { return nil }
            s.handleKey(e)
            return nil
        }
    }
}

enum MacKeyMap {
    static let special: [UInt16: UInt32] = [
        36: Keysym.returnKey, 76: Keysym.returnKey, 48: Keysym.tab, 49: Keysym.space,
        51: Keysym.backspace, 117: Keysym.delete, 53: Keysym.escape,
        123: Keysym.left, 124: Keysym.right, 125: Keysym.down, 126: Keysym.up,
        115: Keysym.home, 119: Keysym.end, 116: Keysym.pageUp, 121: Keysym.pageDown,
        114: 0xFF63, // Help/Insert
        122: Keysym.function(1), 120: Keysym.function(2), 99: Keysym.function(3), 118: Keysym.function(4),
        96: Keysym.function(5), 97: Keysym.function(6), 98: Keysym.function(7), 100: Keysym.function(8),
        101: Keysym.function(9), 109: Keysym.function(10), 103: Keysym.function(11), 111: Keysym.function(12),
    ]

    /// Modifier key code → keysym and its device-dependent flag bit (left/right told apart).
    static func modifier(_ code: UInt16) -> (sym: UInt32, mask: UInt)? {
        switch code {
        case 56: return (Keysym.shift, 0x2)
        case 60: return (0xFFE2, 0x4)
        case 59: return (Keysym.control, 0x1)
        case 62: return (0xFFE4, 0x2000)
        case 58: return (Keysym.option, 0x20)
        case 61: return (0xFFEA, 0x40)
        case 55: return (Keysym.command, 0x8)
        case 54: return (0xFFE8, 0x10)   // right ⌘ (Meta_R; sent to a Mac as Super_R)
        default: return nil
        }
    }

    static func keysym(for e: NSEvent) -> UInt32? {
        if let s = special[e.keyCode] { return s }
        let f = e.modifierFlags
        let chars: String?
        if f.contains(.command) || f.contains(.control) {
            // ⌘⇧3 should arrive as ⌘ + Shift + "3", not "#".
            chars = e.characters(byApplyingModifiers: [])
        } else {
            chars = e.charactersIgnoringModifiers   // includes Shift, ignores Option
        }
        guard let ch = chars?.first else { return nil }
        return Keysym.forCharacter(ch)?.0
    }
}

// MARK: - Session window

final class SessionController: NSWindowController, NSWindowDelegate, RFBConnectionDelegate {
    enum State: Equatable {
        case connecting, reconnecting(Int), connected
        case signIn(String, needsUser: Bool)
        case failed(String)
    }

    private static var sessions: [UUID: SessionController] = [:]

    static var current: SessionController? {
        NSApp.keyWindow?.windowController as? SessionController
            ?? NSApp.mainWindow?.windowController as? SessionController
    }

    static func open(_ host: SavedHost, password: String? = nil) {
        if let s = sessions[host.id] {
            s.window?.makeKeyAndOrderFront(nil)
            if case .failed = s.state { s.connect() }
            return
        }
        let s = SessionController(host: host, password: password ?? HostStore.shared.password(for: host) ?? "")
        sessions[host.id] = s
        s.showWindow(nil)
        s.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        s.start()
    }

    private(set) var host: SavedHost
    private var password: String
    private var typedCredentials = false
    private(set) var connection: RFBConnection?
    private(set) var state: State = .connecting { didSet { stateChanged() } }
    private var everConnected = false
    private var retryCount = 0
    private var closing = false
    private var isPC = false

    private let remoteView: RemoteView
    private let renderer: ScreenRenderer
    private let overlay = StatusOverlay()

    private var fbSize = CGSize.zero
    private var visible = CGRect.zero          // part of the framebuffer shown (whole or one display)

    // Displays: regions of the shared desktop image (from the PC's monitor list, or found in
    // the picture for a Mac, which sends all its displays as one wide image).
    private(set) var displays: [CGRect] = []
    private(set) var selectedDisplay: Int?
    private(set) var displayLayoutIsManual = false
    private var serverScreens: [CGRect] = []
    private var needsDisplayDetection = true
    private var restoredDisplaySelection = false
    private let flashLabel = FlashLabel()
    private var contentRect = CGRect.zero      // where it's drawn, in view points (top-left origin)
    private var sizedWindow = false

    private var remoteCursor: CursorImage?
    private(set) var cursor: NSCursor = .arrow

    private var heldKeys: [UInt16: UInt32] = [:]
    private var heldMods: Set<UInt32> = []
    private var scrollRemainder = CGPoint.zero
    private var buttonMask: UInt8 = 0

    private var lastPasteboardCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    private let drawLock = NSLock()
    private var drawPending = false

    var capturesKeys: Bool { state == .connected && connection != nil }

    init(host: SavedHost, password: String) {
        self.host = host
        self.password = password
        let view = RemoteView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        remoteView = view
        guard let r = ScreenRenderer(view: view) else { fatalError("Metal isn't available on this Mac.") }
        renderer = r
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = host.name.isEmpty ? host.address : host.name
        window.subtitle = "Connecting…"
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("ScreenLinkSession-\(host.id.uuidString)")
        if window.frame.width < 200 { window.center() }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        container.addSubview(overlay)
        flashLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(flashLabel)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            overlay.widthAnchor.constraint(equalToConstant: 340),
            flashLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            flashLabel.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
        window.contentView = container
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "ScreenLinkSession")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        view.session = self
        overlay.onConnect = { [weak self] user, pass in self?.signIn(user: user, password: pass) }
        overlay.onRetry = { [weak self] in self?.connect() }
        overlay.onClose = { [weak self] in self?.window?.performClose(nil) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        if password.isEmpty {
            state = .signIn("Enter the password for \(window?.title ?? "this computer").", needsUser: false)
        } else {
            connect()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: Connection

    func connect() {
        connection?.delegate = nil
        connection?.stop()
        closing = false
        state = everConnected ? .reconnecting(max(1, retryCount)) : .connecting
        let cfg = ConnectionConfig(host: host.address.trimmingCharacters(in: .whitespaces), homeHost: host.home,
                                   port: host.port, username: host.username, password: password,
                                   quality: host.quality)
        let c = RFBConnection(config: cfg)
        c.delegate = self
        connection = c
        c.start()
    }

    private func signIn(user: String?, password: String) {
        if let user { host.username = user }
        self.password = password
        typedCredentials = true
        connect()
    }

    func rfbDidConnect(_ c: RFBConnection, name: String, framebuffer: Framebuffer) {
        renderer.upload(framebuffer, dirty: [])
        DispatchQueue.main.async { [weak self] in
            guard let self, c === self.connection else { return }
            self.everConnected = true
            self.retryCount = 0
            self.isPC = !c.serverIsApple
            self.state = .connected
            self.applySize(CGSize(width: framebuffer.width, height: framebuffer.height))
            if self.typedCredentials, HostStore.shared.hosts.contains(where: { $0.id == self.host.id }) {
                self.typedCredentials = false
                HostStore.shared.upsert(self.host, password: self.password)
            }
            HostStore.shared.markConnected(self.host.id)
            if self.window?.isKeyWindow == true { self.sendLocalClipboardIfChanged(force: true) }
        }
    }

    func rfbDidResize(_ c: RFBConnection, framebuffer: Framebuffer) {
        renderer.upload(framebuffer, dirty: [])
        DispatchQueue.main.async { [weak self] in
            self?.applySize(CGSize(width: framebuffer.width, height: framebuffer.height))
        }
    }

    func rfb(_ c: RFBConnection, didUpdate framebuffer: Framebuffer, dirty: [CGRect]) {
        renderer.upload(framebuffer, dirty: dirty)
        scheduleDraw()
    }

    /// Runs on the main thread after picture updates have been drawn.
    private func afterUpdate() {
        // Wait for the whole picture: a Mac's multi-display picture loads in over a second or more,
        // and looking earlier finds a false edge where the loaded part ends.
        guard needsDisplayDetection, fbSize.width > 0, connection?.hasFullPicture == true else { return }
        needsDisplayDetection = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.detectDisplays(retry: true) }
    }

    func rfb(_ c: RFBConnection, cursorChanged cursor: CursorImage?) {
        DispatchQueue.main.async { [weak self] in
            self?.remoteCursor = cursor
            self?.rebuildCursor()
        }
    }

    func rfb(_ c: RFBConnection, clipboard text: String) {
        DispatchQueue.main.async { [weak self] in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self?.lastPasteboardCount = pb.changeCount
        }
    }

    func rfb(_ c: RFBConnection, screens: [CGRect]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.serverScreens = screens
            if screens.count > 1 { self.detectDisplays(retry: false) }
        }
    }

    func rfb(_ c: RFBConnection, didFail error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, c === self.connection, !self.closing else { return }
            self.connection = nil
            self.releaseAllKeys()
            let isAuth = error is AuthError
            if self.everConnected && !isAuth && self.retryCount < 6 {
                self.retryCount += 1
                self.state = .reconnecting(self.retryCount)
                let delay = min(4.0, 0.5 * Double(self.retryCount))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.closing, self.connection == nil else { return }
                    self.connect()
                }
            } else if isAuth {
                var needsUser = !self.host.username.isEmpty
                if case .needsUsername = error as? AuthError { needsUser = true }
                self.state = .signIn(error?.localizedDescription ?? "Sign-in failed.", needsUser: needsUser)
            } else {
                self.state = .failed(error?.localizedDescription ?? "Disconnected.")
            }
        }
    }

    private func stateChanged() {
        guard let window else { return }
        switch state {
        case .connected:
            overlay.isHidden = true
            var parts = [isPC ? "Windows PC" : "Mac"]
            if let i = selectedDisplay, displays.indices.contains(i) {
                parts.append("Display \(i + 1) of \(displays.count)")
            } else if displays.count > 1 {
                parts.append("All \(displays.count) displays")
            }
            if visible.width > 0 { parts.append("\(Int(visible.width))×\(Int(visible.height))") }
            window.subtitle = parts.joined(separator: " · ")
            window.makeFirstResponder(remoteView)
        case .connecting:
            overlay.show(busy: "Connecting…")
            window.subtitle = "Connecting…"
        case .reconnecting(let n):
            overlay.show(busy: n > 1 ? "Reconnecting… (try \(n))" : "Reconnecting…")
            window.subtitle = "Reconnecting…"
        case .signIn(let message, let needsUser):
            overlay.showSignIn(message: message, user: needsUser ? host.username : nil, password: password)
            window.subtitle = "Sign in"
        case .failed(let message):
            overlay.showFailure(message)
            window.subtitle = "Not connected"
        }
    }

    private func tick() {
        guard let c = connection, state == .connected else { return }
        c.checkHealth()
        if window?.isKeyWindow == true { sendLocalClipboardIfChanged(force: false) }
    }

    // MARK: Drawing and layout

    private func scheduleDraw() {
        drawLock.lock()
        if drawPending { drawLock.unlock(); return }
        drawPending = true
        drawLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drawLock.lock(); self.drawPending = false; self.drawLock.unlock()
            self.remoteView.needsDisplay = true
            self.afterUpdate()
        }
    }

    private func applySize(_ size: CGSize) {
        let changed = size != fbSize
        fbSize = size
        if changed {
            displays = []
            serverScreens = []
            visible = CGRect(origin: .zero, size: size)
        }
        needsDisplayDetection = true
        if !sizedWindow { sizeWindowToFit() }
        updateAspect()
        layout()
        stateChanged()
        publishDisplays()
    }

    // MARK: Displays

    private var layoutKey: String { "displayLayout.\(host.id.uuidString)" }
    private var selectionKey: String { "displaySelection.\(host.id.uuidString)" }
    private var fullRect: CGRect { CGRect(origin: .zero, size: fbSize) }

    /// The saved manual layout as [columns, rows], if one is set for this computer.
    var manualLayout: [Int]? {
        guard let a = UserDefaults.standard.array(forKey: layoutKey) as? [Int], a.count == 2 else { return nil }
        return a
    }

    /// Shows one display, or all of them (nil). Remembered for this computer.
    func selectDisplay(_ index: Int?, announce: Bool = true) {
        guard fbSize.width > 0 else { return }
        let index = index.flatMap { displays.indices.contains($0) ? $0 : nil }
        selectedDisplay = index
        UserDefaults.standard.set(index ?? -1, forKey: selectionKey)
        visible = index.map { displays[$0].intersection(fullRect) } ?? fullRect
        if visible.isEmpty { visible = fullRect }
        connection?.setUpdateRegion(visible == fullRect ? nil : visible)
        updateAspect()
        sizeWindowToFit()
        layout()
        stateChanged()
        publishDisplays()
        if announce {
            if let index {
                let r = displays[index]
                flashLabel.flash("Display \(index + 1)  ·  \(Int(r.width))×\(Int(r.height))")
            } else {
                flashLabel.flash("All Displays")
            }
        }
    }

    /// Next/previous display, like the iPhone's four-finger swipe. Going back past the first shows all.
    func stepDisplay(_ delta: Int) {
        let n = displays.count
        guard n > 1 else { flashLabel.flash("Only one display found"); return }
        if delta > 0 {
            let next = selectedDisplay.map { min(n - 1, $0 + 1) } ?? 0
            if next != selectedDisplay { selectDisplay(next) }
        } else if let cur = selectedDisplay {
            selectDisplay(cur == 0 ? nil : cur - 1)
        }
    }

    func setManualLayout(columns: Int, rows: Int) {
        UserDefaults.standard.set([columns, rows], forKey: layoutKey)
        applyDisplays(DisplayDetector.even(fullRect, columns: columns, rows: rows), manual: true)
        selectDisplay(displays.isEmpty ? nil : 0)
    }

    func redetectDisplays() {
        UserDefaults.standard.removeObject(forKey: layoutKey)
        detectDisplays(retry: false, announce: true)
    }

    private func detectDisplays(retry: Bool, announce: Bool = false) {
        guard fbSize.width > 0 else { return }
        if let saved = manualLayout {
            applyDisplays(DisplayDetector.even(fullRect, columns: saved[0], rows: saved[1]), manual: true)
            return
        }
        if serverScreens.count > 1 {
            applyDisplays(serverScreens, manual: false)
            if announce { flashLabel.flash("Found \(serverScreens.count) displays") }
            return
        }
        guard let fb = connection?.framebuffer else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = DisplayDetector.detect(fb)
            DispatchQueue.main.async {
                guard let self, fb === self.connection?.framebuffer else { return }
                self.applyDisplays(found.count > 1 ? found : [], manual: false)
                if announce {
                    self.flashLabel.flash(found.count > 1 ? "Found \(found.count) displays" : "Only one display found")
                }
                // Content may still have been loading; look once more.
                if retry && found.count <= 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.detectDisplays(retry: false) }
                }
            }
        }
    }

    private func applyDisplays(_ rects: [CGRect], manual: Bool) {
        displays = rects
        displayLayoutIsManual = manual
        var restore: Int?
        if !restoredDisplaySelection, rects.count > 1 {
            restoredDisplaySelection = true
            let saved = UserDefaults.standard.object(forKey: selectionKey) as? Int ?? -1
            if rects.indices.contains(saved) { restore = saved }
        }
        if let restore {
            selectDisplay(restore, announce: false)
        } else if let i = selectedDisplay, rects.indices.contains(i) {
            selectDisplay(i, announce: false)    // the display's rectangle may have moved
        } else {
            selectedDisplay = nil
            if visible != fullRect { selectDisplay(nil, announce: false) }
            stateChanged()
            publishDisplays()
        }
    }

    /// ⌃⌥⌘→ / ⌃⌥⌘← switch displays, ⌃⌥⌘0 shows all, ⌃⌥⌘1–9 picks one.
    func handleDisplayShortcut(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown || e.type == .keyUp else { return false }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.command), f.contains(.option), f.contains(.control) else { return false }
        let digits: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        guard e.keyCode == 123 || e.keyCode == 124 || digits[e.keyCode] != nil else { return false }
        guard e.type == .keyDown, !e.isARepeat else { return true }
        switch e.keyCode {
        case 124: stepDisplay(1)
        case 123: stepDisplay(-1)
        default:
            let d = digits[e.keyCode]!
            if d == 0 { selectDisplay(nil) }
            else if displays.indices.contains(d - 1) { selectDisplay(d - 1) }
        }
        return true
    }

    /// Keeps the menu bar's Displays menu in step with the session in front.
    private func publishDisplays() {
        guard window?.isKeyWindow == true || DisplayMenuModel.shared.session === self else { return }
        DisplayMenuModel.shared.update(from: self)
    }

    private func sizeWindowToFit() {
        guard let window, visible.width > 0, let screen = window.screen ?? NSScreen.main else { return }
        sizedWindow = true
        if window.styleMask.contains(.fullScreen) { return }
        let vf = screen.visibleFrame
        let chrome = window.frame.height - window.contentLayoutRect.height
        let maxW = vf.width * 0.92, maxH = (vf.height - chrome) * 0.92
        let s = min(maxW / visible.width, maxH / visible.height, 1)
        let size = NSSize(width: (visible.width * s).rounded(), height: (visible.height * s).rounded())
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = vf.midX - frame.width / 2
        frame.origin.y = vf.midY - frame.height / 2
        window.setFrame(frame, display: true, animate: false)
    }

    private func updateAspect() {
        guard visible.width > 0 else { return }
        window?.contentAspectRatio = visible.size
    }

    func layout() {
        let b = remoteView.bounds.size
        guard fbSize.width > 0, visible.width > 0, b.width > 0, b.height > 0 else { return }
        let s = min(b.width / visible.width, b.height / visible.height)
        let w = visible.width * s, h = visible.height * s
        contentRect = CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
        renderer.contentRect = contentRect
        renderer.textureRect = CGRect(x: visible.minX / fbSize.width, y: visible.minY / fbSize.height,
                                      width: visible.width / fbSize.width, height: visible.height / fbSize.height)
        let backing = window?.backingScaleFactor ?? 2
        let px = s * backing
        renderer.mipmapsWanted = px < 0.99
        renderer.useNearestFiltering = abs(px - 1) < 0.01
        renderer.cursorPoint = nil
        remoteView.needsDisplay = true
        rebuildCursor()
    }

    /// Points-per-remote-pixel of the current view.
    private var viewScale: CGFloat { visible.width > 0 ? contentRect.width / visible.width : 1 }

    // MARK: Cursor

    private func rebuildCursor() {
        guard let c = remoteCursor, c.width > 0, c.height > 0, c.pixels.count >= c.width * c.height else {
            cursor = .arrow
            applyCursorIfInside()
            return
        }
        var px = c.pixels
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let image: CGImage? = px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: c.width, height: c.height, bitsPerComponent: 8,
                      bytesPerRow: c.width * 4, space: cs, bitmapInfo: info)?.makeImage()
        }
        guard let image else { cursor = .arrow; return }
        let s = min(2, max(0.5, viewScale))
        let size = NSSize(width: CGFloat(c.width) * s, height: CGFloat(c.height) * s)
        cursor = NSCursor(image: NSImage(cgImage: image, size: size),
                          hotSpot: NSPoint(x: CGFloat(c.hotX) * s, y: CGFloat(c.hotY) * s))
        applyCursorIfInside()
    }

    private func applyCursorIfInside() {
        guard let window, window.isKeyWindow else { return }
        let p = remoteView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if remoteView.bounds.contains(p) { cursor.set() }
    }

    // MARK: Mouse

    private func remotePoint(_ e: NSEvent) -> (Int, Int) {
        let p = remoteView.convert(e.locationInWindow, from: nil)
        guard contentRect.width > 0 else { return (0, 0) }
        let u = min(max((p.x - contentRect.minX) / contentRect.width, 0), 0.9999)
        let v = min(max((p.y - contentRect.minY) / contentRect.height, 0), 0.9999)
        return (Int(visible.minX + u * visible.width), Int(visible.minY + v * visible.height))
    }

    func pointerMoved(_ e: NSEvent) {
        guard let c = connection, state == .connected else { return }
        let (x, y) = remotePoint(e)
        c.sendPointer(x: x, y: y)
    }

    func mouseButton(_ e: NSEvent, bit: UInt8, down: Bool) {
        guard let c = connection, state == .connected else { return }
        let (x, y) = remotePoint(e)
        buttonMask = down ? buttonMask | bit : buttonMask & ~bit
        c.setButton(bit, down: down, x: x, y: y)
    }

    func remoteScroll(_ e: NSEvent) {
        guard let c = connection, state == .connected else { return }
        var dx = -e.scrollingDeltaX, dy = -e.scrollingDeltaY
        if e.hasPreciseScrollingDeltas { dx /= 10; dy /= 10 } else { dx *= 3; dy *= 3 }
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let nx = Int(scrollRemainder.x), ny = Int(scrollRemainder.y)
        scrollRemainder.x -= CGFloat(nx)
        scrollRemainder.y -= CGFloat(ny)
        if e.phase == .began { scrollRemainder = .zero }
        guard nx != 0 || ny != 0 else { return }
        let (x, y) = remotePoint(e)
        c.scroll(dx: nx, dy: ny, x: x, y: y)
    }

    // MARK: Keyboard

    func handleKey(_ e: NSEvent) {
        guard let c = connection else { return }
        switch e.type {
        case .flagsChanged:
            if e.keyCode == 57 {   // Caps Lock: each change is one press
                c.key(Keysym.capsLock, down: true)
                c.key(Keysym.capsLock, down: false)
                return
            }
            guard let (sym, mask) = MacKeyMap.modifier(e.keyCode) else { return }
            let down = e.modifierFlags.rawValue & mask != 0
            if down {
                heldMods.insert(sym)
            } else {
                heldMods.remove(sym)
                // macOS can swallow key-ups while ⌘ is held; let go of anything still down.
                if e.keyCode == 55 || e.keyCode == 54 { releaseHeldKeys() }
            }
            c.key(sym, down: down)
        case .keyDown:
            guard let sym = heldKeys[e.keyCode] ?? MacKeyMap.keysym(for: e) else { return }
            heldKeys[e.keyCode] = sym
            c.key(sym, down: true)
        case .keyUp:
            if let sym = heldKeys.removeValue(forKey: e.keyCode) { c.key(sym, down: false) }
        default:
            break
        }
    }

    private func releaseHeldKeys() {
        for (_, sym) in heldKeys { connection?.key(sym, down: false) }
        heldKeys.removeAll()
    }

    private func releaseAllKeys() {
        releaseHeldKeys()
        for sym in heldMods { connection?.key(sym, down: false) }
        heldMods.removeAll()
        if buttonMask != 0, let c = connection {
            for bit in [UInt8(1), 2, 4] where buttonMask & bit != 0 { c.setButton(bit, down: false, x: 0, y: 0) }
            buttonMask = 0
        }
    }

    func sendShortcut(_ key: UInt32, modifiers: [UInt32]) {
        guard let c = connection, state == .connected else { return }
        c.tapKey(key, modifiers: modifiers)
    }

    /// Types the Mac's clipboard text on the remote computer, for places paste doesn't work.
    func typeClipboard() {
        guard let c = connection, state == .connected,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        for ch in text.prefix(4000) {
            guard let (sym, shift) = Keysym.forCharacter(ch) else { continue }
            c.tapKey(sym, modifiers: shift ? [Keysym.shift] : [])
        }
    }

    // MARK: Clipboard

    private func sendLocalClipboardIfChanged(force: Bool) {
        let pb = NSPasteboard.general
        guard force || pb.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pb.changeCount
        guard let c = connection, state == .connected, let text = pb.string(forType: .string), !text.isEmpty else { return }
        c.sendClipboard(text)
    }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        DisplayMenuModel.shared.update(from: self)
        if state == .connected {
            window?.makeFirstResponder(remoteView)
            sendLocalClipboardIfChanged(force: false)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        releaseAllKeys()
    }

    /// Full screen looks like sitting at the other computer: the title bar and Displays button
    /// stay hidden (they slide down with the menu bar if the pointer rests at the top edge) and
    /// come back as normal when the window leaves full screen.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar, .autoHideDock])
    }

    func windowDidResize(_ notification: Notification) { layout() }
    func windowDidChangeBackingProperties(_ notification: Notification) { layout() }

    func windowWillClose(_ notification: Notification) {
        closing = true
        releaseAllKeys()
        timer?.invalidate()
        connection?.delegate = nil
        connection?.stop()
        connection = nil
        Self.sessions[host.id] = nil
        if DisplayMenuModel.shared.session === self { DisplayMenuModel.shared.update(from: nil) }
    }
}

// MARK: - The picture view

final class RemoteView: MTKView {
    weak var session: SessionController?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        session?.layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) { (session?.cursor ?? .arrow).set() }
    override func mouseEntered(with event: NSEvent) { (session?.cursor ?? .arrow).set() }

    override func mouseMoved(with e: NSEvent) { session?.pointerMoved(e) }
    override func mouseDragged(with e: NSEvent) { session?.pointerMoved(e) }
    override func rightMouseDragged(with e: NSEvent) { session?.pointerMoved(e) }
    override func otherMouseDragged(with e: NSEvent) { session?.pointerMoved(e) }

    override func mouseDown(with e: NSEvent) { session?.mouseButton(e, bit: 1, down: true) }
    override func mouseUp(with e: NSEvent) { session?.mouseButton(e, bit: 1, down: false) }
    override func rightMouseDown(with e: NSEvent) { session?.mouseButton(e, bit: 4, down: true) }
    override func rightMouseUp(with e: NSEvent) { session?.mouseButton(e, bit: 4, down: false) }
    override func otherMouseDown(with e: NSEvent) { if e.buttonNumber == 2 { session?.mouseButton(e, bit: 2, down: true) } }
    override func otherMouseUp(with e: NSEvent) { if e.buttonNumber == 2 { session?.mouseButton(e, bit: 2, down: false) } }
    override func scrollWheel(with e: NSEvent) { session?.remoteScroll(e) }

    // Keys are taken by KeyCapture before they get here; swallow strays so nothing beeps.
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { session?.capturesKeys == true }
}

// MARK: - Status / sign-in overlay

final class StatusOverlay: NSVisualEffectView {
    var onConnect: ((String?, String) -> Void)?
    var onRetry: (() -> Void)?
    var onClose: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let userField = NSTextField()
    private let passField = NSSecureTextField()
    private let primary = NSButton(title: "Connect", target: nil, action: nil)
    private let secondary = NSButton(title: "Close", target: nil, action: nil)
    private var mode = 0   // 0 busy, 1 sign-in, 2 failed

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14

        spinner.style = .spinning
        spinner.controlSize = .regular
        title.alignment = .center
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.preferredMaxLayoutWidth = 300
        userField.placeholderString = "Username"
        passField.placeholderString = "Password"
        for f in [userField, passField] as [NSTextField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        primary.keyEquivalent = "\r"
        primary.bezelStyle = .rounded
        secondary.bezelStyle = .rounded
        primary.target = self; primary.action = #selector(primaryTapped)
        secondary.target = self; secondary.action = #selector(secondaryTapped)
        passField.target = self; passField.action = #selector(primaryTapped)

        let buttons = NSStackView(views: [secondary, primary])
        buttons.spacing = 10
        let stack = NSStackView(views: [spinner, title, userField, passField, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(busy message: String) {
        mode = 0
        isHidden = false
        spinner.isHidden = false
        spinner.startAnimation(nil)
        title.stringValue = message
        userField.isHidden = true
        passField.isHidden = true
        primary.isHidden = true
        secondary.title = "Cancel"
        secondary.isHidden = false
    }

    func showSignIn(message: String, user: String?, password: String) {
        mode = 1
        isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        title.stringValue = message
        userField.isHidden = user == nil
        userField.stringValue = user ?? ""
        passField.isHidden = false
        passField.stringValue = ""
        primary.title = "Connect"
        primary.isHidden = false
        secondary.title = "Close"
        secondary.isHidden = false
        DispatchQueue.main.async {
            self.window?.makeFirstResponder(user != nil && (user ?? "").isEmpty ? self.userField : self.passField)
        }
    }

    func showFailure(_ message: String) {
        mode = 2
        isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        title.stringValue = message
        userField.isHidden = true
        passField.isHidden = true
        primary.title = "Try Again"
        primary.isHidden = false
        secondary.title = "Close"
        secondary.isHidden = false
    }

    @objc private func primaryTapped() {
        switch mode {
        case 1:
            guard !passField.stringValue.isEmpty else { return }
            onConnect?(userField.isHidden ? nil : userField.stringValue, passField.stringValue)
        case 2: onRetry?()
        default: break
        }
    }

    @objc private func secondaryTapped() { onClose?() }
}
