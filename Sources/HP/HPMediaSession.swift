import Foundation
import CoreVideo
import Darwin

/// Native Apple HPSS media + control session.
///
/// Media path, matching what screensharingd expects from a viewer:
///   bind UDP ctrl(5900)/video(5901) → Apple TCP warmup → RFB+SRP+enc1103 →
///   0x1c MediaStreamConfiguration offer → SRTP video on :5901 (one SSRC per
///   tile, `tilesPerFrame` consecutive SSRCs per group) and AAC-ELD audio +
///   SRTCP on the rtcp-muxed ctrl port :5900.
///
/// Media endpoint obligations (missing any of these stalls the host after the
/// session-start burst):
///   * every RTCP packet we send carries OUR negotiated video SSRC (the offer's
///     session id) — AVConference ignores RTCP from any other SSRC;
///   * RR/SR, FIR and PLI go to the host's ctrl port (5900), not 5901;
///   * a PT=101 SRTP keepalive (our audio SSRC, audio key) every 0.5 s;
///   * the enc1103 TCP channel keeps being read so the host never blocks on it.
///
/// Same-host testing (iOS Simulator / macOS harness talking to 127.0.0.1): the
/// viewer's UDP ports are symmetric with the host's own 5900/5901, so a
/// wildcard bind steals the host's sockets. We bind UDP and the TCP source to
/// a different local interface address so the kernel can tell the two apart.
final class HPMediaSession {
    struct Stats {
        var frames = 0                 // composited canvas frames
        var tileFrames = 0             // per-tile decoded pictures
        var fps: Double = 0            // canvas fps (2 s window)
        var firstFrameMs: Double? = nil
        var connectToFirstFrameMs: Double? = nil
        var latencyMs: Double? = nil   // host capture (RTP ts via SR) → composited, ms, smoothed
        var pipelineMs: Double? = nil  // first RTP packet of a frame → composited, ms, smoothed
        var videoPPS: Double = 0
        var videoKbps: Double = 0
        var audioPPS: Double = 0
        var audioFrames = 0
        var audioPackets = 0
        var audioNonSilentAUs = 0      // AUs larger than Apple's 4-byte silence AU
        var audioRMS: Float = 0
        var audioPeakRMS: Float = 0
        var canvasW = 0, canvasH = 0, tiles = 0
        var ssrcGroup: [UInt32] = []
        var adoptions = 0
        var firs = 0
        var decodeErrors = 0
        var bindIP = ""
        var rtpClockHz: Double = 0     // measured tile-0 RTP clock (sanity check for latencyMs)
    }

    let host: String
    let port: UInt16
    let username: String
    let password: String
    /// Local IPv4 for UDP + TCP source. nil = auto (only overridden for same-host tests).
    var localBindIP: String?
    var audioEnabled = true
    var audioPlayback = true
    var onFrame: ((CVPixelBuffer, Int, Int) -> Void)?
    var onLog: ((String) -> Void)?
    var onCanvas: ((Int, Int) -> Void)?
    /// Each failed connection attempt (auth, unreachable, no stream), for the UI.
    var onError: ((Error) -> Void)?

    private let statsLock = NSLock()
    private var _stats = Stats()
    var stats: Stats { statsLock.lock(); defer { statsLock.unlock() }; return _stats }
    private func updateStats(_ f: (inout Stats) -> Void) { statsLock.lock(); f(&_stats); statsLock.unlock() }

    private var running = false
    private var generation = 0

