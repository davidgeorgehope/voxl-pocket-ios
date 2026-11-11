import Foundation
import CoreVideo
import CoreGraphics
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
        var updateFPS: Double = 0      // screen updates/s: the busiest tile's decoded pictures
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
        var hwDecode = false           // VideoToolbox session reports a hardware decoder
        var lostPackets = 0            // RTP sequence gaps (video)
        var nacksSent = 0
        var recoveredPackets = 0       // late packets (retransmits/reorder) that filled a hole in time
        var droppedFrames = 0          // tile pictures not decoded: hole not repaired in time
        var ltrAcks = 0
        var backlogMax = 0             // largest decode-queue depth seen in the last 2 s
        var backlogPeak = 0
        var e2eMs: Double? = nil       // marker test: host screen draw → decoded on our side (same clock)
        var e2eSamples = 0
        var e2eLast: Double? = nil
        var cursorUpdates = 0
        var phases = ""                // connect timeline
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
    /// One decoded tile (index, picture). When set, no CPU canvas composite is made
    /// unless onFrame is also set: the view shows the tiles as stacked layers.
    var onTile: ((Int, CVPixelBuffer) -> Void)?
    /// Host cursor shape (enc 1104): image + hotspot, in canvas pixels. nil = default arrow.
    var onCursor: ((CGImage?, CGPoint) -> Void)?
    /// How long a tile picture with a sequence hole waits for a NACK retransmit
    /// before it is dropped (and decoding moves on). 0 = drop at once: measured on the
    /// mini, the host never retransmits HEVC packets for a NACK, so waiting only adds delay.
    var repairWait: Double = Double(ProcessInfo.processInfo.environment["VOXL_HP_REPAIR_MS"] ?? "").map { $0 / 1000 } ?? 0
    /// Decode a picture with a hole anyway (VideoToolbox conceals) instead of skipping it.
    var feedPartial = ProcessInfo.processInfo.environment["VOXL_HP_FEED_PARTIAL"] == "1"
    /// Test hook: drop this fraction of incoming video packets (Wi-Fi loss simulation).
    var simulatedLoss: Double = Double(ProcessInfo.processInfo.environment["VOXL_HP_DROP"] ?? "") ?? 0
    /// Marker test: cell size in canvas pixels of the time code drawn at the host's
    /// top-left (16 bits, row 2 inverted). 0 = off.
    var markerCell: Int = Int(ProcessInfo.processInfo.environment["VOXL_HP_MARKER"] ?? "") ?? 0
    /// Send Apple's LTR acknowledgements (lets the host recover from loss without an IDR).
    var ltrAcksEnabled = ProcessInfo.processInfo.environment["VOXL_HP_LTR"] != "0"
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
        /// Pictures being received, by RTP timestamp; decoded in sequence order.
        var pending: [UInt32: PFrame] = [:]
        var lastMarkerSeq: UInt16?
        var recent: [UInt32] = []          // recently decoded/dropped timestamps (late duplicates)
        var nack = Set<UInt16>()
        init(ssrc: UInt32, index: Int) { self.ssrc = ssrc; self.index = index }
    }

    private final class PFrame {
        var pkts: [(seq: UInt16, marker: Bool, payload: Data)] = []
        let arrival: Double
        let order: Int
        var deadline: Double?
        init(arrival: Double, order: Int) { self.arrival = arrival; self.order = order }
        var hasMarker: Bool { pkts.contains { $0.marker } }
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

        phaseMarks = []
        try HPRFB.warmupTCP(host: host, port: port, dwell: warmupDwell, sourceIP: bindIP)
        mark("warmup")
        log("warmup done; handshaking")
        let (sock, _hs) = try HPRFB.connectAndAuth(host: host, port: port, username: username,
                                                   password: password, sourceIP: bindIP)
        mark("auth")
        controlSocket = sock
        HPNeg.trace = { [weak self] in self?.log($0) }
        let neg = try HPNeg.negotiate(sock, ecbKey: _hs.ecbKey)
        mark("offer answered")
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
        let tcpCipher = neg.cipher
        let tail = neg.rxTail, early = neg.leftover
        Thread.detachNewThread { [weak self] in
            // Read the enc1103 TCP channel: cursor shapes (enc 1104) arrive here; keeps
            // the host's send buffer drained and detects a closed session.
            var rx = tail
            for m in early { self?.handleTCP(m, conn) }
            while let self, self.running, self.generation == gen {
                guard let s = self.controlSocket else { break }
                let (d, r) = s.recvSomeData(65536)
                if r < 0 { break }          // closed / hard error
                if d.isEmpty { continue }
                rx += d
                let (msgs, used) = tcpCipher.decryptStream(rx)
                rx.removeSubrange(rx.startIndex..<(rx.startIndex + used))
                if rx.count > 1 << 20 { rx.removeAll() }
                for m in msgs { self.handleTCP(m, conn) }
            }
            tcpAlive = false
            threadsDone.leave()
        }
        // Decode worker: the receive loop only queues packets, so a slow decode
        // never backs up the socket (where Wi-Fi bursts would overflow and drop).
        inboxLock.lock(); inbox.removeAll(); inboxLock.unlock()
        threadsDone.enter()
        Thread.detachNewThread { [weak self] in self?.decodeLoop(conn); threadsDone.leave() }
        defer { generation += 1; inboxSignal.signal(); controlSocket?.shutdownBoth(); threadsDone.wait() }

        // video receive loop (this thread)
        var buf = [UInt8](repeating: 0, count: 65536)
        setRecvTimeout(videoFD, seconds: 0.25)
        lastRateTick = Self.now()
        var firstRTP = true
        while running && tcpAlive {
            let n = Darwin.recv(videoFD, &buf, buf.count, 0)
            guard n > 0 else { continue }
            if firstRTP { firstRTP = false; mark("first video packet") }
            if simulatedLoss > 0, Double.random(in: 0..<1) < simulatedLoss { continue }
            let pkt = Data(buf[0..<n]), t = Self.now()
            inboxLock.lock(); inbox.append((pkt, t)); let depth = inbox.count; inboxLock.unlock()
            if depth > backlogWindowMax { backlogWindowMax = depth }
            inboxSignal.signal()
        }
        if running && !tcpAlive { throw Err.sock("control channel closed by host") }
    }

    private func resetMediaState() {
        mediaLock.lock()
        tiles.removeAll(); group.removeAll(); blacklist.removeAll(); candidateCounts.removeAll()
        srMap.removeAll(); composeTS = nil; composeDone.removeAll(); tileHeight = 0
        decoder.teardown(); vps = Data(); sps = Data(); ppsPool.removeAll(); haveParams = false; synced = false
        lastPublish = 0; lastAdopt = 0; rtpClockRef = nil
        firstIRAPMarked = false; adoptMarked = false; lastLTR = nil; frameOrder = 0
        mediaLock.unlock()
        rxVideo = 0; rxVideoBytes = 0; rxAudio = 0; framesAtTick = 0
    }

    // MARK: connect timeline

    private var phaseMarks: [(String, Double)] = []
    /// TCP warmup dwell. Apple dwells ~1.4 s; 0.3-0.5 s measured fine on the mini (VOXL_HP_WARMUP overrides).
    var warmupDwell: Double = Double(ProcessInfo.processInfo.environment["VOXL_HP_WARMUP"] ?? "") ?? 0.5

    private func mark(_ name: String) {
        let t = Self.now()
        phaseMarks.append((name, t))
        var prev = connectStart
        let line = phaseMarks.map { (n, at) -> String in
            defer { prev = at }
            return String(format: "%@ +%.2fs", n, at - prev)
        }.joined(separator: ", ")
        updateStats { $0.phases = line + String(format: " (total %.1fs)", t - connectStart) }
        log("connect: \(name) at +" + String(format: "%.2fs", t - connectStart))
    }

    // MARK: video receive → decode worker

    private let inboxLock = NSLock()
    private let inboxSignal = DispatchSemaphore(value: 0)
    private var inbox: [(Data, Double)] = []
    private var backlogWindowMax = 0
    private var tileCounts: [Int: Int] = [:]
    private var frameOrder = 0
    private var firstIRAPMarked = false

    private func decodeLoop(_ c: Conn) {
        while running && generation == c.gen {
            _ = inboxSignal.wait(timeout: .now() + .milliseconds(10))
            inboxLock.lock(); let batch = inbox; inbox.removeAll(keepingCapacity: true); inboxLock.unlock()
            for (pkt, t) in batch { handleVideo(pkt, c, arrival: t) }
            // Repair deadlines expire even when no packet arrives.
            drainReady(c, now: Self.now())
        }
    }

    private func handleVideo(_ pkt: Data, _ c: Conn, arrival now: Double) {
        guard pkt.count >= 12 else { return }
        let b1 = pkt[pkt.startIndex + 1] & 0x7f
        if b1 >= 64 && b1 <= 95 {                    // RTCP muxed on the video port
            if let d = c.srtcpDec.unprotect(pkt) { noteSR(d) }
            return
        }
        rxVideo += 1; rxVideoBytes += pkt.count
        let p = pkt.startIndex
        let ssrc = UInt32(pkt[p+8]) << 24 | UInt32(pkt[p+9]) << 16 | UInt32(pkt[p+10]) << 8 | UInt32(pkt[p+11])

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
        let marker = (h[1] & 0x80) != 0
        let ts = UInt32(h[4]) << 24 | UInt32(h[5]) << 16 | UInt32(h[6]) << 8 | UInt32(h[7])
        var late = false
        if !tile.seqInit { tile.maxSeq = seq; tile.seqInit = true }
        else {
            let diff = seq &- tile.maxSeq
            if diff == 0 { return }                          // duplicate
            if diff >= 0x8000 {                              // late: retransmit or reorder
                late = true
                tile.nack.remove(seq)
            } else {
                if diff > 1 {
                    let missed = Int(diff) - 1
                    for k in 1..<min(Int(diff), 64) { tile.nack.insert(tile.maxSeq &+ UInt16(k)) }
                    updateStats { $0.lostPackets += missed }
                    sendNACK(tile, c)
                }
                if seq < tile.maxSeq { tile.roc &+= 1 }
                tile.maxSeq = seq
            }
        }
        if tile.recent.contains(ts) { return }               // picture already decoded/dropped
        let f: PFrame
        if let have = tile.pending[ts] { f = have }
        else { frameOrder += 1; f = PFrame(arrival: now, order: frameOrder); tile.pending[ts] = f }
        if f.pkts.contains(where: { $0.seq == seq }) { return }
        f.pkts.append((seq, marker, payload))
        if late, f.deadline != nil { updateStats { $0.recoveredPackets += 1 } }
        drainReady(c, now: now)
        tickRates(now)
    }

    /// Generic NACK (RFC 4585) for this tile's missing sequence numbers, sent at once.
    private func sendNACK(_ tile: Tile, _ c: Conn) {
        guard !tile.nack.isEmpty else { return }
        let seqs = tile.nack.sorted { ($0 &- tile.maxSeq) < ($1 &- tile.maxSeq) }
        var fci = Data()
        var i = 0
        while i < seqs.count {
            let pid = seqs[i]; var blp: UInt16 = 0; var j = i + 1
            while j < seqs.count, case let d = seqs[j] &- pid, d >= 1 && d <= 16 { blp |= 1 << (d - 1); j += 1 }
            fci += Data([UInt8(pid >> 8), UInt8(pid & 0xff), UInt8(blp >> 8), UInt8(blp & 0xff)])
            i = j
        }
        let words = 2 + fci.count / 4
        var nack = Data([0x81, 205, UInt8(words >> 8), UInt8(words & 0xff)])
        for v in [c.ourVideoSSRC, tile.ssrc] { nack += Data([UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
        nack += fci
        let srcs = [(ssrc: tile.ssrc, extSeq: (tile.roc << 16) | UInt32(tile.maxSeq))]
        sendTo(c.ctrlFD, addr: c.hostAddr, port: port, c.srtcpEnc.protect(HPRTCP.rr(sender: c.ourVideoSSRC, sources: srcs) + nack))
        tile.nack.removeAll()
        updateStats { $0.nacksSent += 1 }
    }

    /// The tile's next picture in decode order: sequence distance from the last
    /// decoded marker (a retransmitted, wholly-missing picture arrives after its
    /// successor but still decodes first).
    private func head(_ t: Tile) -> (UInt32, PFrame)? {
        guard !t.pending.isEmpty else { return nil }
        if let lm = t.lastMarkerSeq {
            let exp = lm &+ 1
            return t.pending.min { a, b in
                let da = (a.value.pkts.map { $0.seq &- exp }.min() ?? 0xffff)
                let db = (b.value.pkts.map { $0.seq &- exp }.min() ?? 0xffff)
                return da != db ? da < db : a.value.order < b.value.order
            }.map { ($0.key, $0.value) }
        }
        return t.pending.min { $0.value.order < $1.value.order }.map { ($0.key, $0.value) }
    }

    private func sortedPkts(_ t: Tile, _ f: PFrame) -> [(seq: UInt16, marker: Bool, payload: Data)] {
        let anchor = t.lastMarkerSeq.map { $0 &+ 1 } ?? (f.pkts.first!.seq &- 0x4000)
        return f.pkts.sorted { ($0.seq &- anchor) < ($1.seq &- anchor) }
    }

    /// Marker seen, no hole inside, and it starts right after the previous picture.
    private func complete(_ t: Tile, _ f: PFrame) -> Bool {
        guard f.hasMarker else { return false }
        let ps = sortedPkts(t, f)
        if let lm = t.lastMarkerSeq, ps.first!.seq != lm &+ 1 { return false }
        for i in 1..<max(1, ps.count) where ps[i].seq &- ps[i - 1].seq != 1 { return false }
        return ps.last!.marker
    }

    /// Decode every picture that is ready, oldest first across tiles (they share
    /// one DPB). A picture with a hole blocks the queue for `repairWait`, then is dropped.
    private func drainReady(_ c: Conn, now: Double) {
        while true {
            mediaLock.lock()
            let ts_ = group.compactMap { tiles[$0] }
            mediaLock.unlock()
            var best: (Tile, UInt32, PFrame)?
            for t in ts_ { if let (k, f) = head(t), best == nil || f.order < best!.2.order { best = (t, k, f) } }
            guard let (t, ts, f) = best else { return }
            if complete(t, f) {
                decodePicture(t, ts: ts, sortedPkts(t, f), arrival: f.arrival, c)
                continue
            }
            // Still arriving (no marker, nothing newer for this tile): just wait —
            // unless it has been far too long.
            let newer = t.pending.count > 1
            if !f.hasMarker && !newer && now - f.arrival < 0.25 { return }
            if f.deadline == nil { f.deadline = now + repairWait }
            if now < f.deadline! { return }
            if feedPartial, f.hasMarker { updateStats { $0.droppedFrames += 1 }; decodePicture(t, ts: ts, sortedPkts(t, f), arrival: f.arrival, c) }
            else { dropPicture(t, ts: ts, f, c) }
        }
    }

    private func finish(_ t: Tile, ts: UInt32, lastSeq: UInt16) {
        t.pending[ts] = nil
        t.lastMarkerSeq = lastSeq
        t.recent.append(ts); if t.recent.count > 32 { t.recent.removeFirst(t.recent.count - 32) }
    }

    private func dropPicture(_ t: Tile, ts: UInt32, _ f: PFrame, _ c: Conn) {
        let ps = sortedPkts(t, f)
        finish(t, ts: ts, lastSeq: (ps.last { $0.marker } ?? ps.last!).seq)
        updateStats { $0.droppedFrames += 1 }
        // The host keeps sending pictures that reference acked LTRs; if those fail to
        // decode, the decode-error path asks for a keyframe.
    }

    private func decodePicture(_ tile: Tile, ts: UInt32, _ pkts: [(seq: UInt16, marker: Bool, payload: Data)], arrival: Double, _ c: Conn) {
        finish(tile, ts: ts, lastSeq: pkts.last!.seq)
        let payloads = pkts.map { $0.payload }
        let nalus = HPNALU.reassembleGroup(payloads)
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
            let hw = decoder.usingHardware
            updateStats { $0.hwDecode = hw }
            log("VT session \(haveParams ? "up" : "FAILED") (pps=\(pps.count)) hw=\(hw)")
        }
        var clean = true
        for nalu in nalus {
            let t = HPNALU.nalType(nalu)
            guard t >= 0 && t <= 31 else { continue }        // VCL only; params live in the format desc
            if t >= 16 && t <= 23 {
                synced = true
                if !firstIRAPMarked { firstIRAPMarked = true; mark("first keyframe") }
            }
            guard haveParams, synced else {
                clean = false
                if let t0 = group.first.flatMap({ tiles[$0] }) { requestKeyframe(t0, c, now: now) }
                continue
            }
            var au = Data(capacity: nalu.count + 4)
            var len = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &len) { au.append(contentsOf: $0) }
            au.append(nalu)
            guard let dec = decoder.decode(accessUnit: au) else {
                clean = false
                updateStats { $0.decodeErrors += 1 }
                maybeRecover(c, now: now)
                continue
            }
            tile.latest = dec.pixelBuffer
            tile.lastDecode = now
            updateStats { $0.tileFrames += 1 }
            tileCounts[tile.index, default: 0] += 1
            if markerCell > 0 && tile.index == 0 { readMarker(dec.pixelBuffer) }
            onTile?(tile.index, dec.pixelBuffer)
            compose(tile: tile, ts: ts, firstArrival: arrival, c)
        }
        if clean { lastCleanDecode = now }
        if clean && tile.index == 0 && ltrAcksEnabled, let donl = Self.firstDONL(payloads) { sendLTRAck(donl, c) }
    }

    /// HEVC decoding-order number from the first packet (Apple: after the 2-byte
    /// payload header, or after the FU header).
    static func firstDONL(_ payloads: [Data]) -> UInt16? {
        for pay in payloads where pay.count >= 2 {
            let b = pay.startIndex
            let nt = (pay[b] >> 1) & 0x3f
            if nt == 49 { if pay.count >= 5 { return UInt16(pay[b + 3]) << 8 | UInt16(pay[b + 4]) } }
            else if pay.count >= 4 { return UInt16(pay[b + 2]) << 8 | UInt16(pay[b + 3]) }
        }
        return nil
    }

    private var lastLTR: UInt16?
    private var lastCleanDecode: Double = 0
    private var lastRecoveryFIR: Double = 0
    /// Keyframe only when loss isn't healing by itself: the host answers NACKs by
    /// predicting from an acked long-term reference, which is far cheaper than an IDR
    /// (an IDR is hundreds of packets, and on lossy Wi-Fi it loses a packet itself).
    private func maybeRecover(_ c: Conn, now: Double) {
        guard now - lastCleanDecode > recoverAfter, now - lastRecoveryFIR > 0.5,
              let t0 = group.first.flatMap({ tiles[$0] }) else { return }
        lastRecoveryFIR = now
        requestKeyframe(t0, c, now: now, force: true)
    }
    var recoverAfter = Double(ProcessInfo.processInfo.environment["VOXL_HP_RECOVER_MS"] ?? "").map { $0 / 1000 } ?? 0.15
    /// RTCP APP "LTRP" ack for a cleanly decoded tile-0 picture, to the video port.
    private func sendLTRAck(_ donl: UInt16, _ c: Conn) {
        guard donl != lastLTR else { return }
        lastLTR = donl
        let v = c.ourVideoSSRC, d = UInt32(donl)
        let pkt = Data([0x80, 204, 0, 3, UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff),
                        0, 0, 0, 5, UInt8(d >> 24), UInt8(d >> 16 & 0xff), UInt8(d >> 8 & 0xff), UInt8(d & 0xff)])
        sendTo(c.videoFD, addr: c.hostAddr, port: port + 1, c.srtcpEnc.protect(pkt))
        updateStats { $0.ltrAcks += 1 }
    }

    /// Marker test: read the 16-bit millisecond code the host draws at top-left.
    private func readMarker(_ pb: CVPixelBuffer) {
        let cell = markerCell
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetWidth(pb) >= cell * 16,
              CVPixelBufferGetHeight(pb) >= cell * 2 else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        func lum(_ x: Int, _ y: Int) -> Int {
            let px = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            return Int(px[0]) + Int(px[1]) + Int(px[2])
        }
        var v = 0
        for i in 0..<16 {
            let a = lum(i * cell + cell / 2, cell / 2), b = lum(i * cell + cell / 2, cell + cell / 2)
            guard abs(a - b) > 300 else { return }            // not a marker (row 2 is row 1 inverted)
            if a > b { v |= 1 << (15 - i) }
        }
        let nowMs = Int((Date().timeIntervalSince1970 * 1000).rounded()) & 0xffff
        let lat = Double((nowMs - v) & 0xffff)
        guard lat < 3000 else { return }
        updateStats { s in
            s.e2eMs = s.e2eMs.map { $0 * 0.9 + lat * 0.1 } ?? lat
            s.e2eLast = lat; s.e2eSamples += 1
        }
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
        if !adoptMarked { adoptMarked = true; mark("tiles adopted") }
        for t in chosen.compactMap({ tiles[$0] }) { requestKeyframe(t, c, now: now, force: true) }
    }
    private var adoptMarked = false

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
        // The app shows tiles as layers (onTile); only the harness wants a composite.
        guard onFrame != nil else { recordFrame(firstArrival: fa, ts0: ts0, sr: sr); return }

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

        recordFrame(firstArrival: fa, ts0: ts0, sr: sr)
        onFrame?(out, w, h)
    }

    private func recordFrame(firstArrival fa: Double, ts0: UInt32, sr: (wall: Double, rtp: UInt32)?) {
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
        if stats.firstFrameMs == nil { mark("first frame") }
        updateStats { s in
            s.frames += 1
            if s.firstFrameMs == nil { s.firstFrameMs = now * 1000; s.connectToFirstFrameMs = (now - self.connectStart) * 1000 }
            s.backlogPeak = max(s.backlogPeak, s.backlogMax)
            s.pipelineMs = s.pipelineMs.map { $0 * 0.9 + pipe * 0.1 } ?? pipe
            if let lat { s.latencyMs = s.latencyMs.map { $0 * 0.9 + lat * 0.1 } ?? lat }
        }
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
            s.backlogMax = self.backlogWindowMax
            s.updateFPS = Double(self.tileCounts.values.max() ?? 0) / dt
        }
        tileCounts.removeAll()
        backlogWindowMax = 0
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
            sendControl(HPNeg.cursorPoll())       // keep cursor shapes coming
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
    /// Input goes out on its own queue so a slow Wi-Fi socket never stalls touch
    /// handling; pointer moves coalesce to the latest position while one is in flight.
    private let inputQueue = DispatchQueue(label: "hp.input", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pendingMove: (x: Int, y: Int, buttons: UInt8)?
    private var lastSent: (x: Int, y: Int, buttons: UInt8)?
    private(set) var pointerSent = 0, pointerCoalesced = 0

    /// Encrypt + send one control message; the lock keeps cipher order = wire order.
    private func sendControl(_ d: Data) {
        guard let s = controlSocket, let c = cipher else { return }
        inputLock.lock(); defer { inputLock.unlock() }
        try? s.send(c.encrypt(d))
    }

    private func pointerMsg(_ x: Int, _ y: Int, _ b: UInt8) -> Data {
        let cx = UInt16(clamping: max(0, min(x, max(canvasW - 1, 0)))), cy = UInt16(clamping: max(0, min(y, max(canvasH - 1, 0))))
        return Data([5, b, UInt8(cx >> 8), UInt8(cx & 0xff), UInt8(cy >> 8), UInt8(cy & 0xff)])
    }

    private func flushMove() {
        pendingLock.lock(); let m = pendingMove; pendingMove = nil; pendingLock.unlock()
        guard let m else { return }
        if let l = lastSent, l == m { return }
        lastSent = m
        pointerSent += 1
        sendControl(pointerMsg(m.x, m.y, m.buttons))
    }

    /// Pointer motion (canvas pixels). Coalesced: only the newest position is sent.
    func movePointer(x: Int, y: Int, buttons: UInt8) {
        pendingLock.lock()
        let idle = pendingMove == nil
        if !idle { pointerCoalesced += 1 }
        pendingMove = (x, y, buttons)
        pendingLock.unlock()
        if idle { inputQueue.async { self.flushMove() } }
    }

    /// RFB PointerEvent (msg 5) for a button change: sent in order, never coalesced.
    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        inputQueue.async {
            self.flushMove()
            self.lastSent = (x, y, buttons)
            self.pointerSent += 1
            self.sendControl(self.pointerMsg(x, y, buttons))
        }
    }

    /// Wheel: Apple maps buttons 4/5 (mask 8 up, 16 down) press/release pairs to ticks.
    func scroll(x: Int, y: Int, ticks: Int, buttons: UInt8 = 0) {
        guard ticks != 0 else { return }
        let bit: UInt8 = ticks < 0 ? 8 : 16
        inputQueue.async {
            self.flushMove()
            for _ in 0..<min(abs(ticks), 20) {
                self.sendControl(self.pointerMsg(x, y, buttons | bit))
                self.sendControl(self.pointerMsg(x, y, buttons))
            }
        }
    }

    /// RFB KeyEvent (msg 4): down flag + X11 keysym.
    func sendKey(keysym: UInt32, down: Bool) {
        let d = Data([4, down ? 1 : 0, 0, 0,
                      UInt8(keysym >> 24 & 0xff), UInt8(keysym >> 16 & 0xff),
                      UInt8(keysym >> 8 & 0xff), UInt8(keysym & 0xff)])
        inputQueue.async { self.flushMove(); self.sendControl(d) }
    }

    // MARK: control channel messages (cursor shapes)

    private var cursorCache: [UInt32: (CGImage, CGPoint)] = [:]

    private func handleTCP(_ m: Data, _ c: Conn) {
        let b = [UInt8](m)
        guard b.count >= 4, b[0] == 0x00 else { return }
        let n = Int(b[2]) << 8 | Int(b[3])
        var p = 4
        var sawCursor = false
        func u16(_ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o+1]) << 16 | UInt32(b[o+2]) << 8 | UInt32(b[o+3]) }
        rects: for _ in 0..<n {
            guard p + 12 <= b.count else { break }
            let f0 = u16(p), f1 = u16(p + 2), f2 = u16(p + 4), f3 = u16(p + 6)
            let enc = Int32(bitPattern: u32(p + 8))
            p += 12
            switch enc {
            case 1104:
                guard p + 8 <= b.count else { break rects }
                let cacheID = u32(p), comp = Int(u32(p + 4))
                p += 8
                sawCursor = true
                if comp == 0 {
                    let hit = cursorCache[cacheID]
                    onCursor?(hit?.0, hit?.1 ?? .zero)
                } else {
                    guard p + comp <= b.count else { break rects }
                    if let img = Self.cursorImage(Data(b[p..<(p + comp)]), w: f2, h: f3) {
                        let hot = CGPoint(x: f0, y: f1)
                        cursorCache[cacheID] = (img, hot)
                        onCursor?(img, hot)
                    }
                    p += comp
                }
                updateStats { $0.cursorUpdates += 1 }
            case 1010, 1011, 1107, 1109, 1110, 0x3f2, 0x3f3, 0x3ea, 0x453, 0x455, 0x456, 0x451:
                guard p + 2 <= b.count else { break rects }
                p += 2 + u16(p)
            default:
                break rects
            }
        }
        if sawCursor { sendControl(HPNeg.cursorPoll()) }
    }

    /// enc 1104 body: zlib(w*h BGRA, then a w*h alpha mask).
    static func cursorImage(_ z: Data, w: Int, h: Int) -> CGImage? {
        guard w > 0, h > 0, w <= 512, h <= 512,
              let raw = HPZlib.decompress(z + Data([0, 0, 0, 0]), expectedMax: w * h * 5 + 64), raw.count >= w * h * 5 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        raw.withUnsafeBytes { (r: UnsafeRawBufferPointer) in
            let src = r.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) {
                let a = Int(src[w * h * 4 + i])
                rgba[i * 4 + 0] = UInt8(Int(src[i * 4 + 2]) * a / 255)
                rgba[i * 4 + 1] = UInt8(Int(src[i * 4 + 1]) * a / 255)
                rgba[i * 4 + 2] = UInt8(Int(src[i * 4 + 0]) * a / 255)
                rgba[i * 4 + 3] = UInt8(a)
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func log(_ m: String) { onLog?("[hpmedia] " + m) }
    enum Err: Error { case sock(String) }
}
