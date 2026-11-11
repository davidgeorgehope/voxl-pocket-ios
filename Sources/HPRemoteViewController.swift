import UIKit
import AVFoundation
import CoreMedia
import CoreVideo

/// Screen view for an Apple High-Performance Screen Sharing host (hpss://).
///
/// Drives `HPMediaSession` (RFB+SRP+enc1103 control, SRTP/HEVC-4:4:4 media) and
/// renders decoded frames through an `AVSampleBufferDisplayLayer`. Touches map
/// to RFB pointer events; a hidden text field feeds RFB key events. Reuses the
/// same navigation/full-screen presentation as the WebSocket RemoteViewController
/// and can be mirrored onto the external-display scene via `displayLayer`.
final class HPRemoteViewController: UIViewController {
    private var host: Host
    private var session: HPMediaSession?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let statsLabel = UILabel()
    private let statusLabel = UILabel()
    private let menuButton = UIButton(type: .system)
    private let chrome = UIStackView()
    private var canvasSize = CGSize(width: 1920, height: 1080)
    private var buttons: UInt8 = 0
    private var statsTimer: Timer?
    private var startedAt = Date()
    private var gotFrame = false
    private var failures = 0
    private var offeredFallback = false

    /// voxl is there to fall back to unless the host is a bare hpss:// address.
    private var canUseVoxl: Bool { !host.isHPSS }

    init(host: Host) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = view.bounds
        view.layer.addSublayer(displayLayer)

        statusLabel.textColor = .white
        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Connecting to \(host.name) in High Performance mode…"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        statsLabel.textColor = .systemGreen
        statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.numberOfLines = 0
        statsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statsLabel.isHidden = !host.hpShowStats
        statsLabel.isUserInteractionEnabled = false
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsLabel)

        // Same chrome as the voxl screen: round buttons in a row, top right.
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
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        view.addGestureRecognizer(pan)

        startSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        displayLayer.frame = view.bounds
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

    private func updateMenu() {
        var items: [UIMenuElement] = []
        if canUseVoxl {
            items.append(UIAction(title: "Switch to voxl", subtitle: "Turns High Performance mode off for this Mac",
                                  image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in self?.switchToVoxl(reason: nil) })
        }
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
        guard let hostname = host.hpHostname, !hostname.isEmpty else {
            statusLabel.text = "This Mac's address has no host name."; return
        }
        let pw = Hosts.hpPassword(for: host) ?? ""
        let s = HPMediaSession(host: hostname, port: host.hpPortValue, username: host.hpUsername, password: pw)
        // Muted by default: playing the Mac's audio next to the Mac would echo.
        s.audioPlayback = !host.hpMuted
        s.onCanvas = { [weak self] w, h in
            DispatchQueue.main.async { self?.canvasSize = CGSize(width: max(w,1), height: max(h,1)) }
        }
        s.onFrame = { [weak self] pb, _, _ in self?.enqueue(pb) }
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
        startedAt = Date()
        s.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let st = self.session?.stats else { return }
            if st.frames > 0 && !self.gotFrame { self.gotFrame = true; self.statusLabel.isHidden = true }
            if !self.gotFrame, Date().timeIntervalSince(self.startedAt) > 40 {
                self.failures = max(self.failures, 2)
                self.failed("Connected, but no picture arrived from the Mac.", wrongPassword: false)
            }
            let ff = st.connectToFirstFrameMs.map { String(format: "%.1fs", $0 / 1000) } ?? "—"
            let pipe = st.pipelineMs.map { String(format: "%.1f ms", $0) } ?? "—"
            let text = String(format: "HP %@  %dx%d  %d tiles  %.1f fps\nvideo %.0f pkt/s  %.1f Mbit/s  rx→screen %@  decErr %d\naudio %.0f pkt/s  %@  first frame %@",
                hostname, st.canvasW, st.canvasH, st.tiles, st.fps,
                st.videoPPS, st.videoKbps / 1000, pipe, st.decodeErrors, st.audioPPS,
                (self.session?.audioPlayback ?? false) ? "playing" : "muted", ff)
            self.statsLabel.text = text
            NSLog("[HPLive] %@ | frames %d bind %@", text.replacingOccurrences(of: "\n", with: " | "), st.frames, st.bindIP)
        }
    }

    // MARK: render

    private var fmtDesc: CMVideoFormatDescription?
    private var lastDims = (0, 0)

    private func enqueue(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if fmtDesc == nil || lastDims != (w, h) {
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fd)
            fmtDesc = fd; lastDims = (w, h)
        }
        guard let fmtDesc else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                    dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                                    formatDescription: fmtDesc, sampleTiming: &timing, sampleBufferOut: &sb)
        guard st == noErr, let sb else { return }
        if let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [CFMutableDictionary], let d = attach.first {
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.displayLayer.status == .failed { self.displayLayer.flush() }
            self.displayLayer.enqueue(sb)
        }
    }

    // MARK: input (RFB pointer)

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let p = canvasPoint(g.location(in: view))
        session?.sendPointer(x: p.x, y: p.y, buttons: 1)   // button1 down
        session?.sendPointer(x: p.x, y: p.y, buttons: 0)   // up (click)
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let p = canvasPoint(g.location(in: view))
        switch g.state {
        case .began: buttons = 1
        case .ended, .cancelled: buttons = 0
        default: break
        }
        session?.sendPointer(x: p.x, y: p.y, buttons: buttons)
    }

    /// Map a view point to canvas pixels, honouring the aspect-fit letterbox.
    private func canvasPoint(_ pt: CGPoint) -> (x: Int, y: Int) {
        let vb = view.bounds.size
        let scale = min(vb.width / canvasSize.width, vb.height / canvasSize.height)
        let drawn = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        let ox = (vb.width - drawn.width) / 2, oy = (vb.height - drawn.height) / 2
        let x = (pt.x - ox) / max(scale, 0.0001)
        let y = (pt.y - oy) / max(scale, 0.0001)
        return (Int(max(0, min(canvasSize.width - 1, x))), Int(max(0, min(canvasSize.height - 1, y))))
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        statsTimer?.invalidate(); statsTimer = nil
        session?.stop(); session = nil
    }

    /// "hpss://mac.ts.net" or "hpss://mac.ts.net:5900" -> (host, port).
    static func parseHPSS(_ url: String) -> (String, UInt16)? {
        guard let c = URLComponents(string: url), c.scheme?.lowercased() == "hpss", let h = c.host, !h.isEmpty else { return nil }
        return (h, UInt16(c.port ?? 5900))
    }
}