    // Live control channel (enc1103) kept for RFB input.
    private(set) var controlSocket: HPSocket?
    private(set) var cipher: HPStreamCipher?
    private(set) var canvasW = 0, canvasH = 0

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
        player?.stop()
    }

    // MARK: reconnect with backoff (rapid reconnects wedge screensharingd)

    private func reconnectLoop() {
        var delay: Double = 1.0
        while running {
            let t0 = Date()
            do { try runOnce() } catch { log("session error: \(error)"); onError?(error) }
            controlSocket?.close(); controlSocket = nil
            if !running { break }
            if Date().timeIntervalSince(t0) > 20 { delay = 1.0 }
            log(String(format: "reconnecting in %.0fs", delay))
            var waited = 0.0
            while running && waited < delay { Thread.sleep(forTimeInterval: 0.25); waited += 0.25 }
            delay = min(delay * 2, 30)
        }
    }

    // MARK: per-connection state

    private final class Tile {
        let ssrc: UInt32
        var index: Int
        var ts: UInt32?
        var payloads: [Data] = []
        var firstArrival: Double = 0
        var latest: CVPixelBuffer?
        var lastDecodeError: Double = 0
        var lastFIR: Double = 0
        var lastDecode: Double = 0
        var maxSeq: UInt16 = 0, roc: UInt32 = 0, seqInit = false
        init(ssrc: UInt32, index: Int) { self.ssrc = ssrc; self.index = index }
    }

    private struct Conn {
        let gen: Int
        let ctrlFD: Int32, videoFD: Int32
        let hostAddr: in_addr_t
        let ourVideoSSRC: UInt32
        let videoDec: HPSRTPDecryptor
        let audioDec: HPSRTPDecryptor
        let srtcpDec: HPSRTCP
        let srtcpEnc: HPSRTCP
        let audioEnc: HPSRTPEncryptor
        let tilesWanted: Int
    }

    private let mediaLock = NSLock()           // guards tiles / group / sr / compose state
    private var tiles: [UInt32: Tile] = [:]
    // The tiles of one group are ONE HEVC stream sharing a single DPB: Apple
    // IDRs tile 0 only and tiles 1-3 reference across tiles, so every tile's
    // VCL NALs go through one VT session in arrival order (one NAL per sample),
    // and each decoded picture is routed back to the tile it came from.
    private let decoder = HPVTDecoder()
    private var vps = Data(), sps = Data()
    private var ppsPool: [Int: Data] = [:]
    private var haveParams = false
    private var synced = false          // fed an IRAP since the session was (re)built
    private var group: [UInt32] = []
    private var blacklist = Set<UInt32>()
    private var candidateCounts: [UInt32: Int] = [:]
    private var lastPublish: Double = 0
    private var lastAdopt: Double = 0
    private var srMap: [UInt32: (wall: Double, rtp: UInt32)] = [:]
    private var composeTS: UInt32?
    private var composeDone = Set<Int>()
    private var composeFirstArrival: Double = 0
    private var pool: CVPixelBufferPool?
    private var poolDims = (0, 0)
    private var tileHeight = 0
    private var firSeq: UInt8 = 0
    private var audioDecoder: HPAudioDecoder?
    private var player: HPAudioPlayer?
    private var connectStart: Double = 0
    private var rtcpUndecryptable = 0
    private var rtpClockRef: (t: Double, ts: UInt32)?

    // rate counters
    private var rxVideo = 0, rxVideoBytes = 0, rxAudio = 0, framesAtTick = 0
    private var lastRateTick: Double = 0

    private static func now() -> Double { Date().timeIntervalSince1970 }
    /// Apple's HP video RTP clock (measured on the wire: ~24 kHz, not the usual 90 kHz).
    static let videoRTPClock = 24_000.0

    // MARK: one connection cycle

    private func runOnce() throws {
        generation += 1
        let gen = generation
        resetMediaState()
        connectStart = Self.now()

        let bindIP = localBindIP ?? Self.autoBindIP(for: host)
        updateStats { $0.bindIP = bindIP ?? "0.0.0.0" }
        if let bindIP { log("same-host target: binding UDP + TCP source to \(bindIP)") }
        let ctrlFD = try bindUDP(port, ip: bindIP)           // audio + all RTCP (muxed)
        let videoFD = try bindUDP(port + 1, ip: bindIP)      // video (+ LTR acks)
        defer { Darwin.close(ctrlFD); Darwin.close(videoFD) }

        try HPRFB.warmupTCP(host: host, port: port, sourceIP: bindIP)
        log("warmup done; handshaking")
        let (sock, _hs) = try HPRFB.connectAndAuth(host: host, port: port, username: username,
                                                   password: password, sourceIP: bindIP)
        controlSocket = sock
        let neg = try HPNeg.negotiate(sock, ecbKey: _hs.ecbKey)
        cipher = neg.cipher
        canvasW = neg.canvasW; canvasH = neg.canvasH
        let nTiles = max(1, neg.tiles == 0 ? HPOffers.tilesPerFrame : neg.tiles)
        updateStats { $0.canvasW = neg.canvasW; $0.canvasH = neg.canvasH; $0.tiles = nTiles }
        onCanvas?(canvasW, canvasH)
        log(String(format: "negotiated enc1103; canvas %dx%d tiles=%d ourSSRC v=0x%08x a=0x%08x",
                   canvasW, canvasH, nTiles, neg.videoSSRC, neg.audioSSRC))
        guard canvasW > 0, canvasH > 0 else { throw Err.sock("degenerate canvas (no 0x1c answer)") }

        let conn = Conn(gen: gen, ctrlFD: ctrlFD, videoFD: videoFD, hostAddr: Self.ipv4(host),
                        ourVideoSSRC: neg.videoSSRC,
                        videoDec: HPSRTPDecryptor(blob: neg.videoKeyS),
                        audioDec: HPSRTPDecryptor(blob: neg.audioKeyS),
                        srtcpDec: HPSRTCP(blob: neg.videoKeyS),
                        srtcpEnc: HPSRTCP(blob: neg.videoKeyV),
                        audioEnc: HPSRTPEncryptor(blob: neg.audioKeyV, ssrc: neg.audioSSRC),
                        tilesWanted: nTiles)
        if audioEnabled {
            audioDecoder = HPAudioDecoder()
            if audioDecoder == nil { log("AAC-ELD decoder unavailable") }
        }

        var tcpAlive = true
        let threadsDone = DispatchGroup()
        threadsDone.enter()
        Thread.detachNewThread { [weak self] in self?.ctrlLoop(conn); threadsDone.leave() }
        threadsDone.enter()
        Thread.detachNewThread { [weak self] in self?.txLoop(conn); threadsDone.leave() }
        threadsDone.enter()
        Thread.detachNewThread { [weak self] in
            // Keep reading the enc1103 TCP channel (cursor, layout, clipboard…)
            // so the host's send buffer never fills; detect a closed session.
            while let self, self.running, self.generation == gen {
                guard let s = self.controlSocket else { break }
                let r = s.recvSomeStatus(65536)
                if r < 0 { break }          // closed / hard error
            }
            tcpAlive = false
            threadsDone.leave()
        }
        defer { generation += 1; controlSocket?.shutdownBoth(); threadsDone.wait() }

        // video receive loop (this thread)
        var buf = [UInt8](repeating: 0, count: 65536)
        setRecvTimeout(videoFD, seconds: 0.25)
        lastRateTick = Self.now()
        while running && tcpAlive {
            let n = Darwin.recv(videoFD, &buf, buf.count, 0)
            if n > 0 { handleVideo(Data(buf[0..<n]), conn) }
        }
        if running && !tcpAlive { throw Err.sock("control channel closed by host") }
    }

    private func resetMediaState() {
        mediaLock.lock()
        tiles.removeAll(); group.removeAll(); blacklist.removeAll(); candidateCounts.removeAll()
        srMap.removeAll(); composeTS = nil; composeDone.removeAll(); tileHeight = 0
        decoder.teardown(); vps = Data(); sps = Data(); ppsPool.removeAll(); haveParams = false; synced = false
        lastPublish = 0; lastAdopt = 0; rtpClockRef = nil
        mediaLock.unlock()
        rxVideo = 0; rxVideoBytes = 0; rxAudio = 0; framesAtTick = 0
    }

    // MARK: video

    private func handleVideo(_ pkt: Data, _ c: Conn) {
        guard pkt.count >= 12 else { return }
        let b1 = pkt[pkt.startIndex + 1] & 0x7f
        if b1 >= 64 && b1 <= 95 {                    // RTCP muxed on the video port
            if let d = c.srtcpDec.unprotect(pkt) { noteSR(d) }
            return
        }
        rxVideo += 1; rxVideoBytes += pkt.count
        let p = pkt.startIndex
        let ssrc = UInt32(pkt[p+8]) << 24 | UInt32(pkt[p+9]) << 16 | UInt32(pkt[p+10]) << 8 | UInt32(pkt[p+11])
        let now = Self.now()

        mediaLock.lock()
        var tile = tiles[ssrc]
        if tile == nil {
            candidateCounts[ssrc, default: 0] += 1
            maybeAdopt(c, now: now)
            tile = tiles[ssrc]
        }
        mediaLock.unlock()
        guard let tile else { return }

        guard let (hdr, payload) = c.videoDec.decrypt(pkt), payload.count >= 2 else { return }
        let h = [UInt8](hdr)
        let seq = UInt16(h[2]) << 8 | UInt16(h[3])
        if !tile.seqInit { tile.maxSeq = seq; tile.seqInit = true }
        else if seq &- tile.maxSeq < 0x8000 && seq != tile.maxSeq {
            if seq < tile.maxSeq { tile.roc &+= 1 }
            tile.maxSeq = seq
        }
        let marker = (h[1] & 0x80) != 0
        let ts = UInt32(h[4]) << 24 | UInt32(h[5]) << 16 | UInt32(h[6]) << 8 | UInt32(h[7])
        if let cur = tile.ts, cur != ts { flush(tile, c) }
        if tile.payloads.isEmpty { tile.firstArrival = now }
        tile.ts = ts
        tile.payloads.append(payload)
        if marker { flush(tile, c) }
        tickRates(now)
    }

    /// Adopt the newest complete run of `tilesWanted` consecutive SSRCs once the
    /// current group has gone quiet (Apple rotates groups during session start
    /// and may double-publish; never flip back to an abandoned group).
    private func maybeAdopt(_ c: Conn, now: Double) {
        if !group.isEmpty && now - lastPublish < 1.0 { return }
        if !group.isEmpty && now - lastAdopt < 1.0 { return }
        let cands = candidateCounts.filter { $0.value >= 3 && !blacklist.contains($0.key) }.keys.sorted()
        guard cands.count >= c.tilesWanted else { return }
        var chosen: [UInt32]?
        var run: [UInt32] = []
        for s in cands {
            if let last = run.last, s &- last == 1 { run.append(s) } else { run = [s] }
            if run.count == c.tilesWanted { chosen = run }      // keep scanning: prefer the highest run
        }
        guard let chosen, chosen != group else { return }
        blacklist.formUnion(group)
        for s in group { tiles[s] = nil }
        group = chosen
        for (i, s) in chosen.enumerated() { tiles[s] = Tile(ssrc: s, index: i); candidateCounts[s] = nil }
        lastAdopt = now
        lastPublish = now          // grace period before re-adopting
        synced = false             // wait for the new group's tile-0 IDR
        composeTS = nil; composeDone.removeAll()
        updateStats { $0.ssrcGroup = chosen; $0.adoptions += 1 }
        log("adopted SSRC group " + chosen.map { String(format: "0x%08x", $0) }.joined(separator: ","))
        for t in chosen.compactMap({ tiles[$0] }) { requestKeyframe(t, c, now: now, force: true) }
    }

    private func flush(_ tile: Tile, _ c: Conn) {
        defer { tile.payloads.removeAll(keepingCapacity: true); tile.ts = nil }
        guard !tile.payloads.isEmpty, let ts = tile.ts else { return }
        let nalus = HPNALU.reassembleGroup(tile.payloads)
        let now = Self.now()
        var newParams = false
        for nalu in nalus {
            switch HPNALU.nalType(nalu) {
            case HPNALU.NAL_VPS: if nalu != vps { vps = nalu; newParams = true }
            case HPNALU.NAL_SPS: if nalu != sps { sps = nalu; newParams = true }
            case HPNALU.NAL_PPS:
                let id = HPNALU.ppsID(nalu)
                if ppsPool[id] != nalu { ppsPool[id] = nalu; newParams = true }
            default: break
            }
        }
        if newParams, !vps.isEmpty, !sps.isEmpty, !ppsPool.isEmpty {
            let pps = ppsPool.keys.sorted().compactMap { ppsPool[$0] }
            haveParams = decoder.setParams(vps: vps, sps: sps, ppsList: pps, outputFormat: kCVPixelFormatType_32BGRA)
            synced = false
            log("VT session \(haveParams ? "up" : "FAILED") (pps=\(pps.count)) hw=\(decoder.usingHardware)")
        }
        for nalu in nalus {
            let t = HPNALU.nalType(nalu)
            guard t >= 0 && t <= 31 else { continue }        // VCL only; params live in the format desc
            if t >= 16 && t <= 23 { synced = true }
            guard haveParams, synced else {
                if let t0 = group.first.flatMap({ tiles[$0] }) { requestKeyframe(t0, c, now: now) }
                continue
            }
            var au = Data(capacity: nalu.count + 4)
            var len = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &len) { au.append(contentsOf: $0) }
            au.append(nalu)
            guard let dec = decoder.decode(accessUnit: au) else {
                updateStats { $0.decodeErrors += 1 }
                if now - tile.lastDecodeError > 0.5 { tile.lastDecodeError = now; requestKeyframe(tile, c, now: now) }
                continue
            }
            tile.latest = dec.pixelBuffer
            tile.lastDecode = now
            updateStats { $0.tileFrames += 1 }
            compose(tile: tile, ts: ts, firstArrival: tile.firstArrival, c)
        }
    }

    private func requestKeyframe(_ tile: Tile, _ c: Conn, now: Double, force: Bool = false) {
        if !force && now - tile.lastFIR < 0.5 { return }
        tile.lastFIR = now
        firSeq &+= 1
        let pkt = HPRTCP.keyframeRequest(sender: c.ourVideoSSRC, target: tile.ssrc, seq: firSeq)
        sendTo(c.ctrlFD, addr: c.hostAddr, port: port, c.srtcpEnc.protect(pkt))
        updateStats { $0.firs += 1 }
    }

    // MARK: composition (horizontal stripes, CTU-padded tile height)

    private func compose(tile: Tile, ts: UInt32, firstArrival: Double, _ c: Conn) {
        // Apple emits a frame's tiles round-robin (0,1,2,3): publish a canvas
        // when the last tile lands, or early if a tile repeats (one was lost).
        mediaLock.lock()
        if composeDone.contains(tile.index) { composeDone.removeAll(); composeFirstArrival = firstArrival }
        if composeDone.isEmpty { composeFirstArrival = firstArrival }
        composeDone.insert(tile.index)
        if tile.index == 0 { composeTS = ts }
        composeFirstArrival = min(composeFirstArrival, firstArrival)
        lastPublish = Self.now()
        let complete = tile.index == group.count - 1 || composeDone.count >= group.count
        if complete { composeDone.removeAll() }
        let parts = group.compactMap { tiles[$0] }.compactMap { t in t.latest.map { (t.index, $0) } }
        let fa = composeFirstArrival
        // Host SRs arrive for the tile-0 SSRC; host and Simulator share one
        // clock, so (SR wall, SR rtp) maps tile-0's RTP ts to capture time.
        let sr = group.first.flatMap { srMap[$0] }
        let ts0 = composeTS ?? ts
        mediaLock.unlock()
        guard complete, !parts.isEmpty else { return }

        let w = canvasW, h = canvasH
        if pool == nil || poolDims != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                          kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
            pool = p; poolDims = (w, h)
        }
        guard let pool else { return }
        var outPB: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outPB) == kCVReturnSuccess,
              let out = outPB else { return }
        CVPixelBufferLockBaseAddress(out, [])
        let dst = CVPixelBufferGetBaseAddress(out)!
        let dstStride = CVPixelBufferGetBytesPerRow(out)
        for (idx, pb) in parts {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let th = CVPixelBufferGetHeight(pb), tw = CVPixelBufferGetWidth(pb)
            if tileHeight == 0 { tileHeight = th }
            let y0 = idx * tileHeight
            let rows = max(0, min(th, h - y0))
            let src = CVPixelBufferGetBaseAddress(pb)!
            let srcStride = CVPixelBufferGetBytesPerRow(pb)
            let rowBytes = min(tw, w) * 4
            for r in 0..<rows { memcpy(dst + (y0 + r) * dstStride, src + r * srcStride, rowBytes) }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        CVPixelBufferUnlockBaseAddress(out, [])

        let now = Self.now()
        let pipe = (now - fa) * 1000
        if let f = rtpClockRef {
            let dt = now - f.t
            if dt > 2 { let hz = Double(ts0 &- f.ts) / dt; updateStats { $0.rtpClockHz = hz } }
        } else { rtpClockRef = (now, ts0) }
        var lat: Double? = nil
        if let sr {
            let dt = Double(Int32(bitPattern: ts0 &- sr.rtp)) / Self.videoRTPClock
            let l = (now - (sr.wall + dt)) * 1000
            if l > -100 && l < 5000 { lat = l }
        }
        updateStats { s in
            s.frames += 1
            if s.firstFrameMs == nil { s.firstFrameMs = now * 1000; s.connectToFirstFrameMs = (now - self.connectStart) * 1000 }
            s.pipelineMs = s.pipelineMs.map { $0 * 0.9 + pipe * 0.1 } ?? pipe
            if let lat { s.latencyMs = s.latencyMs.map { $0 * 0.9 + lat * 0.1 } ?? lat }
        }
        onFrame?(out, w, h)
    }

    private func tickRates(_ now: Double) {
        let dt = now - lastRateTick
        guard dt >= 2.0 else { return }
        let f = stats.frames
        let ap = rxAudio
        let vp = rxVideo, vb = rxVideoBytes
        updateStats { s in
            s.fps = Double(f - self.framesAtTick) / dt
            s.videoPPS = Double(vp) / dt
            s.videoKbps = Double(vb) * 8 / dt / 1000
            s.audioPPS = Double(ap) / dt
        }
        framesAtTick = f; rxVideo = 0; rxVideoBytes = 0; rxAudio = 0
        lastRateTick = now
    }

    // MARK: ctrl port: audio RTP + SRTCP from the host

    private func ctrlLoop(_ c: Conn) {
        var buf = [UInt8](repeating: 0, count: 65536)
        setRecvTimeout(c.ctrlFD, seconds: 0.25)
        while running && generation == c.gen {
            let n = Darwin.recv(c.ctrlFD, &buf, buf.count, 0)
            guard n >= 2 else { continue }
            let pkt = Data(buf[0..<n])
            let pt = buf[1] & 0x7f
            if (buf[0] & 0xc0) == 0x80 && !(pt >= 72 && pt <= 79) {      // RTP (not RTCP 200..207)
                rxAudio += 1
                guard audioEnabled, let (_, payload) = c.audioDec.decrypt(pkt), let dec = audioDecoder else { continue }
                let loud = payload.count > 4 && payload.contains { $0 != 0 }
                updateStats { $0.audioPackets += 1; if loud { $0.audioNonSilentAUs += 1 } }
                if let pcm = dec.decode(payload) {
                    // Mute can flip mid-session; the player starts on first unmuted audio.
                    if audioPlayback {
                        if player == nil { player = HPAudioPlayer(); player?.start() }
                        player?.play(interleaved: pcm)
                    }
                    let fr = dec.decodedFrames, rms = dec.lastRMS, pk = dec.peakRMS
                    updateStats { $0.audioFrames = fr; $0.audioRMS = rms; $0.audioPeakRMS = pk }
                }
            } else if let d = c.srtcpDec.unprotect(pkt) {
                noteSR(d)
            } else {
                rtcpUndecryptable += 1
                if rtcpUndecryptable == 1 { log("ctrl RTCP not decryptable with video key S (len \(n), pt \(buf[1]))") }
            }
        }
    }

    private func noteSR(_ d: Data) {
        let srs = HPRTCP.senderReports(d)
        guard !srs.isEmpty else { return }
        mediaLock.lock()
        for s in srs {
            if srMap[s.ssrc] == nil { log(String(format: "host SR ssrc=0x%08x wall=%.3f rtp=%u (now %.3f)", s.ssrc, s.wall, s.rtp, Self.now())) }
            srMap[s.ssrc] = (s.wall, s.rtp)
        }
        mediaLock.unlock()
    }

    // MARK: tx loop: keepalive + RR/SR + keyframe recovery (every 0.5 s)

    private func txLoop(_ c: Conn) {
        var tick = 0
        let heartbeat = Data([0x00, 0x68, 0x34, 0x00])
        while running && generation == c.gen {
            tick += 1
            sendTo(c.ctrlFD, addr: c.hostAddr, port: port, c.audioEnc.encrypt(heartbeat, pt: 101))
            mediaLock.lock()
            let srcs = group.compactMap { tiles[$0] }.map { (ssrc: $0.ssrc, extSeq: ($0.roc << 16) | UInt32($0.maxSeq)) }
            let stale = (haveParams && synced) ? [] : group.prefix(1).compactMap { tiles[$0] }
            mediaLock.unlock()
            var rtcp = HPRTCP.rr(sender: c.ourVideoSSRC, sources: srcs)
            if tick % 10 == 1 { rtcp = HPRTCP.emptySR(c.ourVideoSSRC) + rtcp }
            sendTo(c.ctrlFD, addr: c.hostAddr, port: port, c.srtcpEnc.protect(rtcp))
            let now = Self.now()
            for t in stale { requestKeyframe(t, c, now: now) }
            mediaLock.lock(); maybeAdopt(c, now: now); mediaLock.unlock()
            tickRates(now)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: UDP / address helpers

    /// For a same-host target (loopback or one of our own addresses) pick a
    /// different local IPv4 so our 5900/5901 don't collide with the host's.
    static func autoBindIP(for host: String) -> String? {
        let target = ipv4String(host) ?? host
        let locals = localIPv4s()
        let sameHost = target.hasPrefix("127.") || locals.contains { $0.ip == target }
        guard sameHost else { return nil }
        // Prefer a physical (en*) interface, never the target itself; utun
        // (Tailscale) source addresses don't route to local listeners.
        let pick = locals.first { $0.name.hasPrefix("en") && $0.ip != target }
            ?? locals.first { !$0.name.hasPrefix("utun") && $0.ip != target }
        return pick?.ip
    }

    static func localIPv4s() -> [(name: String, ip: String)] {
        var out: [(String, String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                out.append((String(cString: cur.pointee.ifa_name), String(cString: host)))
            }
            p = cur.pointee.ifa_next
        }
        return out
    }

    static func ipv4String(_ host: String) -> String? {
        var a = in_addr()
        if inet_pton(AF_INET, host, &a) == 1 { return host }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = r.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    static func ipv4(_ host: String) -> in_addr_t { inet_addr(ipv4String(host) ?? host) }

    private func bindUDP(_ p: UInt16, ip: String?) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Err.sock("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var rb: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rb, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = p.bigEndian
        addr.sin_addr.s_addr = ip.map { inet_addr($0) } ?? INADDR_ANY
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { Darwin.close(fd); throw Err.sock("bind \(ip ?? "*"):\(p) errno=\(errno)") }
        return fd
    }

    private func sendTo(_ fd: Int32, addr a: in_addr_t, port p: UInt16, _ data: Data) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = p.bigEndian
        addr.sin_addr.s_addr = a
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
        let d = Data([5, buttons, UInt8(cx >> 8), UInt8(cx & 0xff), UInt8(cy >> 8), UInt8(cy & 0xff)])
        inputLock.lock(); defer { inputLock.unlock() }
        try? s.send(c.encrypt(d))
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
