import AVFoundation
import UIKit

/// One horizontal band of the desktop with its own H.264 or HEVC stream (port of
/// web/src/worker.ts). HEVC (4:2:0 or 4:4:4) is used when the host offers it and this
/// device decodes it in hardware (`DecoderCheck`).
final class Stripe {
    let layer = AVSampleBufferDisplayLayer()
    var waitingKey = true
    /// "h264", "hevc" or "hevc444", as the host confirmed (`{"t":"codec"}`).
    var codec = "h264" { didSet { if codec != oldValue { reset() } } }
    private var format: CMVideoFormatDescription?

    init(y: Int, height: Int, width: Int) {
        layer.frame = CGRect(x: 0, y: y, width: width, height: height)
        layer.videoGravity = .resize
    }

    func reset() {
        waitingKey = true
        format = nil
        layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    /// Decodes one Annex-B access unit. Returns false when the decoder needs a keyframe.
    func decode(_ data: Data) -> Bool {
        if codec != "h264" { return decodeHEVC(data) }
        var sps: Data?, pps: Data?
        var avcc = Data(capacity: data.count + 16)
        for nal in Stripe.nals(data) {
            switch nal.first! & 0x1f {
            case 7: sps = nal
            case 8: pps = nal
            case 9: break // access unit delimiter
            default:
                var n = UInt32(nal.count).bigEndian
                avcc.append(Data(bytes: &n, count: 4))
                avcc.append(nal)
            }
        }
        if let sps, let pps { format = Stripe.makeFormat(sps, pps) ?? format }
        guard let format, !avcc.isEmpty, let sb = Stripe.sample(avcc, format) else { return avcc.isEmpty }
        let r = layer.sampleBufferRenderer
        if r.status == .failed || r.requiresFlushToResumeDecoding { reset(); return false }
        r.enqueue(sb)
        return true
    }

    private func decodeHEVC(_ data: Data) -> Bool {
        var vps: Data?, sps: Data?, pps: Data?
        var avcc = Data(capacity: data.count + 16)
        for nal in Stripe.nals(data) {
            switch (nal.first! >> 1) & 0x3f {
            case 32: vps = nal
            case 33: sps = nal
            case 34: pps = nal
            case 35: break // access unit delimiter
            default:
                var n = UInt32(nal.count).bigEndian
                avcc.append(Data(bytes: &n, count: 4))
                avcc.append(nal)
            }
        }
        if let vps, let sps, let pps { format = Stripe.makeHEVCFormat(vps, sps, pps) ?? format }
        guard let format, !avcc.isEmpty, let sb = Stripe.sample(avcc, format) else { return avcc.isEmpty }
        let r = layer.sampleBufferRenderer
        if r.status == .failed || r.requiresFlushToResumeDecoding { reset(); return false }
        r.enqueue(sb)
        return true
    }

    static func makeHEVCFormat(_ vps: Data, _ sps: Data, _ pps: Data) -> CMVideoFormatDescription? {
        var fmt: CMVideoFormatDescription?
        vps.withUnsafeBytes { v in
            sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let ptrs = [v, s, p].map { $0.bindMemory(to: UInt8.self).baseAddress! }
                    _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: 3, parameterSetPointers: ptrs,
                        parameterSetSizes: [vps.count, sps.count, pps.count], nalUnitHeaderLength: 4,
                        extensions: nil, formatDescriptionOut: &fmt)
                }
            }
        }
        return fmt
    }

    static func nals(_ d: Data) -> [Data] {
        var out: [Data] = []
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            let n = b.count
            var i = 0, start = -1
            while i + 2 < n {
                if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                    if start >= 0 {
                        var end = i
                        while end > start, b[end - 1] == 0 { end -= 1 } // 4-byte start code / trailing zeros
                        if end > start { out.append(d.subdata(in: d.startIndex + start ..< d.startIndex + end)) }
                    }
                    i += 3
                    start = i
                } else { i += 1 }
            }
            if start >= 0, start < n { out.append(d.subdata(in: d.startIndex + start ..< d.startIndex + n)) }
        }
        return out
    }

    static func makeFormat(_ sps: Data, _ pps: Data) -> CMVideoFormatDescription? {
        var fmt: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        return fmt
    }

    static func sample(_ avcc: Data, _ format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var sb: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
            atts.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sb
    }
}

