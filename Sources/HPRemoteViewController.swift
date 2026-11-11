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
    private let host: Host
    private var session: HPMediaSession?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let statusLabel = UILabel()
    private var canvasSize = CGSize(width: 1920, height: 1080)
    private var buttons: UInt8 = 0
    private var statsTimer: Timer?

    init(host: Host) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = view.bounds
        view.layer.addSublayer(displayLayer)

        statusLabel.textColor = .systemGreen
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.frame = CGRect(x: 8, y: 48, width: view.bounds.width - 16, height: 120)
        statusLabel.text = "connecting \(host.url)…"
        view.addSubview(statusLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        view.addGestureRecognizer(pan)

        startSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        displayLayer.frame = view.bounds
    }

    private func startSession() {
        guard let (hostname, port) = Self.parseHPSS(host.url) else {
            statusLabel.text = "bad hpss url: \(host.url)"; return
        }
        let pw = Hosts.password(for: host.url) ?? ""
        let s = HPMediaSession(host: hostname, port: port, username: "", password: pw)
        s.onCanvas = { [weak self] w, h in
            DispatchQueue.main.async { self?.canvasSize = CGSize(width: max(w,1), height: max(h,1)) }
        }
        s.onFrame = { [weak self] pb, _, _ in self?.enqueue(pb) }
        s.onLog = { line in NSLog("%@", line) }
        session = s
        s.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let st = self.session?.stats else { return }
            let ff = st.firstFrameMs != nil ? "ok" : "—"
            self.statusLabel.text = "hpss \(self.host.url)\ncanvas \(Int(self.canvasSize.width))x\(Int(self.canvasSize.height))  frames \(st.frames)  fps \(String(format: "%.1f", st.fps))  firstFrame \(ff)"
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
        statsTimer?.invalidate(); statsTimer = nil
        session?.stop(); session = nil
    }

    /// "hpss://mac.ts.net" or "hpss://mac.ts.net:5900" -> (host, port).
    static func parseHPSS(_ url: String) -> (String, UInt16)? {
        guard let c = URLComponents(string: url), c.scheme?.lowercased() == "hpss", let h = c.host, !h.isEmpty else { return nil }
        return (h, UInt16(c.port ?? 5900))
    }
}
