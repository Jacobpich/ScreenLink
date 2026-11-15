import UIKit
import MetalKit
import SwiftUI
import Combine

/// Full-screen remote session: Metal screen, gestures, keyboard and toolbar.
final class RemoteViewController: UIViewController, RFBConnectionDelegate, UIGestureRecognizerDelegate {
    private var host: SavedHost
    private var password: String
    let model: SessionModel

    private var connection: RFBConnection?
    private let inputQueue = DispatchQueue(label: "ScreenLink.input", qos: .userInteractive)

    private var mtkView: MTKView!
    private var renderer: ScreenRenderer!
    private let keyInput = KeyInputView()
    private let modifierBar = ModifierBar()
    private var overlayHost: UIHostingController<SessionOverlay>!
    private var toolbarHost: UIHostingController<SessionToolbar>!
    private var cancellables = Set<AnyCancellable>()

    // Displays (regions of the shared desktop image)
    private var needsDisplayDetection = true
    private var serverScreens: [CGRect] = []
    private var restoredDisplaySelection = false

    // Viewport (remote pixels ↔ view points)
    private var fbSize = CGSize.zero
    private var scale: CGFloat = 1                 // points per remote pixel
    private var offset = CGPoint.zero              // remote pixel at the view's top-left
    private var userZoomed = false
    private var keyboardHeight: CGFloat = 0
    private var lastLayoutSize = CGSize.zero

    // Pointer
    private var cursorPos = CGPoint.zero
    private var cursorHidden = false
    private var hasServerCursor = false
    private var textCursor = false                 // Mac is showing the I-beam
    // Waiting after a click to see whether the Mac switches to the I-beam.
    private var keyboardCheck: (id: CFTimeInterval, pos: CGPoint, sawUpdate: Bool)?

    // Gesture state
    private enum TwoFinger { case undecided, scroll, zoom }
    private var twoFingerMode = TwoFinger.undecided
    private var pinchCumulative: CGFloat = 1
    private var lastPan = CGPoint.zero
    private var lastTwoPan = CGPoint.zero
    private var smoothedSpeed: CGFloat = 0
    private var pinchSpanStart: CGFloat = 100
    private enum ScrollAxis { case undecided, vertical, horizontal, free }
    private var scrollAxis = ScrollAxis.undecided
    private var railProbe = CGPoint.zero
    private var multiFired = false
    private var fourSpreadStart: CGFloat = 0
    private var edgeFired = false
    private enum Expose { case none, missionControl, appExpose }
    private var expose = Expose.none
    private var lastDrag = CGPoint.zero
    private var scrollAccum = CGPoint.zero
    private var pressedKeys: [Int: UInt32] = [:]
    private var repeatTimer: Timer?
    private var repeatCode: Int?

    // Momentum (scroll + viewport pan)
    private var scrollVelocity = CGPoint.zero
    private var panVelocity = CGPoint.zero
    private var lastTick: CFTimeInterval = 0

    // Connection lifecycle
    private var everConnected = false
    private var retryCount = 0
    private var closing = false
    private var statsTimer: Timer?
    private var lastStatFrames = 0
    private var lastStatBytes = 0

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let dragHaptic = UIImpactFeedbackGenerator(style: .medium)

    // Settings
    private var defaults: UserDefaults { .standard }
    private var pointerSpeed: CGFloat { CGFloat(defaults.object(forKey: "pointerSpeed") as? Double ?? 1.0) }
    private var scrollSpeed: CGFloat { CGFloat(defaults.object(forKey: "scrollSpeed") as? Double ?? 1.0) }
    private var invertScroll: Bool { defaults.bool(forKey: "invertScroll") }
    private var hapticsOn: Bool { defaults.object(forKey: "haptics") as? Bool ?? true }
    private var syncClipboard: Bool { defaults.object(forKey: "syncClipboard") as? Bool ?? true }
    private var autoKeyboard: Bool { defaults.object(forKey: "autoKeyboard") as? Bool ?? true }

    init(host: SavedHost, password: String) {
        self.host = host
        self.password = password
        self.model = SessionModel(hostName: host.name)
        super.init(nibName: nil, bundle: nil)
        model.controller = self
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        connection?.stop()
    }

    // MARK: View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        mtkView = MTKView(frame: view.bounds)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false   // driven by markActive()/frameTick()
        mtkView.preferredFramesPerSecond = 120
        mtkView.isMultipleTouchEnabled = true
        view.addSubview(mtkView)
        renderer = ScreenRenderer(view: mtkView)
        renderer?.setCursor(ScreenRenderer.defaultCursor())
        renderer?.onDraw = { [weak self] in self?.frameTick() }

        keyInput.frame = CGRect(x: -10, y: -10, width: 1, height: 1)
        keyInput.inputAccessoryView = modifierBar
        view.addSubview(keyInput)
        wireKeyboard()

