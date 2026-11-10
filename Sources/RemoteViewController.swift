import UIKit

/// Full-screen remote desktop: video, cursor, touch/pointer/keyboard input.
final class RemoteViewController: UIViewController, SessionDelegate, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    private let session: Session
    private let desk = UIView()            // bounds = desktop pixels, scaled by transform
    private let cursorLayer = CALayer()
    private let status = UILabel()
    private let keyInput = KeyInput()
    private let modeButton = UIButton(type: .system)
    private let displayButton = UIButton(type: .system)
    private let densityButton = UIButton(type: .system)

    private var W: CGFloat = 0, H: CGFloat = 0
    private var resizeScale: Double?
    private var lastSz = ""
    private var display = 0
    private var ownSize: [Int: String] = [:] // display -> its size before we resized it
    private var resized: Set<Int> = []       // displays this view changed
    private let kbGuide = UIView()           // follows the keyboard's top edge
    /// Points at the bottom hidden by the soft keyboard and key bar. The desktop may then be
    /// moved up by that much (pinch-pan), and is moved to keep the pointer in sight.
    private var covered: CGFloat = 0
    private var laidOutSize = CGSize.zero
    private var resizeTimer: Timer?
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var cursor = CGPoint.zero      // desktop pixels
    private var hotspot = CGPoint.zero
    private var lastMove = ""
    private var trackpad = true
    private var pinching = false
    private var scrollAcc = CGPoint.zero
    private var heldKeys: [Int: Int] = [:] // HID usage -> keysym sent on press
    private var pointerButtons: [ObjectIdentifier: Int] = [:]

    // ponytail: fixed trackpad gain; add acceleration curve if long moves feel slow.
    private let trackpadGain: CGFloat = 1.5

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var canBecomeFirstResponder: Bool { true }

    init(host: Host) {
        session = Session(host: host)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(desk)
        cursorLayer.anchorPoint = .zero
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        cursorLayer.zPosition = 1
        desk.layer.addSublayer(cursorLayer)
        desk.isUserInteractionEnabled = false

        status.textColor = .white
        status.font = .systemFont(ofSize: 17, weight: .medium)
        status.textAlignment = .center
        status.isUserInteractionEnabled = true
        status.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(statusTapped)))
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        keyInput.owner = self
        view.addSubview(keyInput)
        kbGuide.isHidden = true
        kbGuide.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(kbGuide)

        let backButton = chromeButton("chevron.left", #selector(goBack))
        backButton.accessibilityLabel = "Hosts"
        let kbButton = chromeButton("keyboard", #selector(toggleKeyboard))
        updateModeButton()
        modeButton.addTarget(self, action: #selector(toggleMode), for: .touchUpInside)
        styleChrome(modeButton)
        displayButton.setImage(UIImage(systemName: "display.2"), for: .normal)
        displayButton.accessibilityLabel = "Display"
        displayButton.showsMenuAsPrimaryAction = true
        displayButton.isHidden = true
        styleChrome(displayButton)
        densityButton.setImage(UIImage(systemName: "textformat.size"), for: .normal)
        densityButton.accessibilityLabel = "Text size"
        densityButton.showsMenuAsPrimaryAction = true
        styleChrome(densityButton)
        updateDensityMenu()
        let stack = UIStackView(arrangedSubviews: [backButton, displayButton, densityButton, kbButton, modeButton])
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            kbGuide.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            kbGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kbGuide.widthAnchor.constraint(equalToConstant: 1),
            kbGuide.heightAnchor.constraint(equalToConstant: 1),
        ])

        setupGestures()
        view.addInteraction(UIPointerInteraction(delegate: self))

        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.releaseAll()
                self?.session.stop()
            },
            // Keys held when another app took focus never come up.
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.releaseAll()
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.session.start()
            },
        ]

        session.delegate = self
        session.start()
    }

    private var observers: [NSObjectProtocol] = []
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        // The back-swipe would fight edge drags on the desktop; the chevron goes back.
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        releaseAll()
        session.close()
    }

    @objc private func goBack() { navigationController?.popViewController(animated: true) }

    // MARK: density

    /// How much of the Mac fits on screen: 0 = the Mac's own resolution (never resized, so
    /// windows stay put), 1 = Mac points as big as iPad points (large text), 3 = one Mac
    /// pixel per iPad pixel (most space), 2 = halfway. Every session starts at 0. Mac
    /// displays only offer fixed modes, so the host takes the largest that fits the asked size.
    // ponytail: fixed display modes; a virtual display at the exact size (as Jump Desktop does) would fill the screen.
    private var density = 0

    private func updateDensityMenu() {
        let names = ["Mac's resolution (no change)", "Large", "Medium", "More space (pixel perfect)"]
        densityButton.menu = UIMenu(title: "Text size", children: names.indices.map { i in
            UIAction(title: names[i], state: i == density ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.density = i
                self.updateDensityMenu()
                self.zoom = 1; self.offset = .zero
                self.layoutDesk()
                self.sendResize()
            }
        })
    }

    /// Device pixels per point of this screen (2 on Retina iPads).
    private var nativeScale: CGFloat { view.window?.screen.nativeScale ?? traitCollection.displayScale }

    private func updateDisplayMenu(count: Int, current: Int) {
        displayButton.isHidden = count < 2
        displayButton.menu = UIMenu(title: "Show display", children: (0..<count).map { i in
            UIAction(title: i == 0 ? "Display 1 (main)" : "Display \(i + 1)",
                     state: i == current ? .on : .off) { [weak self] _ in
                if i != current { self?.session.send("dp,\(i)") }
            }
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let kb = keyInput.isFirstResponder ? max(0, view.bounds.height - kbGuide.frame.maxY) : 0
        // Only when the keyboard or window size changed: every layout pass would pull a
        // zoomed-in view back to the pointer and undo pinch and pan.
        let changed = kb != covered || view.bounds.size != laidOutSize
        covered = kb
        laidOutSize = view.bounds.size
        layoutDesk()
        if changed { followCursor() }
        scheduleResize()
    }

    // MARK: chrome

    private func chromeButton(_ symbol: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        styleChrome(b)
        return b
    }

    private func styleChrome(_ b: UIButton) {
        b.tintColor = .white
        b.backgroundColor = UIColor(white: 0, alpha: 0.45)
        b.layer.cornerRadius = 20
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    private func updateModeButton() {
        modeButton.setImage(UIImage(systemName: trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left"), for: .normal)
        modeButton.accessibilityLabel = trackpad ? "Trackpad mode" : "Touch mode"
    }

    @objc private func toggleMode() { trackpad.toggle(); updateModeButton() }

    @objc private func toggleKeyboard() {
        if keyInput.isFirstResponder { keyInput.resignFirstResponder(); becomeFirstResponder() }
        else { keyInput.becomeFirstResponder() }
        view.setNeedsLayout() // covered depends on which responder is first
    }

    @objc private func statusTapped() { if !session.connected { session.start() } }

    // MARK: SessionDelegate

    func sessionHello(width: Int, height: Int, stripes: [Stripe], resizeScale: Double?, displays: Int, display: Int) {
        updateDisplayMenu(count: displays, current: display)
        self.display = display
        if ownSize[display] == nil { ownSize[display] = "\(width),\(height)" } // first hello: before we resized it
        W = CGFloat(width); H = CGFloat(height)
        for s in stripes { desk.layer.insertSublayer(s.layer, below: cursorLayer) }
        self.resizeScale = resizeScale
        lastSz = ""
        lastMove = ""
        cursor = CGPoint(x: min(cursor.x, W - 1), y: min(cursor.y, H - 1))
        layoutDesk()
        placeCursor()
        sendResize()
    }

    func sessionCursor(_ image: CGImage?, hotspot: CGPoint) {
        cursorLayer.contents = image
        if let image { cursorLayer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height) }
        self.hotspot = hotspot
        placeCursor()
    }

    func sessionAuthFailed() { navigationController?.popViewController(animated: true) }

    func sessionState(_ text: String?) {
        status.text = text
        status.isHidden = text == nil
    }

    // MARK: geometry

    /// Points per desktop pixel at zoom 1. When the desktop fits and stretching it would
    /// gain little, it is shown 1:1 (one desktop pixel per device pixel) so text stays
    /// sharp, with a thin border, instead of being scaled a few percent and blurred.
    private var fit: CGFloat {
        guard W > 0, H > 0 else { return 1 }
        let stretch = min(view.bounds.width / W, view.bounds.height / H)
        let exact = 1 / nativeScale
        return exact <= stretch && stretch / exact < 1.25 ? exact : stretch
    }

    /// Desktop pixels per on-screen point.
    private var deskPerPt: CGFloat { 1 / (fit * zoom) }

    private func layoutDesk() {
        guard W > 0 else { return }
        let s = fit * zoom
        let mx = max(0, (W * s - view.bounds.width) / 2), my = max(0, (H * s - view.bounds.height) / 2)
        offset.x = min(max(offset.x, -mx), mx)
        offset.y = min(max(offset.y, min(-my, (view.bounds.height - H * s) / 2 - covered)), my) // up to the keyboard's top
        desk.transform = .identity
        desk.bounds = CGRect(x: 0, y: 0, width: W, height: H)
        desk.transform = CGAffineTransform(scaleX: s, y: s)
        // Put the desktop's corner on a device pixel, or 1:1 still blurs by half a pixel.
        let n = nativeScale, half = CGSize(width: W * s / 2, height: H * s / 2)
        desk.center = CGPoint(x: ((view.bounds.midX + offset.x - half.width) * n).rounded() / n + half.width,
                              y: ((view.bounds.midY + offset.y - half.height) * n).rounded() / n + half.height)
    }

    private func scheduleResize() {
        guard resizeScale != nil else { return }
        resizeTimer?.invalidate()
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.sendResize() }
    }

    private func sendResize() {
        // Mac displays only offer landscape modes; a portrait size makes the host pick a tiny one.
        // ponytail: portrait keeps the current desktop letterboxed; add rotated modes if the host learns them.
        guard let base = resizeScale else { return }
        if density == 0 {
            // Back to the display's own size, only if we changed it. Done only once sent;
            // while disconnected it is retried after the next hello.
            // ponytail: sets the same-sized mode, not necessarily the user's exact one (refresh rate, HiDPI).
            if resized.contains(display), let own = ownSize[display], session.send("sz,\(own)") {
                lastSz = own
                resized.remove(display)
            }
            return
        }
        guard view.bounds.width >= view.bounds.height else { return }
        // Desktop pixels asked per window point: the host's own scale (Mac points as big as
        // iPad points) up to this screen's pixel density (one desktop pixel per device pixel).
        let native = Double(nativeScale)
        let scale = [base, (base + native) / 2, native][min(max(density, 1), 3) - 1]
        let w = Int((view.bounds.width * scale).rounded()), h = Int((view.bounds.height * scale).rounded())
        let key = "\(w),\(h)"
        guard key != lastSz else { return }
        // Counted only once sent; while disconnected it is retried after the next hello.
        if session.send("sz,\(key)") {
            lastSz = key
            resized.insert(display)
        }
    }

    private func placeCursor() {
        cursorLayer.position = CGPoint(x: cursor.x - hotspot.x, y: cursor.y - hotspot.y)
    }

    private func toDesk(_ p: CGPoint) -> CGPoint { desk.convert(p, from: view) }

    /// Moves the remote pointer to a desktop point (clamped) and sends `m` when it changed.
    private func move(to p: CGPoint) {
        guard W > 0 else { return }
        cursor = CGPoint(x: min(max(p.x, 0), W - 1), y: min(max(p.y, 0), H - 1))
        placeCursor()
        let s = "m,\(Int(cursor.x.rounded())),\(Int(cursor.y.rounded()))"
        if s != lastMove { lastMove = s; session.send(s) }
    }

    private func button(_ b: Int, _ down: Bool) { session.send("b,\(b),\(down ? 1 : 0)") }
    private func click(_ b: Int = 1) { button(b, true); button(b, false) }

    private func scroll(_ dPt: CGPoint) {
        scrollAcc.x -= dPt.x * deskPerPt
        scrollAcc.y -= dPt.y * deskPerPt
        guard abs(scrollAcc.x) >= 0.5 || abs(scrollAcc.y) >= 0.5 else { return }
        session.send(String(format: "sp,%.1f,%.1f", scrollAcc.x, scrollAcc.y))
        scrollAcc = .zero
    }

    /// Keeps the cursor in sight when zoomed in (trackpad mode) or above the soft keyboard.
    private func followCursor() {
        guard zoom > 1 || covered > 0, W > 0 else { return }
        let p = view.convert(cursor, from: desk), m: CGFloat = 40
        let b = view.bounds, bottom = b.height - covered - m
        if p.x < m { offset.x += m - p.x } else if p.x > b.width - m { offset.x -= p.x - (b.width - m) }
        if p.y < m { offset.y += m - p.y } else if p.y > bottom { offset.y -= p.y - bottom }
        layoutDesk()
    }

    // MARK: gestures (direct touch)

    private func setupGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let tap2 = UITapGestureRecognizer(target: self, action: #selector(tapped2))
        tap2.numberOfTouchesRequired = 2
        let tap1 = UITapGestureRecognizer(target: self, action: #selector(tapped1))
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        long.minimumPressDuration = 0.4
        let pan1 = UIPanGestureRecognizer(target: self, action: #selector(panned1))
        pan1.maximumNumberOfTouches = 1
        let pan2 = UIPanGestureRecognizer(target: self, action: #selector(panned2))
        pan2.minimumNumberOfTouches = 2
        pan2.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        for g in [tap1, tap2, long, pan1, pan2, pinch] as [UIGestureRecognizer] {
            g.allowedTouchTypes = direct
            g.delegate = self
            view.addGestureRecognizer(g)
        }

        // Magic Keyboard trackpad / mouse wheel scrolling.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        view.addGestureRecognizer(wheel)

        view.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
    }

    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        let pair = [a, b]
        return pair.contains { $0 is UIPinchGestureRecognizer } && pair.contains { ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }
    }

    @objc private func tapped1(_ g: UITapGestureRecognizer) {
        if !trackpad { move(to: toDesk(g.location(in: view))) }
        click()
    }

    @objc private func tapped2(_ g: UITapGestureRecognizer) {
        if !trackpad { move(to: toDesk(g.location(in: view))) }
        click(3)
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        if trackpad {
            // Hold, then drag: left-button drag from the cursor.
            switch g.state {
            case .began: lastLong = g.location(in: view); button(1, true)
            case .changed:
                let p = g.location(in: view)
                relative(CGPoint(x: p.x - lastLong.x, y: p.y - lastLong.y))
                lastLong = p
            case .ended, .cancelled, .failed: button(1, false)
            default: break
            }
        } else if g.state == .began {
            move(to: toDesk(g.location(in: view)))
            click(3)
        }
    }
    private var lastLong = CGPoint.zero

    private func relative(_ d: CGPoint) {
        let k = trackpadGain * deskPerPt
        move(to: CGPoint(x: cursor.x + d.x * k, y: cursor.y + d.y * k))
        followCursor()
    }

    @objc private func panned1(_ g: UIPanGestureRecognizer) {
        if trackpad {
            relative(g.translation(in: view))
            g.setTranslation(.zero, in: view)
            return
        }
        switch g.state {
        case .began:
            let t = g.translation(in: view), p = g.location(in: view)
            move(to: toDesk(CGPoint(x: p.x - t.x, y: p.y - t.y)))
            button(1, true)
            move(to: toDesk(p))
        case .changed: move(to: toDesk(g.location(in: view)))
        case .ended, .cancelled, .failed: button(1, false)
        default: break
        }
    }

    @objc private func panned2(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        if pinching {
            offset.x += t.x; offset.y += t.y
            layoutDesk()
        } else if g.state == .changed {
            scroll(t)
        }
        if g.state == .ended || g.state == .cancelled { scrollAcc = .zero }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinching = false
        case .changed:
            if !pinching {
                guard abs(g.scale - 1) > 0.15 else { return }
                pinching = true
            }
            let c = g.location(in: view), anchor = toDesk(c)
            zoom = min(max(zoom * g.scale, 1), 5)
            g.scale = 1
            let s = fit * zoom
            offset = CGPoint(x: c.x - (anchor.x - W / 2) * s - view.bounds.midX,
                             y: c.y - (anchor.y - H / 2) * s - view.bounds.midY)
            layoutDesk()
        default:
            if pinching, zoom < 1.05 {
                zoom = 1; offset.x = 0
                if covered == 0 { offset.y = 0 }
                layoutDesk()
            }
            pinching = false
        }
    }

    // MARK: pointer (Magic Keyboard trackpad / mouse)

    func pointerInteraction(_ i: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        move(to: toDesk(g.location(in: view)))
    }

    @objc private func wheeled(_ g: UIPanGestureRecognizer) {
        move(to: toDesk(g.location(in: view)))
        scroll(g.translation(in: view))
        g.setTranslation(.zero, in: view)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .indirectPointer {
            let mask = event?.buttonMask ?? .primary
            let b = mask.contains(.secondary) ? 3 : mask.contains(.button(3)) ? 2 : 1
            pointerButtons[ObjectIdentifier(t)] = b
            move(to: toDesk(t.location(in: view)))
            button(b, true)
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .indirectPointer { move(to: toDesk(t.location(in: view))) }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointerUp(touches)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointerUp(touches)
        super.touchesCancelled(touches, with: event)
    }

    private func pointerUp(_ touches: Set<UITouch>) {
        for t in touches where t.type == .indirectPointer {
            if let b = pointerButtons.removeValue(forKey: ObjectIdentifier(t)) {
                move(to: toDesk(t.location(in: view)))
                button(b, false)
            }
        }
    }

    // MARK: keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    /// Returns true when every press was a keyboard key sent to the host.
    @discardableResult
    func handlePresses(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = true
        for p in presses {
            guard let k = p.key else { handled = false; continue }
            let code = k.keyCode.rawValue
            if down {
                guard let sym = keysym(k) else { continue }
                heldKeys[code] = sym
                key(sym, true)
            } else if let sym = heldKeys.removeValue(forKey: code) {
                key(sym, false)
            }
        }
        return handled
    }

    func key(_ sym: Int, _ down: Bool) {
        // Something copied in an app beside Voxl (Split View) sends no notification:
        // sync before a V reaches the host, so Cmd+V there pastes it.
        if down, sym == 0x76 || sym == 0x56 { session.sendPasteboard() }
        session.send("k,\(sym),\(down ? 1 : 0)")
    }

    /// Taps a key with the soft-keyboard sticky modifiers held, then clears them.
    /// Sends Cmd+`sym` as one shortcut. If Cmd is already held on a hardware keyboard
    /// (and so already down on the host), only the key is sent.
    func cmdCombo(_ sym: Int) {
        let cmd = 0xffeb
        let held = heldKeys.values.contains(cmd)
        if !held { key(cmd, true) }
        key(sym, true); key(sym, false)
        if !held { key(cmd, false) }
    }

    /// iPadOS keeps these for itself (Spotlight, app switcher). Asking for priority
    /// gets some of them to the app; the key bar's buttons work either way.
    static let systemShortcuts: [UIKeyCommand] = [(" ", 0x20), ("\t", 0xff09)].map { input, sym in
        let c = UIKeyCommand(title: "", action: #selector(RemoteViewController.systemShortcut(_:)),
                             input: input, modifierFlags: .command, propertyList: sym)
        c.wantsPriorityOverSystemBehavior = true
        return c
    }

    override var keyCommands: [UIKeyCommand]? { RemoteViewController.systemShortcuts }

    @objc func systemShortcut(_ c: UIKeyCommand) {
        if let sym = c.propertyList as? Int { cmdCombo(sym) }
    }

    func tap(_ sym: Int) {
        let mods = keyInput.takeModifiers()
        mods.forEach { key($0, true) }
        key(sym, true); key(sym, false)
        mods.reversed().forEach { key($0, false) }
    }

    private func releaseAll() {
        session.send("r")
        heldKeys.removeAll()
        pointerButtons.removeAll()
    }

    private func keysym(_ k: UIKey) -> Int? {
        let code = k.keyCode.rawValue
        if (0x3A...0x45).contains(code) { return 0xffbe + code - 0x3A } // F1-F12
        if let s = RemoteViewController.special[k.keyCode] { return s }
        let mods = k.modifierFlags.intersection([.command, .control, .alternate])
        let text = mods.isEmpty ? k.characters : k.charactersIgnoringModifiers
        guard let u = text.unicodeScalars.first else { return nil }
        return RemoteViewController.keysym(for: u)
    }

    static func keysym(for u: Unicode.Scalar) -> Int {
        u.value < 0x100 ? Int(u.value) : 0x0100_0000 + Int(u.value)
    }

    private static let special: [UIKeyboardHIDUsage: Int] = [
        .keyboardReturnOrEnter: 0xff0d, .keypadEnter: 0xff8d, .keyboardEscape: 0xff1b,
        .keyboardDeleteOrBackspace: 0xff08, .keyboardTab: 0xff09, .keyboardSpacebar: 0x20,
        .keyboardDeleteForward: 0xffff, .keyboardHome: 0xff50, .keyboardEnd: 0xff57,
        .keyboardPageUp: 0xff55, .keyboardPageDown: 0xff56, .keyboardInsert: 0xff63,
        .keyboardLeftArrow: 0xff51, .keyboardUpArrow: 0xff52, .keyboardRightArrow: 0xff53, .keyboardDownArrow: 0xff54,
        .keyboardLeftShift: 0xffe1, .keyboardRightShift: 0xffe2,
        .keyboardLeftControl: 0xffe3, .keyboardRightControl: 0xffe4,
        .keyboardLeftAlt: 0xffe9, .keyboardRightAlt: 0xffea,
        .keyboardLeftGUI: 0xffeb, .keyboardRightGUI: 0xffec, // Cmd = Super
        .keyboardCapsLock: 0xffe5,
    ]
}

/// Hidden first responder that brings up the soft keyboard and its key toolbar.
final class KeyInput: UIView, UIKeyInput {
    weak var owner: RemoteViewController?
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    private var modItems: [(UIBarButtonItem, Int)] = []
    private lazy var toolbar: UIToolbar = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 100, height: 44))
        func item(_ title: String, _ tag: Int, symbol: String? = nil) -> UIBarButtonItem {
            let i = symbol.map { UIBarButtonItem(image: UIImage(systemName: $0), style: .plain, target: self, action: #selector(tapped)) }
                ?? UIBarButtonItem(title: title, style: .plain, target: self, action: #selector(tapped))
            i.tag = tag
            return i
        }
        let mods = [item("Shift", 0xffe1), item("Cmd", 0xffeb), item("Ctrl", 0xffe3), item("Opt", 0xffe9)]
        modItems = mods.map { ($0, $0.tag) }
        let hide = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: self, action: #selector(hide))
        // Shortcuts iPadOS takes for itself when typed, sent as one combo.
        func combo(_ title: String, _ sym: Int) -> UIBarButtonItem {
            UIBarButtonItem(title: title, primaryAction: UIAction { [weak self] _ in self?.owner?.cmdCombo(sym) })
        }
        bar.items = [item("Esc", 0xff1b), item("Tab", 0xff09)] + mods + [
            combo("⌘Space", 0x20), combo("⌘Tab", 0xff09),
            .flexibleSpace(),
            item("", 0xff51, symbol: "arrow.left"), item("", 0xff52, symbol: "arrow.up"),
            item("", 0xff54, symbol: "arrow.down"), item("", 0xff53, symbol: "arrow.right"),
            .flexibleSpace(), hide,
        ]
        return bar
    }()

    override var canBecomeFirstResponder: Bool { true }
    private lazy var keyBar = KeyBarScroll(toolbar)
    override var inputAccessoryView: UIView? { keyBar }
    override var keyCommands: [UIKeyCommand]? { RemoteViewController.systemShortcuts }
    @objc func systemShortcut(_ c: UIKeyCommand) { owner?.systemShortcut(c) }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        for u in text.unicodeScalars {
            owner?.tap(u == "\n" ? 0xff0d : RemoteViewController.keysym(for: u))
        }
    }

    func deleteBackward() { owner?.tap(0xff08) }

    /// Sticky modifiers currently on; turns them off (one-shot, like Jump).
    func takeModifiers() -> [Int] {
        let on = modItems.filter { $0.0.isSelected }.map(\.1)
        modItems.forEach { $0.0.isSelected = false }
        return on
    }

    @objc private func tapped(_ i: UIBarButtonItem) {
        if modItems.contains(where: { $0.0 === i }) { i.isSelected.toggle() } else { owner?.tap(i.tag) }
    }

    @objc private func hide() {
        resignFirstResponder()
        owner?.becomeFirstResponder()
    }

    // Hardware keys while the soft keyboard is up go straight to the host, not insertText.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { owner?.handlePresses(presses, down: true) }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { owner?.handlePresses(presses, down: false) }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { owner?.handlePresses(presses, down: false) }
}

/// The key bar, scrolled sideways when the screen is narrower than its buttons (iPhone).
final class KeyBarScroll: UIScrollView {
    private let bar: UIToolbar
    private static let minWidth: CGFloat = 1100 // every button shown, no "…" overflow

    init(_ bar: UIToolbar) {
        self.bar = bar
        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 44))
        autoresizingMask = .flexibleWidth
        showsHorizontalScrollIndicator = false
        addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = CGRect(x: 0, y: 0, width: max(bounds.width, KeyBarScroll.minWidth), height: bounds.height)
        contentSize = bar.frame.size
    }
}
