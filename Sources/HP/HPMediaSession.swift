import Foundation
import CoreVideo
import Darwin

/// Native Apple HPSS media + control session.
///
/// Brings up the Screen Sharing media path the way the reference client does:
///   bind UDP ctrl(5900)/video(5901) → Apple two-TCP warmup → RFB+SRP+enc1103
///   handshake → MediaStreamConfiguration offer → drain the session-start burst
///   → SRTP video → HEVC NAL reassembly → VideoToolbox → CVPixelBuffer callback.
///
/// RTCP (RR/SR/legacy-FIR) is sent back on the muxed video port to sustain the
/// stream and pull fresh IDRs. Requests tilesPerFrame=1 so each frame is a
/// single self-contained HEVC picture (no cross-tile composition).
///
/// Reconnects with exponential backoff (1s→30s) so a dropped/stalled host is
/// retried gently instead of hammered — rapid reconnects are what wedge
/// screensharingd.
final class HPMediaSession {
    struct Stats { var frames = 0; var firstFrameMs: Double? = nil; var fps: Double = 0 }

    let host: String
    let port: UInt16
    let username: String
    let password: String
    var onFrame: ((CVPixelBuffer, Int, Int) -> Void)?
    var onLog: ((String) -> Void)?
    var onCanvas: ((Int, Int) -> Void)?

    private(set) var stats = Stats()
    private var running = false
    private let decoder = HPVTDecoder()
    private var haveParams = false

    // Live control channel (enc1103) kept for RFB input.
    private(set) var controlSocket: HPSocket?
    private(set) var cipher: HPStreamCipher?
    private(set) var canvasW = 0, canvasH = 0

    private let rtcpSSRC: UInt32 = 0x1234_5678
    private var lastRTCP = Date.distantPast

    init(host: String, port: UInt16 = 5900, username: String = "", password: String) {
        self.host = host; self.port = port; self.username = username; self.password = password
    }

    func start() {
        guard !running else { return }
        running = true
        Thread.detachNewThread { [weak self] in self?.reconnectLoop() }
    }

    func stop() {
        running = false
        controlSocket?.close(); controlSocket = nil
    }

    // MARK: reconnect with backoff

    private func reconnectLoop() {
        var delay: Double = 1.0
        while running {
            let t0 = Date()
            do {
                try runOnce()
            } catch {
                log("session error: \(error)")
            }
            controlSocket?.close(); controlSocket = nil
            haveParams = false
            decoder.teardown()
            if !running { break }
            // If the session held for a while, reset backoff; otherwise grow it.
            if Date().timeIntervalSince(t0) > 20 { delay = 1.0 }
            log(String(format: "reconnecting in %.0fs", delay))
            let step = 0.25
            var waited = 0.0
            while running && waited < delay { Thread.sleep(forTimeInterval: step); waited += step }
            delay = min(delay * 2, 30)
        }
    }

    // MARK: one connection cycle

    private func runOnce() throws {
        let ctrlFD = try bindUDP(self.port)                 // audio + its RTCP (muxed)
        let videoFD = try bindUDP(self.port + 1)            // video + its RTCP (muxed)
        defer { Darwin.close(ctrlFD); Darwin.close(videoFD) }

        try HPRFB.warmupTCP(host: host, port: port)         // Apple TCP #1
        log("warmup done; handshaking")

        let (sock, hs) = try HPRFB.connectAndAuth(host: host, port: port,
                                                  username: username, password: password)
        controlSocket = sock
        let neg = try HPNeg.negotiate(sock, ecbKey: hs.ecbKey)
        cipher = neg.cipher
        canvasW = neg.canvasW; canvasH = neg.canvasH
        onCanvas?(canvasW, canvasH)
        log("negotiated enc1103; canvas \(canvasW)x\(canvasH) tiles=\(neg.tiles)")

        let videoDec = HPSRTPDecryptor(blob: neg.videoKeyS)
        let rtcpSend = HPSRTCP(blob: neg.videoKeyV)

        // server symmetric-sends to the ports we just bound; prime the path with
        // an RR + legacy FIR so it emits a session-start IDR burst.
        sendVideoRTCP(videoFD, rtcpSend, kickoff: true)

        // Drain the burst (param sets + first IDR). Must NOT send FBU here.
        let burst = drainBurst(videoFD, maxSeconds: 2.5)
        log("burst: \(burst.count) packets")
        var groups = RTPGrouper()
        for pkt in burst { feed(pkt, videoDec: videoDec, grouper: &groups) }

        // steady-state receive loop
        var buf = [UInt8](repeating: 0, count: 65536)
        setRecvTimeout(videoFD, seconds: 0.5)
        let startedAt = Date()
        var lastFrameCountTick = Date()
        var framesAtTick = 0
        while running {
            let n = Darwin.recv(videoFD, &buf, buf.count, 0)
            if n > 0 { feed(Data(buf[0..<n]), videoDec: videoDec, grouper: &groups) }
            // periodic RTCP so AVConference doesn't time us out (~every 1s)
            if Date().timeIntervalSince(lastRTCP) > 1.0 {
                sendVideoRTCP(videoFD, rtcpSend, kickoff: false)
                lastRTCP = Date()
            }
            // fps sample every 2s
            if Date().timeIntervalSince(lastFrameCountTick) > 2.0 {
                let df = stats.frames - framesAtTick
                stats.fps = Double(df) / Date().timeIntervalSince(lastFrameCountTick)
                framesAtTick = stats.frames; lastFrameCountTick = Date()
            }
            _ = startedAt
        }
    }

