import UIKit
import AVFoundation
import CoreMedia
import CoreVideo
import GameController

/// Screen view for an Apple High-Performance Screen Sharing host.
///
/// Drives `HPMediaSession` and shows each decoded tile on its own
/// AVSampleBufferDisplayLayer (stacked stripes, no CPU composite). The pointer is
/// drawn locally from the host's cursor shapes (enc 1104) and moves the moment a
/// finger does, like the voxl screen: trackpad mode by default, tap to click,
/// two-finger tap for a right click, hold then drag to drag, two fingers to scroll,
/// pinch to zoom.
final class HPRemoteViewController: UIViewController, UIGestureRecognizerDelegate, UIPointerInteractionDelegate, ExternalDisplayDelegate {
    private var host: Host
    private var session: HPMediaSession?
    private let desk = UIView()                  // canvas-pixel coordinates, scaled to fit
    private var tileLayers: [Int: AVSampleBufferDisplayLayer] = [:]
    private var tileDesc: [Int: (CMVideoFormatDescription, Int, Int)] = [:]
    private let cursorLayer = CALayer()
    private var cursorImage: CGImage?
    private var hotspot = CGPoint.zero
    private let statsLabel = UILabel()
    private let statusLabel = UILabel()
    private let monitorHint = UILabel()
    private let menuButton = UIButton(type: .system)
    private let chrome = UIStackView()
    private var W: CGFloat = 0, H: CGFloat = 0   // canvas pixels
    private var cursor = CGPoint(x: 400, y: 300)
    private var buttons: UInt8 = 0
    private var trackpad = UserDefaults.standard.object(forKey: "hpTrackpad") as? Bool ?? true
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var pinching = false
    private var scrollAcc: CGFloat = 0
    private var lastLong = CGPoint.zero
    private var statsTimer: Timer?
    private var startedAt = Date()
    private var gotFrame = false
    private var failures = 0
    private var offeredFallback = false
    private var moves = 0
    private var restoreTouchOnUnplug = false
    private var mouseObservers: [NSObjectProtocol] = []
    /// voxl's on-device check: does this device's hardware decoder take HEVC 4:4:4?
    private var device444: Bool?

    /// voxl is there to fall back to unless the host is a bare hpss:// address.
    private var canUseVoxl: Bool { !host.isHPSS }

    override var prefersPointerLocked: Bool { ExternalDisplay.isActive }

    /// The view that currently shows the desktop (the monitor, when there is one).
    private var deskHost: UIView { ExternalDisplay.hostView ?? view }

    /// Trackpad-style input: on by preference, and always while the desktop is on a monitor.
    private var trackpadSurface: Bool { trackpad || ExternalDisplay.isActive }

