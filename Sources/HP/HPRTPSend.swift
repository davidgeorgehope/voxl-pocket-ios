import Foundation

/// SRTP sender (AES-256-CTR + HMAC-SHA1-80, RFC 3711 labels 0/1/2). Only used
/// for the PT=101 audio keepalive the host expects from the viewer on the
/// muxed ctrl port: without it AVConference treats the viewer as gone and
/// stops streaming (`noRemotePacketsTimeout`).
final class HPSRTPEncryptor {
    private let cipherKey: Data, authKey: Data, salt: Data
    let ssrc: UInt32
    private var seq: UInt16 = 0, roc: UInt32 = 0, ts: UInt32 = 0
    private let lock = NSLock()

    init(blob: Data, ssrc: UInt32) {
        let mk = blob.prefix(32)
        let ms = blob.subdata(in: (blob.startIndex + 32)..<(blob.startIndex + 46))
        cipherKey = HPSRTP.kdf(mk, ms, 0, 32)
        authKey = HPSRTP.kdf(mk, ms, 1, 20)
        salt = HPSRTP.kdf(mk, ms, 2, 14)
        self.ssrc = ssrc
    }

    func encrypt(_ payload: Data, pt: UInt8 = 101, marker: Bool = false) -> Data {
        lock.lock()
        let s = seq, r = roc, t = ts
        seq &+= 1; if seq == 0 { roc &+= 1 }
        ts &+= 480
        lock.unlock()
        let hdr = Data([0x80, (pt & 0x7f) | (marker ? 0x80 : 0)] + HPRTCP.be16(Int(s)) + HPRTCP.be32(t) + HPRTCP.be32(ssrc))
        let index = (UInt64(r) << 16) | UInt64(s)
        let ivInt = UInt128(bytes: salt + Data([0, 0])) ^ UInt128(hi: UInt64(ssrc), lo: 0)
            ^ UInt128(hi: index >> 48, lo: index << 16)
        var body = hdr + HPSRTP.aesCTR(key: cipherKey, iv: ivInt.bytesBE, data: payload)
        let tag = HPSRTP.hmacSHA1(key: authKey, data: body + Data(HPRTCP.be32(r))).prefix(10)
        body.append(tag)
        return body
    }
}

extension HPRTCP {
    /// Picture Loss Indication (RFC 4585 PT=206 FMT=1).
    static func pli(sender: UInt32, target: UInt32) -> Data {
        Data([0x80 | 1, 206] + be16(2) + be32(sender) + be32(target))
    }

    /// RR with one report block per source carrying the extended highest seq.
    static func rr(sender: UInt32, sources: [(ssrc: UInt32, extSeq: UInt32)]) -> Data {
        if sources.isEmpty { return emptyRR(sender) }
        let rc = min(sources.count, 31)
        var d = Data([UInt8(0x80 | rc), 201] + be16(1 + rc * 6) + be32(sender))
        for s in sources.prefix(rc) { d += Data(be32(s.ssrc) + be32(0) + be32(s.extSeq) + be32(0) + be32(0) + be32(0)) }
        return d
    }

    /// Keyframe request the way Apple's viewer does it: RR + AVPF FIR + PLI +
    /// legacy (RFC 2032) FIR, all addressed to the tile's media SSRC.
    static func keyframeRequest(sender: UInt32, target: UInt32, seq: UInt8) -> Data {
        emptyRR(sender) + fir(sender: sender, target: target, seq: seq)
            + pli(sender: sender, target: target) + firLegacy(target)
    }

    /// Sender Reports in a compound RTCP buffer: (ssrc, NTP wallclock seconds since 1970, RTP ts).
    static func senderReports(_ d: Data) -> [(ssrc: UInt32, wall: Double, rtp: UInt32)] {
        let b = [UInt8](d); var out: [(UInt32, Double, UInt32)] = []; var pos = 0
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o+1]) << 16 | UInt32(b[o+2]) << 8 | UInt32(b[o+3]) }
        while pos + 4 <= b.count {
            let len = (((Int(b[pos+2]) << 8) | Int(b[pos+3])) + 1) * 4
            if pos + len > b.count || len < 4 { break }
            if b[pos+1] == 200 && len >= 28 {
                let sec = Double(u32(pos+8)) - 2_208_988_800, frac = Double(u32(pos+12)) / 4_294_967_296.0
                out.append((u32(pos+4), sec + frac, u32(pos+16)))
            }
            pos += len
        }
        return out
    }
}