protocol SessionDelegate: AnyObject {
    /// `displays`/`display`: how many displays the host can stream and which one this is.
    func sessionHello(width: Int, height: Int, stripes: [Stripe], resizeScale: Double?, displays: Int, display: Int, os: String?)
    /// The host can put up a virtual display of our size (`vd`), and whether it shows one now.
    func sessionVirtualDisplay(available: Bool, active: Bool)
    func sessionCursor(_ image: CGImage?, hotspot: CGPoint)
    func sessionState(_ text: String?)
    /// The host refused the saved password, which is now forgotten.
    func sessionAuthFailed()
}

/// WebSocket connection to the voxl host. All callbacks arrive on the main queue.
// ponytail: decoding runs on the main queue; move to a serial queue if the UI stutters at 60fps.
final class Session: NSObject, URLSessionWebSocketDelegate {
    weak var delegate: SessionDelegate?
    let host: Host
    private(set) var connected = false
    private var task: URLSessionWebSocketTask?
    private var stripes: [Stripe] = []
    /// Codec the host confirmed for this connection.
    private(set) var codec = "h264"
    let audio = AudioPlayer()
    /// Desktop audio on (persisted; on by default).
    var audioOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "audioMuted") }
        set {
            UserDefaults.standard.set(!newValue, forKey: "audioMuted")
            send(newValue ? "au,1" : "au,0")
            if newValue { audio.start() } else { audio.stop() }
        }
    }
    private var reportedDisplay = false
    private var pings = 0, framesIn = 0, keysIn = 0
    private var pending: [UInt32: Int] = [:] // frame id -> parts still to arrive
    private var lastKeyRequest = Date.distantPast
    private var keyRetryQueued = false
    private var stopped = true
    private lazy var urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    /// Pasteboard generation already in sync with a host (set or sent by us). Kept across
    /// launches, so a copy made before connecting is sent, but an old one isn't re-sent.
    /// changeCount restarts at boot, so the saved one only counts for the same boot.
    private var pasteSeen: Int {
        get {
            let d = UserDefaults.standard
            return d.string(forKey: "pasteBoot") == Session.boot ? d.integer(forKey: "pasteSynced") : -1
        }
        set {
            UserDefaults.standard.set(Session.boot, forKey: "pasteBoot")
            UserDefaults.standard.set(newValue, forKey: "pasteSynced")
        }
    }

    private static let boot: String = {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return "\(tv.tv_sec)"
    }()
    private var observers: [NSObjectProtocol] = []

    init(host: Host) {
        self.host = host
        super.init()
        let nc = NotificationCenter.default
        for name in [UIPasteboard.changedNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sendPasteboard()
            })
        }
    }

    /// Sends the iPad's pasteboard to the host if it changed since we last synced. Only
    /// then is it read, so iOS asks for paste permission only when there is something new.
    func sendPasteboard() {
        let pb = UIPasteboard.general
        let gen = pb.changeCount
        guard connected, let task, gen != pasteSeen else { return }
        let msg: URLSessionWebSocketTask.Message
        if pb.hasStrings, let s = pb.string, !s.isEmpty {
            msg = .string("c,\(s)")
        } else if pb.hasImages, let png = pb.image?.pngData(), png.count < 15 << 20 {
            msg = .data(Data([0x11]) + png)
        } else {
            return
        }
        // Marked synced only once sent, so a failed send is retried on the next V.
        task.send(msg) { [weak self] err in
            guard err == nil else { return }
            DispatchQueue.main.async { self?.pasteSeen = gen }
        }
    }

    func start() {
        stopped = false
        let pw = Hosts.password(for: host.url)
        guard task == nil, let url = URL(string: host.url), let pw else {
            if pw == nil { delegate?.sessionState("No password saved") }
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(pw)", forHTTPHeaderField: "Authorization")
        let t = urlSession.webSocketTask(with: req)
        t.maximumMessageSize = 64 << 20
        task = t
        delegate?.sessionState("Connecting…")
        t.resume()
        receive(t)
    }

    func stop() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        dropped(retry: false)
    }

    /// Ends the session for good; URLSession keeps its delegate (this object) alive until invalidated.
    func close() {
        stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        urlSession.invalidateAndCancel()
    }

    /// Returns whether the message was queued (false while disconnected).
    @discardableResult
    func send(_ s: String) -> Bool {
        guard connected, let task else { return false }
        task.send(.string(s)) { _ in }
        return true
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure:
                if let r = t.response as? HTTPURLResponse, r.statusCode == 401 || r.statusCode == 403 {
                    // Forget the password so the host list asks for it again.
                    Hosts.setPassword(nil, for: self.host.url)
                    self.stop()
                    self.delegate?.sessionState("Wrong password")
                    self.delegate?.sessionAuthFailed()
                } else {
                    self.dropped(retry: true)
                }
            case .success(.data(let d)): self.binary(d); self.receive(t)
            case .success(.string(let s)): self.text(s); self.receive(t)
            case .success: self.receive(t)
            }
        }
    }

    private func dropped(retry: Bool) {
        task = nil
        connected = false
        audio.stop()
        reportedDisplay = false
        pending.removeAll()
        stripes.forEach { $0.reset() }
        guard retry, !stopped else { return }
        delegate?.sessionState("Reconnecting…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if let self, !self.stopped { self.start() }
        }
    }

    func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        guard t === task else { return }
        connected = true
        // Ask for the best codec this device decodes in hardware; the host answers with
        // the one it will send (H.264 if it offers nothing better).
        send("cd," + DecoderCheck.preferred.joined(separator: ","))
        send("cl,decoder check: " + DecoderCheck.result.detail)
        send("v,1")
        send(audioOn ? "au,1" : "au,0")
        if audioOn { audio.start() }
    }

    func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if t === task { dropped(retry: true) }
    }

    private func text(_ s: String) {
        guard let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let type = j["t"] as? String else { return }
        switch type {
        case "hello":
            let w = j["w"] as? Int ?? 0, h = j["h"] as? Int ?? 0
            let bands = (j["stripes"] as? [[Int]]) ?? [[0, h]]
            stripes.forEach { $0.layer.removeFromSuperlayer() }
            stripes = bands.map { Stripe(y: $0[0], height: $0[1], width: w) }
            stripes.forEach { $0.codec = codec }
            pending.removeAll()
            let scale = (j["resize"] as? [String: Any])?["scale"] as? Double
            delegate?.sessionState(nil)
            delegate?.sessionHello(width: w, height: h, stripes: stripes, resizeScale: scale,
                                   displays: j["displays"] as? Int ?? 1, display: j["display"] as? Int ?? 0,
                                   os: j["os"] as? String)
            delegate?.sessionVirtualDisplay(available: j["vd"] as? Bool ?? false, active: j["virtual"] as? Bool ?? false)
            sendPasteboard() // anything copied on the iPad while disconnected
        case "codec":
            codec = j["c"] as? String ?? "h264"
            stripes.forEach { $0.codec = codec }
            reportedDisplay = false
            requestKeyframe()
        case "ping":
            if let v = j["s"] { send("po,\(v)") }
            pings += 1
            if pings % 10 == 0 {
                Diagnostics.note("session", "url=\(host.url) codec=\(codec) frames=\(framesIn) keyframes=\(keysIn) audioOn=\(audioOn) audio packets=\(audio.packets) dropped=\(audio.dropped) failed=\(audio.failed)")
            }
        case "clip":
            if let d = j["d"] as? String {
                UIPasteboard.general.string = d
                pasteSeen = UIPasteboard.general.changeCount
            }
        case "close":
            stop()
            delegate?.sessionState("Closed by host. Tap to reconnect.")
        default: break
        }
    }

    private func binary(_ d: Data) {
        let b = [UInt8](d.prefix(16))
        guard let kind = b.first else { return }
        if kind == 0x01, b.count == 16 {
            let key = b[1] & 1 == 1
            framesIn += 1
            if key { keysIn += 1 }
            let frame = UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
            let idx = Int(b[10]), parts = max(Int(b[12]), 1)
            if idx < stripes.count {
                let st = stripes[idx]
                if key { st.waitingKey = false }
                if !st.waitingKey, !st.decode(d.dropFirst(16)) { st.waitingKey = true }
                if st.waitingKey { requestKeyframe() }
                if key, !reportedDisplay { reportedDisplay = true; checkDisplay(st) }
            }
            // A frame is acked once every stripe part arrived, decoded or not (same as the web worker).
            let left = (pending[frame] ?? parts) - 1
            if left <= 0 { pending[frame] = nil; send("a,\(frame)") } else { pending[frame] = left }
        } else if kind == 0x02, d.count > 1 {
            audio.enqueue(d.dropFirst())
        } else if kind == 0x04, d.count > 1, let img = UIImage(data: d.dropFirst()) {
            // Image copied on the host.
            UIPasteboard.general.image = img
            pasteSeen = UIPasteboard.general.changeCount
        } else if kind == 0x03, d.count >= 14 {
            let u16 = { (o: Int) in Int(b[o]) << 8 | Int(b[o + 1]) }
            let w = u16(2), h = u16(4)
            let px = d.dropFirst(14)
            guard w > 0, h > 0, px.count >= w * h * 4,
                  let provider = CGDataProvider(data: Data(px.prefix(w * h * 4)) as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { delegate?.sessionCursor(nil, hotspot: .zero); return }
            delegate?.sessionCursor(img, hotspot: CGPoint(x: u16(6), y: u16(8)))
        }
    }

    /// A moment after the first keyframe: did the display layer really show it? Reported
    /// to the host's log; a 4:4:4 stream it can't show is not asked for again.
    private func checkDisplay(_ st: Stripe) {
        let codec = self.codec
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.connected, self.codec == codec else { return }
            let r = st.layer.sampleBufferRenderer
            var fmt = "?"
            if let pb = r.displayedPixelBuffer() { fmt = DecoderCheck.fourcc(CVPixelBufferGetPixelFormatType(pb)) + " \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))" }
            let failed = r.status == .failed
            self.send("cl,display \(codec): status=\(failed ? "failed" : "ok") shown=\(fmt) err=\(r.error.map { "\($0)" } ?? "-")")
            Diagnostics.note("display", "\(codec) failed=\(failed) shown=\(fmt)")
            if codec == "hevc444" && failed {
                UserDefaults.standard.set(true, forKey: "hevc444Broken")
                self.send("cd," + DecoderCheck.preferred.joined(separator: ","))
            }
        }
    }

    /// Asks the host for keyframes, at most every 500 ms. A request inside that window is
    /// sent when it ends, so a stripe that only became ready meanwhile is not left blank
    /// on a desktop that never changes.
    private func requestKeyframe() {
        let wait = 0.5 - Date().timeIntervalSince(lastKeyRequest)
        if wait > 0 {
            if !keyRetryQueued {
                keyRetryQueued = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self else { return }
                    self.keyRetryQueued = false
                    if self.stripes.contains(where: { $0.waitingKey }) { self.requestKeyframe() }
                }
            }
            return
        }
        lastKeyRequest = Date()
        send("kf")
    }
}