    init(host: Host) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        desk.clipsToBounds = true
        desk.isUserInteractionEnabled = false
        view.addSubview(desk)
        cursorLayer.anchorPoint = .zero
        cursorLayer.zPosition = 100
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "transform": NSNull()]
        desk.layer.addSublayer(cursorLayer)
        setCursor(nil, .zero)

        statusLabel.textColor = .white
        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Connecting to \(host.name) in High Performance mode…"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        monitorHint.text = "Desktop is on the monitor\nUse this screen as a trackpad"
        monitorHint.textColor = UIColor(white: 1, alpha: 0.8)
        monitorHint.font = .systemFont(ofSize: 17, weight: .medium)
        monitorHint.textAlignment = .center
        monitorHint.numberOfLines = 0
        monitorHint.isHidden = true
        monitorHint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(monitorHint)

        statsLabel.textColor = .systemGreen
        statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.numberOfLines = 0
        statsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statsLabel.isHidden = !host.hpShowStats
        statsLabel.isUserInteractionEnabled = false
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsLabel)

        let back = chromeButton("chevron.left")
        back.accessibilityLabel = "Hosts"
        back.addAction(UIAction { [weak self] _ in self?.navigationController?.popViewController(animated: true) }, for: .touchUpInside)
        menuButton.setImage(UIImage(systemName: "bolt.horizontal.circle"), for: .normal)
        menuButton.accessibilityLabel = "High Performance"
        menuButton.showsMenuAsPrimaryAction = true
        style(menuButton)
        updateMenu()
        chrome.addArrangedSubview(back)
        chrome.addArrangedSubview(menuButton)
        chrome.spacing = 12
        chrome.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            chrome.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            // Stats sit under the buttons so they never cover the back button.
            statsLabel.topAnchor.constraint(equalTo: chrome.bottomAnchor, constant: 8),
            statsLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            statsLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            monitorHint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            monitorHint.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            monitorHint.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            monitorHint.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        setupGestures()
        view.addInteraction(UIPointerInteraction(delegate: self))
        setupMouse()
        ExternalDisplay.delegate = self
        if let w = ExternalDisplay.window { externalDisplayDidConnect(w) }
        startSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ExternalDisplay.delegate = self
        setNeedsUpdateOfPrefersPointerLocked()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDesk()
    }

    private func chromeButton(_ symbol: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        style(b)
        return b
    }

    private func style(_ b: UIButton) {
        b.tintColor = .white
        b.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        b.layer.cornerRadius = 20
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 40), b.heightAnchor.constraint(equalToConstant: 40)])
    }

    // MARK: layout (canvas → screen)

    private var fit: CGFloat {
        guard W > 0, H > 0 else { return 1 }
        let b = deskHost.bounds
        return min(b.width / W, b.height / H)
    }
    /// Screen points per canvas pixel right now.
    private var scale: CGFloat { fit * zoom }

    private func layoutDesk() {
        guard W > 0 else { return }
        let host = deskHost
        let s = scale
        // Keep the zoomed canvas covering the surface where it can. On a monitor
        // at zoom 1 this fills the panel (letterboxed if the aspect ratios differ).
        let maxX = max(0, (W * s - host.bounds.width) / 2), maxY = max(0, (H * s - host.bounds.height) / 2)
        if ExternalDisplay.isActive, zoom <= 1 { offset = .zero }
        offset.x = min(max(offset.x, -maxX), maxX); offset.y = min(max(offset.y, -maxY), maxY)
        desk.transform = .identity
        desk.bounds = CGRect(x: 0, y: 0, width: W, height: H)
        let n = ExternalDisplay.isActive ? ExternalDisplay.screenScale : (view.window?.screen.nativeScale ?? traitCollection.displayScale)
        let half = CGSize(width: W * s / 2, height: H * s / 2)
        desk.center = CGPoint(x: ((host.bounds.midX + offset.x - half.width) * n).rounded() / n + half.width,
                              y: ((host.bounds.midY + offset.y - half.height) * n).rounded() / n + half.height)
        desk.transform = CGAffineTransform(scaleX: s, y: s)
        placeCursor()
    }

    private func toDesk(_ p: CGPoint) -> CGPoint { desk.convert(p, from: view) }

    /// Puts the desktop on the monitor when one is connected, or back on the phone.
    private func attachDesk() {
        let host = deskHost
        if desk.superview !== host { host.insertSubview(desk, at: 0) }
        monitorHint.isHidden = !ExternalDisplay.isActive
        // The monitor hint takes the centre of the phone; errors still appear as alerts.
        if ExternalDisplay.isActive {
            statusLabel.isHidden = true
        } else if statusLabel.text == nil || statusLabel.text?.isEmpty == true {
            statusLabel.isHidden = true
        } else {
            statusLabel.isHidden = false
        }
    }

    func externalDisplayDidConnect(_ window: UIWindow) {
        if !trackpad {
            restoreTouchOnUnplug = true
            trackpad = true
            updateMenu()
        }
        zoom = 1
        offset = .zero
        attachDesk()
        layoutDesk()
        placeCursor()
        setNeedsUpdateOfPrefersPointerLocked()
    }

    func externalDisplayDidDisconnect() {
        if restoreTouchOnUnplug {
            trackpad = false
            restoreTouchOnUnplug = false
            updateMenu()
        }
        zoom = 1
        offset = .zero
        attachDesk()
        layoutDesk()
        placeCursor()
        followCursor()
        setNeedsUpdateOfPrefersPointerLocked()
    }

    func externalDisplayDidLayout(_ window: UIWindow) {
        layoutDesk()
    }

    // MARK: video (one display layer per tile)

    private func showTile(_ index: Int, _ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var fd = tileDesc[index]
        if fd == nil || fd!.1 != w || fd!.2 != h {
            var d: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &d)
            guard let d else { return }
            fd = (d, w, h); tileDesc[index] = fd
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
                                                 makeDataReadyCallback: nil, refcon: nil, formatDescription: fd!.0,
                                                 sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
        if let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [CFMutableDictionary], let a = attach.first {
            CFDictionarySetValue(a, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let layer: AVSampleBufferDisplayLayer
            if let l = self.tileLayers[index] { layer = l } else {
                layer = AVSampleBufferDisplayLayer()
                layer.videoGravity = .resize
                layer.zPosition = CGFloat(index)          // a tile covers the previous one's CTU padding
                layer.actions = ["position": NSNull(), "bounds": NSNull()]
                self.desk.layer.insertSublayer(layer, below: self.cursorLayer)
                self.tileLayers[index] = layer
            }
            // Tiles are CTU-padded stripes at index × picture height (as the composite was).
            let frame = CGRect(x: 0, y: CGFloat(index * h), width: CGFloat(w), height: CGFloat(h))
            if layer.frame != frame { layer.frame = frame }
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sb)
            if !self.gotFrame {
                self.gotFrame = true; self.statusLabel.isHidden = true
                let env = ProcessInfo.processInfo.environment
                if env["VOXL_HP_POINTER_TEST"] == "1" { self.pointerTest() }
                // Test hook: put the Mac's pointer at x,y (canvas pixels).
                if let to = env["VOXL_HP_POINTER_TO"]?.split(separator: ",").compactMap({ Double($0) }), to.count == 2 {
                    self.move(to: CGPoint(x: to[0], y: to[1]))
                }
            }
        }
    }

    // MARK: cursor (drawn here, moves with the finger)

    private func setCursor(_ img: CGImage?, _ hot: CGPoint) {
        cursorImage = img ?? Self.defaultArrow
        hotspot = img == nil ? CGPoint(x: 2, y: 2) : hot
        cursorLayer.contents = cursorImage
        placeCursor()
    }

    private func placeCursor() {
        guard let img = cursorImage else { return }
        // At least ~18 pt tall on screen, else a 4K canvas on a phone shrinks it to a speck.
        let k = max(1, 18 / (CGFloat(img.height) * max(scale, 0.01)))
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
        cursorLayer.position = CGPoint(x: cursor.x - hotspot.x * k, y: cursor.y - hotspot.y * k)
    }

    static let defaultArrow: CGImage? = {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 36), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return r.image { ctx in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 2, y: 2)); p.addLine(to: CGPoint(x: 2, y: 30)); p.addLine(to: CGPoint(x: 9, y: 24))
            p.addLine(to: CGPoint(x: 14, y: 34)); p.addLine(to: CGPoint(x: 18, y: 32)); p.addLine(to: CGPoint(x: 13, y: 22))
            p.addLine(to: CGPoint(x: 22, y: 22)); p.close()
            UIColor.black.setFill(); p.fill()
            UIColor.white.setStroke(); p.lineWidth = 1.5; p.stroke()
        }.cgImage
    }()

    // MARK: input

    private func setupGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let tap2 = UITapGestureRecognizer(target: self, action: #selector(tapped2)); tap2.numberOfTouchesRequired = 2
        let tap1 = UITapGestureRecognizer(target: self, action: #selector(tapped1))
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed)); long.minimumPressDuration = 0.4
        let pan1 = UIPanGestureRecognizer(target: self, action: #selector(panned1)); pan1.maximumNumberOfTouches = 1
        let pan2 = UIPanGestureRecognizer(target: self, action: #selector(panned2)); pan2.minimumNumberOfTouches = 2; pan2.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        for g in [tap1, tap2, long, pan1, pan2, pinch] as [UIGestureRecognizer] {
            g.allowedTouchTypes = direct
            g.delegate = self
            view.addGestureRecognizer(g)
        }
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

    /// Moves the local cursor at once and sends the position (coalesced in the session).
    private func move(to p: CGPoint) {
        guard W > 0 else { return }
        cursor = CGPoint(x: min(max(p.x, 0), W - 1), y: min(max(p.y, 0), H - 1))
        placeCursor()
        moves += 1
        session?.movePointer(x: Int(cursor.x.rounded()), y: Int(cursor.y.rounded()), buttons: buttons)
    }

    private func button(_ mask: UInt8, _ down: Bool) {
        if down { buttons |= mask } else { buttons &= ~mask }
        session?.sendPointer(x: Int(cursor.x.rounded()), y: Int(cursor.y.rounded()), buttons: buttons)
    }

    private func click(_ mask: UInt8 = 1) { button(mask, true); button(mask, false) }

    /// Trackpad motion: 1.5 canvas-points per finger point like voxl, plus a little
    /// acceleration so a 4K desktop doesn't need several swipes to cross.
    private func relative(_ d: CGPoint, velocity v: CGPoint) {
        let speed = hypot(v.x, v.y)
        let accel = 1 + min(speed / 1200, 1.5)
        let k = 1.5 * accel / max(scale, 0.01)       // canvas pixels per finger point
        move(to: CGPoint(x: cursor.x + d.x * k, y: cursor.y + d.y * k))
        followCursor()
    }

    private func followCursor() {
        guard !ExternalDisplay.isActive, zoom > 1 else { return }
        let p = view.convert(cursor, from: desk), m: CGFloat = 40, b = view.bounds
        if p.x < m { offset.x += m - p.x } else if p.x > b.width - m { offset.x -= p.x - (b.width - m) }
        if p.y < m { offset.y += m - p.y } else if p.y > b.height - m { offset.y -= p.y - (b.height - m) }
        layoutDesk()
    }

    @objc private func tapped1(_ g: UITapGestureRecognizer) {
        if !trackpadSurface { move(to: toDesk(g.location(in: view))) }
        click(1)
    }

    @objc private func tapped2(_ g: UITapGestureRecognizer) {
        if !trackpadSurface { move(to: toDesk(g.location(in: view))) }
        click(4)                                     // Apple mask: bit 2 = right button
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        if trackpadSurface {
            switch g.state {
            case .began: lastLong = g.location(in: view); button(1, true)
            case .changed:
                let p = g.location(in: view)
                relative(CGPoint(x: p.x - lastLong.x, y: p.y - lastLong.y), velocity: .zero)
                lastLong = p
            case .ended, .cancelled, .failed: button(1, false)
            default: break
            }
        } else if g.state == .began {
            move(to: toDesk(g.location(in: view)))
            click(4)
        }
    }

    @objc private func panned1(_ g: UIPanGestureRecognizer) {
        if trackpadSurface {
            relative(g.translation(in: view), velocity: g.velocity(in: view))
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
        if pinching, !ExternalDisplay.isActive {
            offset.x += t.x; offset.y += t.y
            layoutDesk()
        } else if g.state == .changed {
            scroll(t.y)
        }
        if g.state == .ended || g.state == .cancelled { scrollAcc = 0 }
    }

    /// One wheel tick per ~10 pt of finger travel. Direction follows InputMap.naturalScrolling.
    private func scroll(_ dy: CGFloat, perTick: CGFloat = 10) {
        let ticks = InputMap.hpScrollTicks(translationY: dy, accumulated: &scrollAcc, perTick: perTick)
        guard ticks != 0 else { return }
        session?.scroll(x: Int(cursor.x), y: Int(cursor.y), ticks: ticks, buttons: buttons)
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        if ExternalDisplay.isActive { return }
        switch g.state {
        case .began: pinching = false
        case .changed:
            if !pinching {
                guard abs(g.scale - 1) > 0.15 else { return }
                pinching = true
            }
            let c = g.location(in: view), anchor = toDesk(c)
            zoom = min(max(zoom * g.scale, 1), 6)
            g.scale = 1
            let s = scale
            offset = CGPoint(x: c.x - (anchor.x - W / 2) * s - view.bounds.midX,
                             y: c.y - (anchor.y - H / 2) * s - view.bounds.midY)
            layoutDesk()
        default:
            if pinching, zoom < 1.05 { zoom = 1; offset = .zero; layoutDesk() }
            pinching = false
        }
    }

    func pointerInteraction(_ i: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard !ExternalDisplay.isActive else { return }
        move(to: toDesk(g.location(in: view)))
    }

    @objc private func wheeled(_ g: UIPanGestureRecognizer) {
        if !ExternalDisplay.isActive { move(to: toDesk(g.location(in: view))) }
        scroll(g.translation(in: view).y, perTick: 6)
        g.setTranslation(.zero, in: view)
    }

    // Magic Keyboard trackpad / mouse buttons.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .indirectPointer {
            if !ExternalDisplay.isActive { move(to: toDesk(t.location(in: view))) }
            button(event?.buttonMask.contains(.secondary) == true ? 4 : 1, true)
        }
        super.touchesBegan(touches, with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !ExternalDisplay.isActive {
            for t in touches where t.type == .indirectPointer { move(to: toDesk(t.location(in: view))) }
        }
        super.touchesMoved(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .indirectPointer { button(5, false) }
        super.touchesEnded(touches, with: event)
    }

    /// Test hook: sweep the pointer through the same path a finger drag takes.
    private func pointerTest() {
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            i += 1
            self.relative(CGPoint(x: 2, y: 1), velocity: CGPoint(x: 240, y: 120))
            if i >= 120 { t.invalidate(); NSLog("[HPLive] pointer test done: cursor %.0f,%.0f", self.cursor.x, self.cursor.y) }
        }
    }

    // MARK: menu, fallback

    private func updateMenu() {
        var items: [UIMenuElement] = []
        if canUseVoxl {
            items.append(UIAction(title: "Switch to voxl", subtitle: "Turns High Performance mode off for this Mac",
                                  image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in self?.switchToVoxl(reason: nil) })
        }
        items.append(UIAction(title: "Trackpad mode", subtitle: "Drag anywhere to move the pointer; off = tap where you want",
                              image: UIImage(systemName: "rectangle.and.hand.point.up.left"),
                              state: trackpad ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.trackpad.toggle()
            UserDefaults.standard.set(self.trackpad, forKey: "hpTrackpad")
            self.updateMenu()
        })
        items.append(UIAction(title: "Natural scrolling",
                              subtitle: "Content follows your fingers, like a Mac trackpad",
                              image: UIImage(systemName: "arrow.up.and.down"),
                              state: InputMap.naturalScrolling ? .on : .off) { [weak self] _ in
            InputMap.naturalScrolling.toggle()
            self?.updateMenu()
        })
        items.append(UIAction(title: "Mute Mac audio", image: UIImage(systemName: "speaker.slash"),
                              state: host.hpMuted ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.host.hpMute = !self.host.hpMuted
            self.session?.audioPlayback = !self.host.hpMuted
            self.persist(); self.updateMenu()
        })
        items.append(UIAction(title: "Stats overlay", image: UIImage(systemName: "speedometer"),
                              state: host.hpShowStats ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.host.hpStats = !self.host.hpShowStats
            self.statsLabel.isHidden = !self.host.hpShowStats
            self.persist(); self.updateMenu()
        })
        menuButton.menu = UIMenu(title: "High Performance mode", children: items)
    }

    private func persist() {
        guard var saved = Hosts.all.first(where: { $0.url == host.url }) else { return }
        saved.hpMute = host.hpMute; saved.hpStats = host.hpStats; saved.hp = host.hp
        Hosts.update(saved)
    }

    /// Turn High Performance off for this host and replace this screen with the voxl one.
    private func switchToVoxl(reason: String?) {
        guard canUseVoxl, let nav = navigationController else { return }
        NSLog("[HPLive] switching to voxl%@", reason.map { ": " + $0 } ?? "")
        session?.stop(); session = nil
        host.hp = false
        persist()
        let go = { [weak nav] in
            guard let nav else { return }
            var stack = nav.viewControllers
            if let i = stack.firstIndex(where: { $0 === self }) { stack[i] = RemoteViewController(host: self.host) }
            nav.setViewControllers(stack, animated: true)
        }
        if Hosts.password(for: host.url) == nil {
            let a = UIAlertController(title: host.name, message: "voxl password for \(host.url)", preferredStyle: .alert)
            a.addTextField { $0.isSecureTextEntry = true; $0.placeholder = "Password"; $0.textContentType = .password }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.navigationController?.popViewController(animated: true) })
            a.addAction(UIAlertAction(title: "Connect", style: .default) { [weak a, weak self] _ in
                guard let self, let pw = a?.textFields?[0].text, !pw.isEmpty else { return }
                Hosts.setPassword(pw, for: self.host.url)
                go()
            })
            present(a, animated: true)
        } else {
            go()
        }
    }

    /// Plain words for what went wrong.
    private static func explain(_ error: Error) -> String {
        let d = String(describing: error)
        if d.contains("auth(") { return "The Mac turned down the username or password. Check them in this Mac's settings (the ⓘ button)." }
        if d.contains("connect") || d.contains("resolve") {
            return "Couldn't reach Screen Sharing on the Mac. Check that Screen Sharing is on (System Settings › General › Sharing) and the Mac is reachable."
        }
        if d.contains("degenerate canvas") { return "The Mac answered but didn't start a High Performance stream." }
        if d.contains("closed by host") { return "The Mac closed the High Performance session." }
        return "High Performance mode stopped: \(d)"
    }

    private func failed(_ message: String, wrongPassword: Bool) {
        statusLabel.isHidden = false
        statusLabel.text = message + "\nRetrying…"
        guard !gotFrame, !offeredFallback, presentedViewController == nil else { return }
        // Once for a wrong password (retrying won't help); else after two failures.
        guard wrongPassword || failures >= 2 else { return }
        offeredFallback = true
        // Test hook: take the "Use voxl" path without a tap.
        if canUseVoxl, ProcessInfo.processInfo.environment["VOXL_HP_AUTOFALLBACK"] == "1" { return switchToVoxl(reason: message) }
        let a = UIAlertController(title: "High Performance mode isn't working",
                                  message: message + (canUseVoxl ? "\n\nYou can use voxl instead; High Performance mode will be turned off for this Mac." : ""),
                                  preferredStyle: .alert)
        if canUseVoxl {
            a.addAction(UIAlertAction(title: "Use voxl", style: .default) { [weak self] _ in self?.switchToVoxl(reason: message) })
        }
        a.addAction(UIAlertAction(title: "Keep trying", style: .cancel) { [weak self] _ in self?.offeredFallback = false; self?.failures = 0 })
        a.addAction(UIAlertAction(title: "Back", style: .destructive) { [weak self] _ in self?.navigationController?.popViewController(animated: true) })
        present(a, animated: true)
    }

    private func startSession() {
        if ProcessInfo.processInfo.environment["VOXL_HP_FAKE_DESK"] == "1" {
            installFakeDesk()
            return
        }
        guard let hostname = host.hpHostname, !hostname.isEmpty else {
            statusLabel.text = "This Mac's address has no host name."; return
        }
        let pw = Hosts.hpPassword(for: host) ?? ""
        let s = HPMediaSession(host: hostname, port: host.hpPortValue, username: host.hpUsername, password: pw)
        // Muted by default: playing the Mac's audio next to the Mac would echo.
        s.audioPlayback = !host.hpMuted
        s.onCanvas = { [weak self] w, h in
            DispatchQueue.main.async {
                guard let self else { return }
                self.W = CGFloat(max(w, 1)); self.H = CGFloat(max(h, 1))
                self.cursor = CGPoint(x: self.W / 2, y: self.H / 2)
                self.attachDesk()
                self.layoutDesk()
            }
        }
        s.onTile = { [weak self] i, pb in self?.showTile(i, pb) }
        s.onCursor = { [weak self] img, hot in DispatchQueue.main.async { self?.setCursor(img, hot) } }
        s.onLog = { line in NSLog("%@", line) }
        s.onError = { [weak self] error in
            let wrong = String(describing: error).contains("auth(")
            DispatchQueue.main.async {
                guard let self else { return }
                self.failures += 1
                self.failed(Self.explain(error), wrongPassword: wrong)
            }
        }
        session = s
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = DecoderCheck.result.hevc444
            DispatchQueue.main.async { self?.device444 = r }
        }
        startedAt = Date()
        s.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let st = self.session?.stats else { return }
            if !self.gotFrame, Date().timeIntervalSince(self.startedAt) > 40 {
                self.failures = max(self.failures, 2)
                self.failed("Connected, but no picture arrived from the Mac.", wrongPassword: false)
            }
            let ff = st.connectToFirstFrameMs.map { String(format: "%.1fs", $0 / 1000) } ?? "—"
            let pipe = st.pipelineMs.map { String(format: "%.0f ms", $0) } ?? "—"
            let e2e = st.e2eMs.map { String(format: "  screen→decoded %.0f ms", $0) } ?? ""
            let sent = self.session?.pointerSent ?? 0, coalesced = self.session?.pointerCoalesced ?? 0
            let dev = self.device444.map { $0 ? "device HW 4:4:4 yes" : "device HW 4:4:4 NO" } ?? ""
            let text = String(format: "HP %dx%d  %d tiles  %.0f fps  %@ decode  %@\nvideo %.1f Mbit/s  rx→decoded %@%@\nloss %d pkts  dropped %d  decErr %d  keyframe req %d  queue %d\npointer %d moves → %d sent (%d merged)  audio %@\nconnect %@: %@",
                st.canvasW, st.canvasH, st.tiles, st.updateFPS, st.hwDecode ? "HW" : "SOFTWARE", dev,
                st.videoKbps / 1000, pipe, e2e,
                st.lostPackets, st.droppedFrames, st.decodeErrors, st.firs, st.backlogMax,
                self.moves, sent, coalesced, (self.session?.audioPlayback ?? false) ? "on" : "muted",
                ff, st.phases)
            self.statsLabel.text = text
            NSLog("[HPLive] %@ | frames %d e2eLast %@ n=%d", text.replacingOccurrences(of: "\n", with: " | "), st.frames,
                  st.e2eLast.map { String(format: "%.0f", $0) } ?? "-", st.e2eSamples)
        }
    }

    /// Simulator / screenshot hook: a labelled 1920×1080 canvas, same attach/layout path as a live stream.
    private func installFakeDesk() {
        W = 1920
        H = 1080
        cursor = CGPoint(x: W / 2, y: H / 2)
        desk.viewWithTag(0x48504644)?.removeFromSuperview() // "HPFD"
        let canvas = FakeHPDesktopView(frame: CGRect(x: 0, y: 0, width: W, height: H))
        canvas.tag = 0x48504644
        canvas.autoresizingMask = []
        desk.insertSubview(canvas, at: 0)
        statusLabel.text = "High Performance (test desktop)"
        attachDesk()
        layoutDesk()
        placeCursor()
        NSLog("[HPLive] fake desk %gx%g on %@", W, H, ExternalDisplay.isActive ? "external display" : "phone")
    }

    private func setupMouse() {
        let nc = NotificationCenter.default
        mouseObservers = [
            nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
                self?.attachMouse(n.object as? GCMouse)
            },
            nc.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] n in
                (n.object as? GCMouse)?.mouseInput?.mouseMovedHandler = nil
                self?.setNeedsUpdateOfPrefersPointerLocked()
            },
        ]
        GCMouse.mice().forEach { attachMouse($0) }
    }

    private func attachMouse(_ mouse: GCMouse?) {
        guard let input = mouse?.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            guard let self, ExternalDisplay.isActive else { return }
            self.relative(CGPoint(x: CGFloat(dx), y: CGFloat(dy)), velocity: .zero)
        }
        setNeedsUpdateOfPrefersPointerLocked()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        if desk.superview !== view { desk.removeFromSuperview() }
        if ExternalDisplay.delegate === self { ExternalDisplay.delegate = nil }
        statsTimer?.invalidate(); statsTimer = nil
        session?.stop(); session = nil
    }

    deinit {
        if ExternalDisplay.delegate === self { ExternalDisplay.delegate = nil }
        mouseObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Coloured 1920×1080 panel used when VOXL_HP_FAKE_DESK=1, so Simulator screenshots
/// can show the desktop on an attached external display without a live HP stream.
private final class FakeHPDesktopView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 0.07, green: 0.18, blue: 0.38, alpha: 1)
        let title = UILabel()
        title.text = "High Performance desktop"
        title.textColor = .white
        title.font = .systemFont(ofSize: 72, weight: .semibold)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        let sub = UILabel()
        sub.text = "1920 × 1080  ·  fills this monitor"
        sub.textColor = UIColor(white: 1, alpha: 0.8)
        sub.font = .systemFont(ofSize: 36, weight: .medium)
        sub.textAlignment = .center
        sub.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(sub)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            sub.centerXAnchor.constraint(equalTo: centerXAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let c = UIGraphicsGetCurrentContext() else { return }
        c.setStrokeColor(UIColor(white: 1, alpha: 0.12).cgColor)
        c.setLineWidth(2)
        let step: CGFloat = 120
        var x: CGFloat = 0
        while x <= bounds.width {
            c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: bounds.height)); x += step
        }
        var y: CGFloat = 0
        while y <= bounds.height {
            c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: bounds.width, y: y)); y += step
        }
        c.strokePath()
        c.setStrokeColor(UIColor.systemOrange.cgColor)
        c.setLineWidth(16)
        c.stroke(bounds.insetBy(dx: 8, dy: 8))
    }
}
