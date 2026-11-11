import Foundation
import CommonCrypto

/// SRTP receiver: AES-256-CTR + HMAC-SHA1-80, RFC 3711 KDF, per-SSRC ROC.
/// Clean-room port. Keyed from a 46-byte blob (32 master key + 14 salt).
final class HPSRTPDecryptor {
    static let keyBlobLen = 46
    private let authTagLen = 10

    private let cipherKey: Data   // 32
    private let authKey: Data     // 20
    private let saltInt: UInt128
    private struct State { var roc: UInt32 = 0; var maxSeq: UInt16 = 0; var inited = false }
    private var states: [UInt32: State] = [:]
    private(set) var counts: [UInt32: Int] = [:]

    init(masterKey: Data, masterSalt: Data) {
        cipherKey = HPSRTP.kdf(masterKey, masterSalt, 0, 32)
        authKey = HPSRTP.kdf(masterKey, masterSalt, 1, 20)
        let salt = HPSRTP.kdf(masterKey, masterSalt, 2, 14)
        saltInt = UInt128(bytes: salt + Data([0,0]))
    }
    convenience init(blob: Data) {
        self.init(masterKey: blob.prefix(32), masterSalt: blob.subdata(in: (blob.startIndex+32)..<(blob.startIndex+46)))
    }

    /// Decrypt one SRTP packet → (rtpHeader, payload) or nil.
    func decrypt(_ pkt: Data) -> (Data, Data)? {
        guard pkt.count >= 12 + authTagLen else { return nil }
        let b = [UInt8](pkt)
        let bodyLen = pkt.count - authTagLen
        let seq = UInt16(b[2]) << 8 | UInt16(b[3])
        let ssrc = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        let st = states[ssrc]
        var guessRoc: UInt32 = 0
        if let st, st.inited {
            let diff = Int(seq) - Int(st.maxSeq)
            if diff > 0x7fff { guessRoc = st.roc == 0 ? 0 : st.roc - 1 }
            else if diff < -0x7fff { guessRoc = st.roc + 1 }
            else { guessRoc = st.roc }
        }
        var cands: [UInt32] = []
        for r in [guessRoc, st?.roc ?? 0, guessRoc + 1, guessRoc == 0 ? 0 : guessRoc - 1] where !cands.contains(r) { cands.append(r) }
        for roc in cands {
            if let res = tryDecrypt(b: b, pkt: pkt, bodyLen: bodyLen, seq: seq, ssrc: ssrc, roc: roc) {
                update(ssrc: ssrc, roc: roc, seq: seq)
                counts[ssrc, default: 0] += 1
                return res
            }
        }
        return nil
    }

    private func tryDecrypt(b: [UInt8], pkt: Data, bodyLen: Int, seq: UInt16, ssrc: UInt32, roc: UInt32) -> (Data, Data)? {
        var macInput = Data(pkt.prefix(bodyLen))
        macInput.append(contentsOf: [UInt8(roc >> 24 & 0xff), UInt8(roc >> 16 & 0xff), UInt8(roc >> 8 & 0xff), UInt8(roc & 0xff)])
        let tag = HPSRTP.hmacSHA1(key: authKey, data: macInput).prefix(authTagLen)
        let recv = pkt.subdata(in: (pkt.startIndex + bodyLen)..<(pkt.startIndex + bodyLen + authTagLen))
        guard tag == recv else { return nil }
        let first = b[0]
        let cc = Int(first & 0x0f)
        var hdrLen = 12 + cc * 4
        if (first >> 4) & 1 == 1 {
            if hdrLen + 4 > bodyLen { return nil }
            let extLen = Int(b[hdrLen + 2]) << 8 | Int(b[hdrLen + 3])
            hdrLen += 4 + extLen * 4
        }
        if hdrLen > bodyLen { return nil }
        let header = Data(pkt.prefix(hdrLen))
        if hdrLen == bodyLen { return (header, Data()) }
        let index = (UInt64(roc) << 16) | UInt64(seq)
        // IV = saltInt ^ (ssrc << 64) ^ (index << 16), as 16 bytes BE
        let ivInt = saltInt ^ UInt128(hi: UInt64(ssrc), lo: 0) ^ UInt128(hi: index >> 48, lo: index << 16)
        let ivBytes = ivInt.bytesBE
        let ct = pkt.subdata(in: (pkt.startIndex + hdrLen)..<(pkt.startIndex + bodyLen))
        let pt = HPSRTP.aesCTR(key: cipherKey, iv: ivBytes, data: ct)
        return (header, pt)
    }

    private func update(ssrc: UInt32, roc: UInt32, seq: UInt16) {
        var st = states[ssrc] ?? State()
        if !st.inited { st.roc = roc; st.maxSeq = seq; st.inited = true; states[ssrc] = st; return }
        let newFull = UInt64(roc) << 16 | UInt64(seq)
        let curFull = UInt64(st.roc) << 16 | UInt64(st.maxSeq)
        if newFull > curFull { st.roc = roc; st.maxSeq = seq }
        states[ssrc] = st
    }