        // Status / tips layer: full screen, but only touchable while it shows a card.
        overlayHost = UIHostingController(rootView: SessionOverlay(model: model))
        overlayHost.view.backgroundColor = .clear
        addChild(overlayHost)
        overlayHost.view.frame = view.bounds
        overlayHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlayHost.view)
        overlayHost.didMove(toParent: self)
        model.$state.combineLatest(model.$showHint)
            .sink { [weak self] state, hint in
                self?.overlayHost.view.isUserInteractionEnabled = state != .connected || hint
            }
            .store(in: &cancellables)

        // Toolbar: hosted in a view that hugs its buttons, so taps elsewhere reach the screen.
        toolbarHost = UIHostingController(rootView: SessionToolbar(model: model))
        toolbarHost.sizingOptions = [.intrinsicContentSize]
        toolbarHost.view.backgroundColor = .clear
        toolbarHost.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(toolbarHost)
        view.addSubview(toolbarHost.view)
        NSLayoutConstraint.activate([
            toolbarHost.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbarHost.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        toolbarHost.didMove(toParent: self)

        setupGestures()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        connect()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        becomeFirstResponder()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStats() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        statsTimer?.invalidate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.size != lastLayoutSize {
            lastLayoutSize = view.bounds.size
            if !userZoomed { scale = fitScale }
            scale = min(max(scale, fitScale), maxScale)
            clampOffset()
            refreshView()
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var canBecomeFirstResponder: Bool { true }
    // Turn off iOS's three-finger undo/redo/copy gestures; those fingers belong to the Mac.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    // MARK: Connection

    func connect() {
        connection?.delegate = nil
        connection?.stop()
        closing = false
        model.state = everConnected ? .reconnecting(max(1, retryCount)) : .connecting
        let cfg = ConnectionConfig(host: host.address.trimmingCharacters(in: .whitespaces), homeHost: host.home, port: host.port,
                                   username: host.username, password: password, quality: host.quality)
        let c = RFBConnection(config: cfg)
        c.delegate = self
        connection = c
        lastStatBytes = 0
        lastStatFrames = 0
        model.loadingStatus = nil
        c.start()
    }

    /// Retry with new credentials from the sign-in card, saving them for next time.
    func signIn(username: String, password newPassword: String) {
        host.username = username.trimmingCharacters(in: .whitespaces)
        password = newPassword
        if HostStore.shared.hosts.contains(where: { $0.id == host.id }) {
            HostStore.shared.upsert(host, password: newPassword)
        }
        retryCount = 0
        connect()
    }

    func disconnect() {
        closing = true
        stopMomentum()
        connection?.delegate = nil
        connection?.stop()
        connection = nil
        keyInput.resignFirstResponder()
        dismiss(animated: true)
    }

    @objc private func didEnterBackground() {
        guard !closing, connection != nil else { return }
        connection?.delegate = nil
        connection?.stop()
        connection = nil
        if model.state == .connected { model.state = .paused }
    }

    @objc private func didBecomeActive() {
        guard !closing else { return }
        if connection == nil, case .paused = model.state { connect() }
    }

    func rfbDidConnect(_ c: RFBConnection, name: String, framebuffer: Framebuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self, c === self.connection else { return }
            let firstTime = !self.everConnected
            self.everConnected = true
            self.retryCount = 0
            self.model.desktopName = name
            self.model.isPC = !c.serverIsApple
            self.model.state = .connected
            self.applySize(CGSize(width: framebuffer.width, height: framebuffer.height), resetCursor: firstTime)
            HostStore.shared.markConnected(self.host.id)
            if firstTime && !UserDefaults.standard.bool(forKey: "seenHint") {
                self.model.showHint = true
            }
        }
    }

    func rfbDidResize(_ c: RFBConnection, framebuffer: Framebuffer) {
        DispatchQueue.main.async { [weak self] in
            self?.applySize(CGSize(width: framebuffer.width, height: framebuffer.height), resetCursor: false)
        }
    }

    func rfb(_ c: RFBConnection, didUpdate framebuffer: Framebuffer, dirty: [CGRect]) {
        renderer?.upload(framebuffer, dirty: dirty)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.markActive()
            // Only once the whole picture is in; earlier, the edge of the loaded part looks like a seam.
            if self.needsDisplayDetection && c.hasFullPicture {
                self.needsDisplayDetection = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.detectDisplays(retry: true) }
            }
        }
    }

    func rfb(_ c: RFBConnection, screens: [CGRect]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.serverScreens = screens
            if screens.count > 1 { self.detectDisplays(retry: false) }
        }
    }

    func rfb(_ c: RFBConnection, cursorChanged cursor: CursorImage?) {
        renderer?.setCursor(cursor)
        let isText = cursor?.isTextCursor ?? false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasServerCursor = true
            self.cursorHidden = cursor == nil
            self.textCursor = isText
            if var k = self.keyboardCheck {
                k.sawUpdate = true
                self.keyboardCheck = k
                if isText && self.cursorPos == k.pos {
                    self.keyboardCheck = nil
                    self.showKeyboard()
                }
            }
            self.refreshView()
        }
    }

    func rfb(_ c: RFBConnection, clipboard text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.syncClipboard else { return }
            UIPasteboard.general.string = text
        }
    }

    func rfb(_ c: RFBConnection, didFail error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, c === self.connection, !self.closing else { return }
            self.connection = nil
            let isAuth = error is AuthError
            if self.everConnected && !isAuth && self.retryCount < 6 && UIApplication.shared.applicationState == .active {
                self.retryCount += 1
                self.model.state = .reconnecting(self.retryCount)
                let delay = min(4.0, 0.5 * Double(self.retryCount))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.closing, self.connection == nil else { return }
                    self.connect()
                }
            } else if isAuth {
                // Usually a changed Mac password: ask for it right here instead of a dead end.
                self.model.signInUser = self.host.username
                self.model.state = .signIn(error?.localizedDescription ?? "Sign-in failed.")
            } else {
                self.model.state = .failed(error?.localizedDescription ?? "Disconnected.")
            }
        }
    }

    private func applySize(_ size: CGSize, resetCursor: Bool) {
        if size != fbSize {
            model.displays = []
            serverScreens = []
        }
        fbSize = size
        needsDisplayDetection = true
        userZoomed = false
        scale = fitScale
        if resetCursor || cursorPos.x > size.width || cursorPos.y > size.height {
            cursorPos = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        clampOffset()
        refreshView()
    }

    private func updateStats() {
        guard let c = connection, model.state == .connected else { return }
        c.checkHealth()
        let frames = c.framesReceived, bytes = c.bytesReceived
        let fps = frames - lastStatFrames
        let kbps = Double(bytes - lastStatBytes) / 1024
        lastStatFrames = frames
        lastStatBytes = bytes
        let rate = kbps > 1024 ? String(format: "%.1f MB/s", kbps / 1024) : String(format: "%.0f KB/s", kbps)
        model.stats = "\(Int(fbSize.width))×\(Int(fbSize.height)) · \(fps) fps · \(rate) · \(Int(c.lastRoundTrip * 1000)) ms"
        if c.hasFullPicture {
            model.loadingStatus = nil
        } else {
            let mb = Double(c.bytesSinceConnect) / 1_048_576
            model.loadingStatus = String(format: "Loading screen… %.1f MB · %@", mb, rate)
            ConnLog.write("waiting for picture: \(c.bytesSinceConnect / 1024) KB so far, \(Int(kbps)) KB/s")
        }
    }

    // MARK: Viewport math

    private var visibleSize: CGSize {
        CGSize(width: view.bounds.width, height: max(100, view.bounds.height - keyboardHeight))
    }

    /// The part of the desktop being shown: one display, or all of them.
    private var region: CGRect {
        if let i = model.selectedDisplay, model.displays.indices.contains(i) { return model.displays[i] }
        return fullRect
    }

    private var fullRect: CGRect { CGRect(origin: .zero, size: fbSize) }

    private var fitScale: CGFloat { fitScale(for: region) }

    private func fitScale(for r: CGRect) -> CGFloat {
        guard r.width > 0, r.height > 0 else { return 1 }
        let v = visibleSize
        return min(v.width / r.width, v.height / r.height)
    }

    private func clampToRegion(_ p: CGPoint) -> CGPoint {
        let r = region
        return CGPoint(x: min(max(r.minX, p.x), r.maxX - 1), y: min(max(r.minY, p.y), r.maxY - 1))
    }

    private var maxScale: CGFloat { max(fitScale * 2, 3.0) }

    private func clampOffset() {
        guard fbSize.width > 0, viewportAnimation == nil else { return }
        offset = clampedOffset(offset, scale: scale, in: region)
    }

    private func clampedOffset(_ o: CGPoint, scale s: CGFloat, in r: CGRect) -> CGPoint {
        let v = visibleSize
        let vw = v.width / s, vh = v.height / s
        return CGPoint(x: r.width <= vw ? r.minX + (r.width - vw) / 2 : min(max(r.minX, o.x), r.maxX - vw),
                       y: r.height <= vh ? r.minY + (r.height - vh) / 2 : min(max(r.minY, o.y), r.maxY - vh))
    }

    private func viewPoint(_ remote: CGPoint) -> CGPoint {
        CGPoint(x: (remote.x - offset.x) * scale, y: (remote.y - offset.y) * scale)
    }

    private func remotePoint(_ p: CGPoint) -> CGPoint {
        clampToRegion(CGPoint(x: p.x / scale + offset.x, y: p.y / scale + offset.y))
    }

    /// Keep the pointer on screen when zoomed in (the view glides along with it).
    private func followCursor() {
        let v = visibleSize
        let vw = v.width / scale, vh = v.height / scale
        let mx = vw * 0.12, my = vh * 0.12
        let r = region
        if r.width > vw {
            if cursorPos.x < offset.x + mx { offset.x = cursorPos.x - mx }
            if cursorPos.x > offset.x + vw - mx { offset.x = cursorPos.x - vw + mx }
        }
        if r.height > vh {
            if cursorPos.y < offset.y + my { offset.y = cursorPos.y - my }
            if cursorPos.y > offset.y + vh - my { offset.y = cursorPos.y - vh + my }
        }
        clampOffset()
    }

    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        let anchorRemote = CGPoint(x: anchor.x / scale + offset.x, y: anchor.y / scale + offset.y)
        let newScale = min(max(scale * factor, fitScale * 0.9), maxScale)
        scale = newScale
        offset = CGPoint(x: anchorRemote.x - anchor.x / scale, y: anchorRemote.y - anchor.y / scale)
        clampOffset()
    }

    func zoomToFit() {
        userZoomed = false
        let s = fitScale
        animateViewport(toScale: s, offset: clampedOffset(offset, scale: s, in: region))
    }

    // MARK: Viewport animation & render loop

    private struct ViewportAnimation {
        var fromScale: CGFloat, toScale: CGFloat
        var fromCenter: CGPoint, toCenter: CGPoint
        var toOffset: CGPoint
        var start: CFTimeInterval, duration: CFTimeInterval
    }
    private var viewportAnimation: ViewportAnimation?
    private var lastActivity: CFTimeInterval = 0

    /// Glide the camera to a new scale/offset (in remote pixels).
    private func animateViewport(toScale s: CGFloat, offset o: CGPoint, duration: CFTimeInterval = 0.34) {
        let v = visibleSize
        guard v.width > 0, scale > 0, s > 0 else { scale = s; offset = o; refreshView(); return }
        let from = CGPoint(x: offset.x + v.width / (2 * scale), y: offset.y + v.height / (2 * scale))
        let to = CGPoint(x: o.x + v.width / (2 * s), y: o.y + v.height / (2 * s))
        viewportAnimation = ViewportAnimation(fromScale: scale, toScale: s, fromCenter: from, toCenter: to,
                                              toOffset: o, start: CACurrentMediaTime(), duration: duration)
        markActive()
    }

    private func stepViewportAnimation(_ now: CFTimeInterval) {
        guard let a = viewportAnimation else { return }
        let t = min(1, (now - a.start) / a.duration)
        let e = 1 - pow(1 - t, 3)   // ease-out cubic
        if t >= 1 {
            viewportAnimation = nil
            scale = a.toScale
            offset = a.toOffset
        } else {
            // Interpolate zoom logarithmically so it feels even, and move the centre in a straight line.
            let s = exp(log(a.fromScale) + (log(a.toScale) - log(a.fromScale)) * e)
            let c = CGPoint(x: a.fromCenter.x + (a.toCenter.x - a.fromCenter.x) * e,
                            y: a.fromCenter.y + (a.toCenter.y - a.fromCenter.y) * e)
            let v = visibleSize
            scale = s
            offset = CGPoint(x: c.x - v.width / (2 * s), y: c.y - v.height / (2 * s))
        }
        refreshView()
    }

    /// Run the Metal view at full refresh rate while anything is moving; idle otherwise.
    private func markActive() {
        lastActivity = CACurrentMediaTime()
        if mtkView.isPaused { mtkView.isPaused = false }
    }

    /// Called by the renderer at the start of every frame (main thread, vsync-aligned).
    private func frameTick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0, now - lastTick))
        lastTick = now
        stepViewportAnimation(now)
        stepMomentum(dt)
        if viewportAnimation == nil && !momentumActive && now - lastActivity > 0.5 {
            mtkView.isPaused = true
        }
    }

    private func refreshView() {
        guard let renderer else { return }
        // While the camera is gliding, show the whole desktop; crop to the display once it lands.
        let r = viewportAnimation == nil ? region : fullRect
        renderer.contentRect = CGRect(x: (r.minX - offset.x) * scale, y: (r.minY - offset.y) * scale,
                                      width: r.width * scale, height: r.height * scale)
        if fbSize.width > 0 && fbSize.height > 0 {
            renderer.textureRect = CGRect(x: r.minX / fbSize.width, y: r.minY / fbSize.height,
                                          width: r.width / fbSize.width, height: r.height / fbSize.height)
        }
        // Crisp pixels once each remote pixel covers 3+ device pixels.
        renderer.useNearestFiltering = scale * (view.window?.screen.scale ?? 3) >= 3
        let showLocalCursor = model.inputMode == .trackpad || hasServerCursor
        renderer.cursorPoint = (fbSize.width > 0 && !cursorHidden && showLocalCursor) ? viewPoint(cursorPos) : nil
        renderer.cursorScale = max(scale, 0.55)
        // Downscaled copies are only needed when the picture is shown smaller than 1:1.
        renderer.mipmapsWanted = scale * (view.window?.screen.scale ?? 3) < 1.0
        markActive()
    }

    // MARK: Pointer output

    private func sendMove() {
        guard let c = connection else { return }
        let x = Int(cursorPos.x.rounded()), y = Int(cursorPos.y.rounded())
        inputQueue.async { c.sendPointer(x: x, y: y) }
    }

    private func click(button: UInt8, count: Int = 1) {
        guard let c = connection else { return }
        expose = .none
        let x = Int(cursorPos.x.rounded()), y = Int(cursorPos.y.rounded())
        inputQueue.async {
            c.sendPointer(x: x, y: y)
            for _ in 0..<count {
                c.setButton(button, down: true, x: x, y: y)
                c.setButton(button, down: false, x: x, y: y)
            }
        }
        if hapticsOn { haptic.impactOccurred(intensity: button == 1 ? 0.5 : 0.8) }
    }

    private func setButton(_ button: UInt8, down: Bool) {
        guard let c = connection else { return }
        let x = Int(cursorPos.x.rounded()), y = Int(cursorPos.y.rounded())
        inputQueue.async { c.setButton(button, down: down, x: x, y: y) }
    }

    private func sendScroll(dx: Int, dy: Int) {
        guard let c = connection, dx != 0 || dy != 0 else { return }
        let x = Int(cursorPos.x.rounded()), y = Int(cursorPos.y.rounded())
        inputQueue.async { c.scroll(dx: dx, dy: dy, x: x, y: y) }
    }

    // MARK: Gestures

    private func setupGestures() {
        let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self

        let threeFingerSwipe = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipe(_:)))
        threeFingerSwipe.minimumNumberOfTouches = 3
        threeFingerSwipe.maximumNumberOfTouches = 3

        let fourFinger = UIPanGestureRecognizer(target: self, action: #selector(handleFourFinger(_:)))
        fourFinger.minimumNumberOfTouches = 4
        fourFinger.maximumNumberOfTouches = 5

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        let fourFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleFourFingerTap(_:)))
        fourFingerTap.numberOfTouchesRequired = 4

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        longPress.allowableMovement = 12

        // Swipe in from the right edge → Notification Center (like the Mac's two-finger edge swipe).
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
        edge.edges = .right
        oneFingerPan.require(toFail: edge)

        // Scroll wheel / trackpad on iPad or with a pointer device.
        let pointerScroll = UIPanGestureRecognizer(target: self, action: #selector(handlePointerScroll(_:)))
        pointerScroll.allowedScrollTypesMask = .all
        pointerScroll.allowedTouchTypes = []
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))

        for g in [oneFingerPan, twoFingerPan, threeFingerSwipe, fourFinger, pinch, tap, twoFingerTap,
                  threeFingerTap, fourFingerTap, longPress, edge, pointerScroll, hover] as [UIGestureRecognizer] {
            mtkView.addGestureRecognizer(g)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair: (UIGestureRecognizer) -> Bool = { $0 is UIPinchGestureRecognizer || ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }
        return pair(g) && pair(other)
    }

    private var isTrackpad: Bool { model.inputMode == .trackpad }

    private func dismissHint() {
        if model.showHint {
            model.showHint = false
            UserDefaults.standard.set(true, forKey: "seenHint")
        }
    }

    // One finger: pointer (trackpad) or pan (touch)

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard fbSize.width > 0 else { return }
        let t = g.translation(in: mtkView)
        switch g.state {
        case .began:
            stopMomentum()
            lastPan = t
            smoothedSpeed = 0
            dismissHint()
        case .changed:
            let d = CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y)
            lastPan = t
            if isTrackpad {
                // Smoothed velocity → acceleration curve (like macOS): precise when slow,
                // covers the whole screen with a quick flick.
                let v = g.velocity(in: mtkView)
                smoothedSpeed = smoothedSpeed * 0.55 + hypot(v.x, v.y) * 0.45
                let x = min(1, max(0, (smoothedSpeed - 100) / 1500))
                let accel = 0.65 + 1.5 * (x * x * (3 - 2 * x))
                let gain = pointerSpeed * accel / scale
                cursorPos = clampToRegion(CGPoint(x: cursorPos.x + d.x * gain, y: cursorPos.y + d.y * gain))
                followCursor()
                sendMove()
            } else {
                offset.x -= d.x / scale
                offset.y -= d.y / scale
                clampOffset()
            }
            refreshView()
        case .ended, .cancelled:
            if !isTrackpad {
                panVelocity = g.velocity(in: mtkView)
                startMomentum()
            }
        default: break
        }
    }

    // Two fingers: scroll, or pinch to zoom

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: mtkView)
        switch g.state {
        case .began:
            stopMomentum()
            dismissHint()
            lastTwoPan = t
            scrollAccum = .zero
            scrollAxis = .undecided
            railProbe = .zero
            if !isPinchActive { twoFingerMode = .undecided; pinchCumulative = 1 }
            if !isTrackpad {
                cursorPos = remotePoint(g.location(in: mtkView))
                sendMove()
                refreshView()
            }
        case .changed:
            let d = CGPoint(x: t.x - lastTwoPan.x, y: t.y - lastTwoPan.y)
            lastTwoPan = t
            let moved = hypot(t.x, t.y)
            if twoFingerMode == .undecided && moved > 6 && moved > abs(pinchSpanDelta) * 1.4 {
                twoFingerMode = .scroll
                applyScroll(CGPoint(x: t.x - d.x, y: t.y - d.y))   // catch up on motion made while deciding
            }
            switch twoFingerMode {
            case .scroll:
                applyScroll(d)
            case .zoom:
                offset.x -= d.x / scale
                offset.y -= d.y / scale
                clampOffset()
                refreshView()
            case .undecided:
                break
            }
        case .ended, .cancelled:
            if twoFingerMode == .scroll {
                scrollVelocity = g.velocity(in: mtkView)
                startMomentum()
            }
            if !isPinchActive { twoFingerMode = .undecided }
        default: break
        }
    }

    private var pinchRecognizer: UIPinchGestureRecognizer? {
        mtkView.gestureRecognizers?.first { $0 is UIPinchGestureRecognizer } as? UIPinchGestureRecognizer
    }

    private var isTwoFingerPanActive: Bool {
        mtkView.gestureRecognizers?.contains {
            ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 && ($0.state == .began || $0.state == .changed)
        } ?? false
    }

    private var isPinchActive: Bool {
        guard let p = pinchRecognizer else { return false }
        return p.state == .began || p.state == .changed
    }

    /// How far (in points) the fingers have spread apart or together during this pinch.
    private var pinchSpanDelta: CGFloat { pinchSpanStart * (pinchCumulative - 1) }

    private func applyScroll(_ raw: CGPoint) {
        var d = raw
        // Lock to one axis at the start of a scroll, like a Mac trackpad.
        if scrollAxis == .undecided {
            railProbe.x += d.x
            railProbe.y += d.y
            if hypot(railProbe.x, railProbe.y) > 5 {
                if abs(railProbe.y) > abs(railProbe.x) * 2 { scrollAxis = .vertical }
                else if abs(railProbe.x) > abs(railProbe.y) * 2 { scrollAxis = .horizontal }
                else { scrollAxis = .free }
            }
        }
        if scrollAxis == .vertical { d.x = 0 }
        if scrollAxis == .horizontal { d.y = 0 }

        // Points of finger travel per wheel notch. Small steps = fine-grained, responsive scrolling;
        // macOS adds its own wheel acceleration on top, just like a real mouse.
        let step = 3.0 / scrollSpeed
        // Send the wheel in the same direction the fingers move. macOS then applies the
        // Mac's own "Natural scrolling" setting, exactly as it does for the real trackpad.
        let sign: CGFloat = invertScroll ? -1 : 1
        scrollAccum.x += d.x * sign
        scrollAccum.y += d.y * sign
        let nx = Int(scrollAccum.x / step), ny = Int(scrollAccum.y / step)
        scrollAccum.x -= CGFloat(nx) * step
        scrollAccum.y -= CGFloat(ny) * step
        sendScroll(dx: nx, dy: ny)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if g.numberOfTouches > 2 { return }   // 4–5 finger pinches are Mac gestures
        switch g.state {
        case .began:
            stopMomentum()
            dismissHint()
            viewportAnimation = nil
            if !isTwoFingerPanActive { twoFingerMode = .undecided; lastTwoPan = .zero }
            pinchCumulative = 1
            if g.numberOfTouches >= 2 {
                let a = g.location(ofTouch: 0, in: mtkView), b = g.location(ofTouch: 1, in: mtkView)
                pinchSpanStart = max(20, hypot(a.x - b.x, a.y - b.y))
            }
        case .changed:
            pinchCumulative *= g.scale
            if twoFingerMode == .undecided && abs(pinchSpanDelta) > 18 && abs(pinchSpanDelta) > hypot(lastTwoPan.x, lastTwoPan.y) {
                twoFingerMode = .zoom
            }
            if twoFingerMode == .zoom {
                zoom(by: g.scale, at: g.location(in: mtkView))
                userZoomed = true
                refreshView()
            }
            g.scale = 1
        case .ended, .cancelled:
            if twoFingerMode == .zoom {
                if scale < fitScale * 1.04 { zoomToFit() }
                userZoomed = scale > fitScale * 1.01
            }
            if !isTwoFingerPanActive { twoFingerMode = .undecided }
        default: break
        }
    }

    // Three fingers: Mission Control, App Exposé, Spaces, Look Up

    private enum MacSwipe { case up, down, left, right }

    @objc private func handleThreeFingerSwipe(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: mtkView)
        switch g.state {
        case .began:
            multiFired = false
            dismissHint()
        case .changed:
            guard !multiFired else { return }
            if let dir = swipeDirection(t, threshold: 45) {
                multiFired = true
                macSwipe(dir)
            }
        default: break
        }
    }

    private func swipeDirection(_ t: CGPoint, threshold: CGFloat) -> MacSwipe? {
        if abs(t.x) > threshold && abs(t.x) > abs(t.y) * 1.3 { return t.x < 0 ? .left : .right }
        if abs(t.y) > threshold && abs(t.y) > abs(t.x) * 1.3 { return t.y < 0 ? .up : .down }
        return nil
    }

    /// Same results as the Mac's three-finger swipes (default System Settings).
    private func macSwipe(_ dir: MacSwipe) {
        switch dir {
        case .up:
            if expose == .appExpose { sendShortcut(Keysym.down, modifiers: [Keysym.control]); expose = .none; model.flash(model.isPC ? "Close Task View" : "Close App Exposé") }
            else if expose == .none { sendShortcut(Keysym.up, modifiers: [Keysym.control]); expose = .missionControl; model.flash(model.isPC ? "Task View" : "Mission Control") }
        case .down:
            if expose == .missionControl { sendShortcut(Keysym.up, modifiers: [Keysym.control]); expose = .none; model.flash(model.isPC ? "Close Task View" : "Close Mission Control") }
            else if expose == .none { sendShortcut(Keysym.down, modifiers: [Keysym.control]); expose = .appExpose; model.flash(model.isPC ? "Task View" : "App Exposé") }
        case .left:
            sendShortcut(Keysym.right, modifiers: [Keysym.control])
            model.flash(model.isPC ? "Next Desktop  →" : "Next Space  →")
        case .right:
            sendShortcut(Keysym.left, modifiers: [Keysym.control])
            model.flash(model.isPC ? "←  Previous Desktop" : "←  Previous Space")
        }
    }

    @objc private func handleThreeFingerTap(_ g: UITapGestureRecognizer) {
        guard fbSize.width > 0 else { return }
        dismissHint()
        // Look Up & data detectors acts on the word under the pointer.
        if !isTrackpad {
            cursorPos = remotePoint(g.location(in: mtkView))
            sendMove()
            refreshView()
        }
        if model.isPC {   // Windows has no Look Up; a right-click shows the word's options
            let p = (x: Int(cursorPos.x.rounded()), y: Int(cursorPos.y.rounded()))
            if let c = connection {
                inputQueue.async {
                    c.setButton(4, down: true, x: p.x, y: p.y)
                    c.setButton(4, down: false, x: p.x, y: p.y)
                }
            }
            model.flash("Right-Click")
            return
        }
        sendShortcut(UInt32(0x64), modifiers: [Keysym.control, Keysym.command])
        model.flash("Look Up")
    }

    // Four fingers: displays, Show Desktop, Apps, keyboard

    @objc private func handleFourFinger(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: mtkView)
        switch g.state {
        case .began:
            multiFired = false
            fourSpreadStart = touchSpread(g)
            dismissHint()
        case .changed:
            guard !multiFired, g.numberOfTouches >= 4, fourSpreadStart > 0 else { return }
            let ratio = touchSpread(g) / fourSpreadStart
            if ratio > 1.35 {
                multiFired = true
                if model.isPC { sendShortcut(UInt32(0x64), modifiers: [Keysym.superL]) }   // Win+D
                else { sendShortcut(Keysym.function(11), modifiers: []) }                // Show Desktop
                model.flash("Show Desktop")
            } else if ratio < 0.72 {
                multiFired = true
                showApps()
            } else if let dir = swipeDirection(t, threshold: 55) {
                multiFired = true
                if (dir == .left || dir == .right) && model.displays.count > 1 {
                    let n = model.displays.count
                    let cur = model.selectedDisplay ?? (dir == .left ? -1 : n)
                    let next = dir == .left ? min(n - 1, cur + 1) : max(0, cur - 1)
                    if next != model.selectedDisplay { selectDisplay(next) }
                } else {
                    macSwipe(dir)
                }
            }
        default: break
        }
    }

    private func touchSpread(_ g: UIGestureRecognizer) -> CGFloat {
        let n = g.numberOfTouches
        guard n >= 2 else { return 0 }
        let c = g.location(in: mtkView)
        var total: CGFloat = 0
        for i in 0..<n {
            let p = g.location(ofTouch: i, in: mtkView)
            total += hypot(p.x - c.x, p.y - c.y)
        }
        return total / CGFloat(n)
    }

    /// The Mac's thumb-and-three-finger pinch opens Apps (formerly Launchpad).
    private func showApps() {
        guard let c = connection else { return }
        if model.isPC {
            sendShortcut(Keysym.superL, modifiers: [])
            model.flash("Start")
            return
        }
        inputQueue.async {
            c.tapKey(Keysym.space, modifiers: [Keysym.command])
            Thread.sleep(forTimeInterval: 0.25)
            c.tapKey(UInt32(0x31), modifiers: [Keysym.command])
        }
        if hapticsOn { haptic.impactOccurred() }
        model.flash("Apps")
    }

    @objc private func handleFourFingerTap(_ g: UITapGestureRecognizer) {
        toggleKeyboard()
    }

    // Edge swipe: Notification Center

    @objc private func handleEdgeSwipe(_ g: UIScreenEdgePanGestureRecognizer) {
        switch g.state {
        case .began:
            edgeFired = false
        case .changed:
            guard !edgeFired, g.translation(in: mtkView).x < -50, fbSize.width > 0, let c = connection else { return }
            edgeFired = true
            if model.isPC {   // Windows: notification center is Win+N
                sendShortcut(UInt32(0x6E), modifiers: [Keysym.superL])
                model.flash("Notifications")
                return
            }
            // macOS has no default shortcut for Notification Center, so click the menu-bar clock.
            let r = model.selectedDisplay.flatMap { model.displays.indices.contains($0) ? model.displays[$0] : nil }
                ?? model.displays.first ?? fullRect
            let x = Int(r.maxX) - 40, y = Int(r.minY) + 10
            let backX = Int(cursorPos.x.rounded()), backY = Int(cursorPos.y.rounded())
            inputQueue.async {
                c.sendPointer(x: x, y: y)
                c.setButton(1, down: true, x: x, y: y)
                c.setButton(1, down: false, x: x, y: y)
                c.sendPointer(x: backX, y: backY)
            }
            if hapticsOn { haptic.impactOccurred() }
            model.flash("Notification Center")
        default: break
        }
    }

    // Taps & drag

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard fbSize.width > 0 else { return }
        stopMomentum()
        dismissHint()
        let before = cursorPos
        if !isTrackpad {
            cursorPos = remotePoint(g.location(in: mtkView))
            refreshView()
        }
        click(button: 1)
        keyboardAfterClick(warped: hypot(cursorPos.x - before.x, cursorPos.y - before.y) > 2)
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard fbSize.width > 0 else { return }
        if !isTrackpad {
            cursorPos = remotePoint(g.location(in: mtkView))
            refreshView()
        }
        click(button: 4)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard fbSize.width > 0 else { return }
        let loc = g.location(in: mtkView)
        switch g.state {
        case .began:
            stopMomentum()
            dismissHint()
            expose = .none
            if !isTrackpad { cursorPos = remotePoint(loc) }
            lastDrag = loc
            sendMove()
            setButton(1, down: true)
            if hapticsOn { dragHaptic.impactOccurred() }
            refreshView()
        case .changed:
            if isTrackpad {
                let gain = pointerSpeed * 1.2 / scale
                cursorPos = clampToRegion(CGPoint(x: cursorPos.x + (loc.x - lastDrag.x) * gain,
                                                  y: cursorPos.y + (loc.y - lastDrag.y) * gain))
                followCursor()
            } else {
                cursorPos = remotePoint(loc)
                // Nudge the view when dragging near an edge while zoomed in.
                let edge: CGFloat = 40
                var nudge = CGPoint.zero
                if loc.x < edge { nudge.x = -8 } else if loc.x > visibleSize.width - edge { nudge.x = 8 }
                if loc.y < edge { nudge.y = -8 } else if loc.y > visibleSize.height - edge { nudge.y = 8 }
                if nudge != .zero {
                    offset.x += nudge.x / scale
                    offset.y += nudge.y / scale
                    clampOffset()
                }
            }
            lastDrag = loc
            sendMove()
            refreshView()
        case .ended, .cancelled, .failed:
            setButton(1, down: false)
        default: break
        }
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        guard fbSize.width > 0, g.state == .changed || g.state == .began else { return }
        cursorPos = remotePoint(g.location(in: mtkView))
        sendMove()
        refreshView()
    }

    @objc private func handlePointerScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: mtkView)
        switch g.state {
        case .began: lastTwoPan = t; scrollAccum = .zero; scrollAxis = .undecided; railProbe = .zero
        case .changed:
            applyScroll(CGPoint(x: t.x - lastTwoPan.x, y: t.y - lastTwoPan.y))
            lastTwoPan = t
        default: break
        }
    }

    // MARK: Momentum (driven by the render loop)

    private var momentumActive: Bool { scrollVelocity != .zero || panVelocity != .zero }

    private func startMomentum() {
        if hypot(scrollVelocity.x, scrollVelocity.y) < 60 { scrollVelocity = .zero }
        if hypot(panVelocity.x, panVelocity.y) < 60 { panVelocity = .zero }
        guard momentumActive else { return }
        lastTick = CACurrentMediaTime()
        markActive()
    }

    private func stopMomentum() {
        scrollVelocity = .zero
        panVelocity = .zero
    }

    private func stepMomentum(_ dt: CFTimeInterval) {
        guard momentumActive, dt > 0 else { return }
        let decay = pow(0.06, dt)   // roughly macOS's inertial scrolling falloff
        if scrollVelocity != .zero {
            applyScroll(CGPoint(x: scrollVelocity.x * dt, y: scrollVelocity.y * dt))
            scrollVelocity.x *= decay
            scrollVelocity.y *= decay
            if hypot(scrollVelocity.x, scrollVelocity.y) < 35 { scrollVelocity = .zero }
        }
        if panVelocity != .zero {
            offset.x -= panVelocity.x * dt / scale
            offset.y -= panVelocity.y * dt / scale
            clampOffset()
            panVelocity.x *= decay
            panVelocity.y *= decay
            if hypot(panVelocity.x, panVelocity.y) < 30 { panVelocity = .zero }
            refreshView()
        }
        markActive()
    }

    // MARK: Keyboard

    private func wireKeyboard() {
        keyInput.onText = { [weak self] text in self?.typeText(text) }
        keyInput.onBackspace = { [weak self] in self?.sendKey(Keysym.backspace) }
        keyInput.onPresses = { [weak self] presses, down in self?.handlePresses(presses, down: down) ?? false }
        modifierBar.onKey = { [weak self] sym in self?.sendKey(sym) }
        modifierBar.onDismiss = { [weak self] in self?.toggleKeyboard() }
    }

    /// Bring up the keyboard when a click lands in a text field. VNC doesn't say what has
    /// focus, but macOS switches the pointer to the I-beam over editable text and sends us
    /// that cursor shape, so use it as the signal.
    private func keyboardAfterClick(warped: Bool) {
        guard autoKeyboard, hasServerCursor, !keyInput.isFirstResponder else { return }
        if textCursor && !warped {
            showKeyboard()
            return
        }
        // The pointer just jumped (touch mode) or the Mac hasn't sent the new shape yet:
        // wait briefly for a cursor update at this spot.
        let id = CACurrentMediaTime()
        keyboardCheck = (id, cursorPos, false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let k = self.keyboardCheck, k.id == id else { return }
            self.keyboardCheck = nil
            // No update means the shape didn't change: it was already the I-beam.
            if !k.sawUpdate && self.textCursor && self.cursorPos == k.pos { self.showKeyboard() }
        }
    }

    private func showKeyboard() {
        guard !keyInput.isFirstResponder else { return }
        dismissHint()
        keyInput.becomeFirstResponder()
    }

    func toggleKeyboard() {
        dismissHint()
        if keyInput.isFirstResponder {
            keyInput.resignFirstResponder()
            becomeFirstResponder()
        } else {
            keyInput.becomeFirstResponder()
        }
    }

    private func sendKey(_ sym: UInt32, extraShift: Bool = false) {
        guard let c = connection else { return }
        if sym == Keysym.escape { expose = .none }
        var mods = modifierBar.activeKeysyms
        if extraShift && !mods.contains(Keysym.shift) { mods.append(Keysym.shift) }
        inputQueue.async { c.tapKey(sym, modifiers: mods) }
        modifierBar.consumeModifiers()
    }

    private func typeText(_ text: String) {
        for ch in text {
            guard let (sym, shift) = Keysym.forCharacter(ch) else { continue }
            sendKey(sym, extraShift: shift)
        }
    }

    func sendShortcut(_ key: UInt32, modifiers: [UInt32]) {
        guard let c = connection else { return }
        inputQueue.async { c.tapKey(key, modifiers: modifiers) }
        if hapticsOn { haptic.impactOccurred() }
    }

    private func handlePresses(_ presses: Set<UIPress>, down: Bool) -> Bool {
        guard let c = connection else { return false }
        var handled = false
        for p in presses {
            guard let key = p.key else { continue }
            let code = key.keyCode.rawValue
            let sym: UInt32?
            if down {
                sym = Keysym.forKey(key)
                if let sym { pressedKeys[code] = sym; startKeyRepeat(code: code, sym: sym) }
            } else {
                sym = pressedKeys.removeValue(forKey: code) ?? Keysym.forKey(key)
                if code == repeatCode { stopKeyRepeat() }
            }
            if let sym {
                handled = true
                inputQueue.async { c.key(sym, down: down) }
            }
        }
        return handled
    }

    /// The Mac doesn't auto-repeat keys held on a remote keyboard (a real Mac client sends
    /// the repeats itself), so repeat held hardware keys here: the latest non-modifier key,
    /// after a short delay, like macOS's default key repeat.
    private func startKeyRepeat(code: Int, sym: UInt32) {
        stopKeyRepeat()
        guard !(0xffe1...0xffee).contains(sym) else { return }   // modifiers don't repeat
        repeatCode = code
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
            guard let self, self.repeatCode == code else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.repeatCode == code, self.pressedKeys[code] == sym, let c = self.connection else {
                    self.stopKeyRepeat(); return
                }
                self.inputQueue.async { c.key(sym, down: true) }
            }
        }
    }

    private func stopKeyRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatCode = nil
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    @objc private func keyboardFrameChanged(_ n: Notification) {
        var h: CGFloat = 0
        if n.name != UIResponder.keyboardWillHideNotification,
           let frame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            let local = view.convert(frame, from: nil)
            h = max(0, view.bounds.maxY - local.minY)
        }
        keyboardHeight = h
        model.keyboardVisible = h > 60
        if !userZoomed { scale = fitScale }
        scale = max(scale, fitScale)
        followCursor()
        clampOffset()
        refreshView()
    }

    // MARK: Menu actions

    func toggleInputMode() {
        model.inputMode = model.inputMode == .trackpad ? .touch : .trackpad
        model.flash(model.inputMode == .trackpad ? "Trackpad mode" : "Touch mode")
        if hapticsOn { haptic.impactOccurred() }
        refreshView()
    }

    func pasteToMac() {
        guard let c = connection, let text = UIPasteboard.general.string else {
            model.flash("iPhone clipboard is empty")
            return
        }
        inputQueue.async {
            c.sendClipboard(text)
            Thread.sleep(forTimeInterval: 0.25)
            c.tapKey(0x76, modifiers: [Keysym.command])
        }
        model.flash("Pasted on \(model.computer)")
    }

    func typeClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            model.flash("iPhone clipboard is empty")
            return
        }
        typeText(String(text.prefix(2000)))
    }

    func refreshScreen() {
        connection?.refresh()
    }

    // MARK: Displays

    private var layoutKey: String { "displayLayout.\(host.id.uuidString)" }
    private var selectionKey: String { "displaySelection.\(host.id.uuidString)" }

    func selectDisplay(_ index: Int?) {
        model.selectedDisplay = index
        UserDefaults.standard.set(index ?? -1, forKey: selectionKey)
        stopMomentum()
        userZoomed = false
        let r = region
        connection?.setUpdateRegion(index == nil ? nil : r)
        if !r.contains(cursorPos) {
            cursorPos = CGPoint(x: r.midX, y: r.midY)
            sendMove()
        }
        let s = fitScale(for: r)
        animateViewport(toScale: s, offset: clampedOffset(offset, scale: s, in: r))
        if hapticsOn { haptic.impactOccurred() }
        model.flash(index.map { "Display \($0 + 1)" } ?? "All Displays")
    }

    func setManualLayout(columns: Int, rows: Int) {
        UserDefaults.standard.set([columns, rows], forKey: layoutKey)
        applyDisplays(DisplayDetector.even(CGRect(origin: .zero, size: fbSize), columns: columns, rows: rows), manual: true)
        selectDisplay(model.displays.isEmpty ? nil : 0)
    }

    func redetectDisplays() {
        UserDefaults.standard.removeObject(forKey: layoutKey)
        detectDisplays(retry: false, announce: true)
    }

    private func detectDisplays(retry: Bool, announce: Bool = false) {
        guard fbSize.width > 0 else { return }
        if let saved = UserDefaults.standard.array(forKey: layoutKey) as? [Int], saved.count == 2 {
            applyDisplays(DisplayDetector.even(CGRect(origin: .zero, size: fbSize), columns: saved[0], rows: saved[1]), manual: true)
            return
        }
        if serverScreens.count > 1 {
            applyDisplays(serverScreens, manual: false)
            return
        }
        guard let fb = connection?.framebuffer else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = DisplayDetector.detect(fb)
            DispatchQueue.main.async {
                guard let self, fb === self.connection?.framebuffer else { return }
                self.applyDisplays(found.count > 1 ? found : [], manual: false)
                if announce {
                    self.model.flash(found.count > 1 ? "Found \(found.count) displays" : "Only one display found")
                }
                // Content may still have been loading; look once more.
                if retry && found.count <= 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.detectDisplays(retry: false) }
                }
            }
        }
    }

    private func applyDisplays(_ rects: [CGRect], manual: Bool) {
        model.displays = rects
        model.displayLayoutIsManual = manual
        if let i = model.selectedDisplay, !rects.indices.contains(i) { model.selectedDisplay = nil }
        if !restoredDisplaySelection, rects.count > 1 {
            restoredDisplaySelection = true
            let saved = UserDefaults.standard.object(forKey: selectionKey) as? Int ?? -1
            if rects.indices.contains(saved) {
                selectDisplay(saved)
                return
            }
        }
        if !userZoomed { scale = fitScale }
        clampOffset()
        refreshView()
    }
}
