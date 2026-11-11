import Foundation

/// enc1103: Apple's RFB control-channel stream cipher (AES-128-CBC with a
/// per-direction counter and a plain-SHA1 tag). Built from the 36-byte 1103
/// encoding blob the server sends after auth. Clean-room port.
///
/// Wire record:  u16 BE ciphertext_length | ciphertext (×16)
/// Plaintext:    u16 BE msg_length | msg | zero-pad | SHA1(u32be(ctr) || all-before-mac)
final class HPStreamCipher {
    private let macLen = 20
    private let block = 16
    private let window = 6

    let cbcKey: Data
    private var encIV: Data
    private var decIV: Data
    private var encCtr: UInt32 = 0
    private var decCtr: UInt32 = 0
    private let lock = NSLock()

    /// `blob` is the 36-byte 1103 body; `ecbKey` is the 16-byte SRP-derived key.
    init?(blob: Data, ecbKey: Data) {
        guard blob.count == 36 else { return nil }
        cbcKey = HPCrypto.aesECB(blob.subdata(in: 4..<20), key: ecbKey, encrypt: false)
        let iv = HPCrypto.aesECB(blob.subdata(in: 20..<36), key: ecbKey, encrypt: false)
        encIV = iv
        decIV = iv
    }

    private func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }
    private func be16(_ v: Int) -> Data { Data([UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }

    /// Encrypt one control message (RFB body) into a framed record.
    func encrypt(_ plaintext: Data) -> Data {
        lock.lock(); defer { lock.unlock() }
        let ctr = encCtr
        let pad = (-(2 + plaintext.count + macLen)) % block
        let padN = (pad + block) % block
        var framed = be16(plaintext.count) + plaintext + Data(count: padN)
        let mac = HPCrypto.sha1(be32(ctr) + framed)
        framed += mac
        // CBC chains across records: use the running IV, then carry the last block.
        let ct = HPCrypto.aesCBC(framed, key: cbcKey, iv: encIV, encrypt: true)
        encIV = ct.suffix(block)
        encCtr = ctr &+ 1
        return be16(ct.count) + ct
    }

    /// Decrypt one ciphertext block. Returns inner RFB body, or nil on MAC miss.
    func decryptRecord(_ ciphertext: Data) -> Data? {
        lock.lock()
        let pt = HPCrypto.aesCBC(ciphertext, key: cbcKey, iv: decIV, encrypt: false)
        decIV = ciphertext.suffix(block)
        let ctrStart = decCtr
        decCtr &+= 1
        lock.unlock()
        if ciphertext.count <= macLen { return pt }
        let body = pt.prefix(pt.count - macLen)
        let mac = pt.suffix(macLen)
        let lo = Int(ctrStart) - 1
        for c in max(0, lo)...(Int(ctrStart) + window) {
            if mac == HPCrypto.sha1(be32(UInt32(c)) + Data(body)) {
                lock.lock(); decCtr = UInt32(c) + 1; lock.unlock()
                let n = Int(body[body.startIndex]) << 8 | Int(body[body.startIndex + 1])
                return Data(body[(body.startIndex + 2)..<(body.startIndex + 2 + n)])
            }
        }
        return nil
    }

    /// Decrypt as many framed records as fit; returns (messages, bytesConsumed).
    func decryptStream(_ data: Data) -> ([Data], Int) {
        var out: [Data] = []
        var pos = data.startIndex
        while pos + 2 <= data.endIndex {
            let len = Int(data[pos]) << 8 | Int(data[pos + 1])
            if len == 0 || len % block != 0 || pos + 2 + len > data.endIndex { break }
            if let m = decryptRecord(data.subdata(in: (pos + 2)..<(pos + 2 + len))) { out.append(m) }
            pos += 2 + len
        }
        return (out, pos - data.startIndex)
    }
}