    /// One of the consecutive-SSRC groups Apple emits (group size = tilesPerFrame).
    func primarySSRCGroup(groupSize: Int = 4) -> [UInt32] {
        guard !counts.isEmpty else { return [] }
        let sorted = counts.keys.sorted()
        var groups: [[UInt32]] = [[sorted[0]]]
        for s in sorted.dropFirst() {
            if s - groups[groups.count - 1].last! <= 1 && groups[groups.count - 1].count < groupSize {
                groups[groups.count - 1].append(s)
            } else { groups.append([s]) }
        }
        groups.sort { $0.map { counts[$0]! }.reduce(0,+) > $1.map { counts[$0]! }.reduce(0,+) }
        return groups.first ?? []
    }
}

enum HPSRTP {
    /// RFC 3711 §4.3.1 KDF: AES-CM with label XORed into IV.
    static func kdf(_ masterKey: Data, _ masterSalt: Data, _ label: UInt8, _ outLen: Int) -> Data {
        var kid = [UInt8](repeating: 0, count: 14); kid[7] = label
        let salt = [UInt8](masterSalt)
        var iv0 = [UInt8](repeating: 0, count: 16)
        for i in 0..<14 { iv0[i] = kid[i] ^ salt[i] }
        var out = Data()
        var counter: UInt16 = 0
        while out.count < outLen {
            var block = iv0
            block[14] = UInt8(counter >> 8); block[15] = UInt8(counter & 0xff)
            out += aesECBBlock(key: masterKey, block: Data(block))
            counter += 1
        }
        return out.prefix(outLen)
    }

    static func aesECBBlock(key: Data, block: Data) -> Data {
        var out = Data(count: 16); var moved = 0
        _ = out.withUnsafeMutableBytes { o in block.withUnsafeBytes { b in key.withUnsafeBytes { k in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    k.baseAddress, key.count, nil, b.baseAddress, 16, o.baseAddress, 16, &moved)
        }}}
        return out
    }

    static func aesCTR(key: Data, iv: Data, data: Data) -> Data {
        var out = Data(count: data.count)
        var cryptor: CCCryptorRef?
        _ = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                    CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count,
                                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        }}
        guard let cryptor else { return out }
        defer { CCCryptorRelease(cryptor) }
        var moved = 0
        let outCap = out.count
        _ = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { d in
            CCCryptorUpdate(cryptor, d.baseAddress, data.count, o.baseAddress, outCap, &moved)
        }}
        return out
    }

    static func hmacSHA1(key: Data, data: Data) -> Data {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { k in data.withUnsafeBytes { d in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), k.baseAddress, key.count, d.baseAddress, data.count, &mac)
        }}
        return Data(mac)
    }
}

/// Minimal unsigned 128-bit for SRTP IV math.
struct UInt128 {
    var hi: UInt64
    var lo: UInt64
    init(hi: UInt64, lo: UInt64) { self.hi = hi; self.lo = lo }
    init(bytes: Data) {
        let b = [UInt8](bytes)
        var h: UInt64 = 0, l: UInt64 = 0
        for i in 0..<8 { h = h << 8 | UInt64(b[i]) }
        for i in 8..<16 { l = l << 8 | UInt64(b[i]) }
        hi = h; lo = l
    }
    static func ^ (a: UInt128, b: UInt128) -> UInt128 { UInt128(hi: a.hi ^ b.hi, lo: a.lo ^ b.lo) }
    static func << (a: UInt128, n: Int) -> UInt128 {
        if n == 0 { return a }
        if n >= 64 { return UInt128(hi: a.lo << (n - 64), lo: 0) }
        return UInt128(hi: (a.hi << n) | (a.lo >> (64 - n)), lo: a.lo << n)
    }
    static func >> (a: UInt128, n: Int) -> UInt128 {
        if n == 0 { return a }
        if n >= 64 { return UInt128(hi: 0, lo: a.hi >> (n - 64)) }
        return UInt128(hi: a.hi >> n, lo: (a.lo >> n) | (a.hi << (64 - n)))
    }
    var bytesBE: Data {
        var d = Data(count: 16)
        for i in 0..<8 { d[i] = UInt8((hi >> (56 - 8*i)) & 0xff) }
        for i in 0..<8 { d[8+i] = UInt8((lo >> (56 - 8*i)) & 0xff) }
        return d
    }
}

/// SRTCP sender/receiver (AES-256-CTR + HMAC-SHA1-80, RFC 3711 labels 3/4/5).
/// Protects/unprotects the RTCP feedback (RR/SR/FIR) the client exchanges.
final class HPSRTCP {
    private let cipherKey: Data   // label 3, 32
    private let authKey: Data     // label 4, 20
    private let salt: [UInt8]     // label 5, 14
    private let authTagLen = 10
    private var index: UInt32 = 0
    private let lock = NSLock()

    init(blob: Data) {
        let mk = blob.prefix(32)
        let ms = blob.subdata(in: (blob.startIndex+32)..<(blob.startIndex+46))
        cipherKey = HPSRTP.kdf(mk, ms, 3, 32)
        authKey = HPSRTP.kdf(mk, ms, 4, 20)
        salt = [UInt8](HPSRTP.kdf(mk, ms, 5, 14))
    }

