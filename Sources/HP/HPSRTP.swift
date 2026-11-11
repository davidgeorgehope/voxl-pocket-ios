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