    // MARK: RTP → access units → decode

    /// Groups RTP payloads by timestamp; flushes a group on timestamp change or
    /// marker bit, reassembles NALUs, pulls param sets, decodes VCL frames.
    private struct RTPGrouper { var ts: UInt32? = nil; var payloads: [Data] = [] }

    private func feed(_ pkt: Data, videoDec: HPSRTPDecryptor, grouper: inout RTPGrouper) {
        guard pkt.count >= 2 else { return }
        let pt = pkt[pkt.startIndex + 1] & 0x7f
        if pt >= 72 && pt <= 76 { return }          // RTCP (muxed SR/RR/etc.) — ignore for now
        guard let (hdr, payload) = videoDec.decrypt(pkt), payload.count >= 2 else { return }
        let h = [UInt8](hdr)
        let marker = (h[1] & 0x80) != 0
        let ts = UInt32(h[4]) << 24 | UInt32(h[5]) << 16 | UInt32(h[6]) << 8 | UInt32(h[7])
        if let cur = grouper.ts, cur != ts {
            flush(&grouper)
        }
        grouper.ts = ts
        grouper.payloads.append(payload)
        if marker { flush(&grouper) }
    }

    private var vps = Data(), sps = Data(), pps = Data()

    private func flush(_ grouper: inout RTPGrouper) {
        defer { grouper.payloads.removeAll(keepingCapacity: true); grouper.ts = nil }
        guard !grouper.payloads.isEmpty else { return }
        let nalus = HPNALU.reassembleGroup(grouper.payloads)
        var vcl = Data()
        for nalu in nalus {
            let t = HPNALU.nalType(nalu)
            switch t {
            case HPNALU.NAL_VPS: vps = nalu
            case HPNALU.NAL_SPS: sps = nalu
            case HPNALU.NAL_PPS: pps = nalu
            default:
                if t >= 0 && t <= 31 {               // VCL NAL
                    var len = UInt32(nalu.count).bigEndian
                    withUnsafeBytes(of: &len) { vcl.append(contentsOf: $0) }
                    vcl.append(nalu)
                }
            }
        }
        if !haveParams, !vps.isEmpty, !sps.isEmpty, !pps.isEmpty {
            haveParams = decoder.setParams(vps: vps, sps: sps, pps: pps)
            log(haveParams ? "VT session up (hw=\(decoder.usingHardware))" : "VT setParams failed")
        }
        guard haveParams, !vcl.isEmpty else { return }
        if let dec = decoder.decode(accessUnit: vcl) {
            if stats.frames == 0 { stats.firstFrameMs = Date().timeIntervalSince1970 * 1000 }
            stats.frames += 1
            onFrame?(dec.pixelBuffer, dec.width, dec.height)
        }
    }

    // MARK: RTCP out

    private func sendVideoRTCP(_ fd: Int32, _ enc: HPSRTCP, kickoff: Bool) {
        var compound = HPRTCP.emptySR(rtcpSSRC)
        compound += HPRTCP.rr(sender: rtcpSSRC, sources: [])
        sendTo(fd, port: port + 1, enc.protect(compound))
        if kickoff {
            // legacy FIR is the keyframe request Apple's encoder honours best
            sendTo(fd, port: port + 1, enc.protect(HPRTCP.firLegacy(rtcpSSRC)))
        }
    }

    // MARK: UDP helpers

    private func drainBurst(_ fd: Int32, maxSeconds: Double) -> [Data] {
        var out: [Data] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        setRecvTimeout(fd, seconds: 0.05)
        let deadline = Date().addingTimeInterval(maxSeconds)
        while Date() < deadline {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n > 0 { out.append(Data(buf[0..<n])) }
            else if !out.isEmpty { break }           // gap after some packets = burst done
        }
        return out
    }

    private func bindUDP(_ p: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Err.sock("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var rb: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rb, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = p.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { Darwin.close(fd); throw Err.sock("bind \(p)") }
        return fd
    }

    private func sendTo(_ fd: Int32, port p: UInt16, _ data: Data) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = p.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func setRecvTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: RFB input over the enc1103 control channel

    private let inputLock = NSLock()

    /// RFB PointerEvent (msg 5): buttonMask + x/y in canvas pixels.
    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        guard let s = controlSocket, let c = cipher else { return }
        let cx = UInt16(clamping: x), cy = UInt16(clamping: y)
        var d = Data([5, buttons, UInt8(cx >> 8), UInt8(cx & 0xff), UInt8(cy >> 8), UInt8(cy & 0xff)])
        inputLock.lock(); defer { inputLock.unlock() }
        try? s.send(c.encrypt(d))
        _ = d
    }

    /// RFB KeyEvent (msg 4): down flag + X11 keysym.
    func sendKey(keysym: UInt32, down: Bool) {
        guard let s = controlSocket, let c = cipher else { return }
        let d = Data([4, down ? 1 : 0, 0, 0,
                      UInt8(keysym >> 24 & 0xff), UInt8(keysym >> 16 & 0xff),
                      UInt8(keysym >> 8 & 0xff), UInt8(keysym & 0xff)])
        inputLock.lock(); defer { inputLock.unlock() }
        try? s.send(c.encrypt(d))
    }

    private func log(_ m: String) { onLog?("[hpmedia] " + m) }
    enum Err: Error { case sock(String) }
}