    private func iv(ssrc: UInt32, index: UInt32) -> Data {
        var iv = salt + [0, 0]
        iv[4] ^= UInt8(ssrc >> 24 & 0xff); iv[5] ^= UInt8(ssrc >> 16 & 0xff)
        iv[6] ^= UInt8(ssrc >> 8 & 0xff);  iv[7] ^= UInt8(ssrc & 0xff)
        iv[10] ^= UInt8(index >> 24 & 0xff); iv[11] ^= UInt8(index >> 16 & 0xff)
        iv[12] ^= UInt8(index >> 8 & 0xff);  iv[13] ^= UInt8(index & 0xff)
        return Data(iv)
    }

    /// Wrap an RTCP packet (SR/RR/FIR/...) as SRTCP for sending.
    func protect(_ rtcp: Data) -> Data {
        lock.lock(); let idx = index; index &+= 1; lock.unlock()
        let hdr = rtcp.prefix(8)
        let pt = rtcp.subdata(in: (rtcp.startIndex+8)..<rtcp.endIndex)
        let ssrc = UInt32(rtcp[rtcp.startIndex+4]) << 24 | UInt32(rtcp[rtcp.startIndex+5]) << 16
                 | UInt32(rtcp[rtcp.startIndex+6]) << 8 | UInt32(rtcp[rtcp.startIndex+7])
        let ct = HPSRTP.aesCTR(key: cipherKey, iv: iv(ssrc: ssrc, index: idx), data: pt)
        let eIndex = Data([UInt8((0x80000000 | idx) >> 24 & 0xff), UInt8(idx >> 16 & 0xff), UInt8(idx >> 8 & 0xff), UInt8(idx & 0xff)])
        var body = Data(hdr) + ct + eIndex
        let tag = HPSRTP.hmacSHA1(key: authKey, data: body).prefix(authTagLen)
        body.append(tag)
        return body
    }

    /// Unprotect a received SRTCP packet → plaintext RTCP, or nil.
    func unprotect(_ pkt: Data) -> Data? {
        guard pkt.count >= 8 + 4 + authTagLen else { return nil }
        let body = pkt.prefix(pkt.count - authTagLen)
        let tag = pkt.suffix(authTagLen)
        guard HPSRTP.hmacSHA1(key: authKey, data: Data(body)).prefix(authTagLen) == Data(tag) else { return nil }
        let b = [UInt8](pkt)
        let eoff = pkt.count - authTagLen - 4
        let eIndex = UInt32(b[eoff]) << 24 | UInt32(b[eoff+1]) << 16 | UInt32(b[eoff+2]) << 8 | UInt32(b[eoff+3])
        let encrypted = (eIndex & 0x80000000) != 0
        let idx = eIndex & 0x7fffffff
        let hdr = pkt.prefix(8)
        let ct = pkt.subdata(in: (pkt.startIndex+8)..<(pkt.startIndex + pkt.count - authTagLen - 4))
        if !encrypted { return Data(hdr) + ct }
        let ssrc = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        let ptext = HPSRTP.aesCTR(key: cipherKey, iv: iv(ssrc: ssrc, index: idx), data: ct)
        return Data(hdr) + ptext
    }
}

/// RTCP feedback builders (RFC 3550/4585/5104 + Apple legacy FIR).
enum HPRTCP {
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

    static func emptyRR(_ ssrc: UInt32) -> Data { Data([0x80, 201] + be16(1) + be32(ssrc)) }

    static func rr(sender: UInt32, sources: [UInt32]) -> Data {
        if sources.isEmpty { return emptyRR(sender) }
        let rc = min(sources.count, 31)
        var d = Data([UInt8(0x80 | rc), 201] + be16(1 + rc*6) + be32(sender))
        for s in sources.prefix(rc) { d += Data(be32(s) + be32(0) + be32(0) + be32(0) + be32(0) + be32(0)) }
        return d
    }

    static func emptySR(_ ssrc: UInt32) -> Data {
        let now = Date().timeIntervalSince1970
        let ntpSec = UInt32((UInt64(now) + 2208988800) & 0xffffffff)
        let ntpFrac = UInt32((now - floor(now)) * 4294967296.0) & 0xffffffff
        let rtpTs = UInt32(UInt64(now * 90000) & 0xffffffff)
        return Data([0x80, 200] + be16(6) + be32(ssrc) + be32(ntpSec) + be32(ntpFrac) + be32(rtpTs) + be32(0) + be32(0))
    }

    /// Legacy FIR (RFC 2032, PT=192) — the keyframe request Apple honours best.
    static func firLegacy(_ target: UInt32) -> Data { Data([0x80, 192] + be16(1) + be32(target)) }

    /// AVPF FIR (RFC 5104, PT=206 FMT 4).
    static func fir(sender: UInt32, target: UInt32, seq: UInt8) -> Data {
        Data([UInt8(0x80 | 4), 206] + be16(4) + be32(sender) + be32(0) + be32(target) + [seq, 0, 0, 0])
    }
}
