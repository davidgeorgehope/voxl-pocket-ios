import Foundation
import Security
import BigInt

/// Minimal blocking transport the control-plane handshake runs over. Backed by
/// a POSIX socket here (works on iOS and macOS alike); a Network.framework
/// adapter can conform to the same surface later.
final class HPSocket {
    private var fd: Int32 = -1
    enum SockError: Error { case resolve, connect, io(String) }

    func connect(host: String, port: UInt16, timeoutSec: Int = 15) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { throw SockError.resolve }
        defer { freeaddrinfo(res) }
        var ai: UnsafeMutablePointer<addrinfo>? = info
        while let cur = ai {
            let s = socket(cur.pointee.ai_family, cur.pointee.ai_socktype, cur.pointee.ai_protocol)
            if s >= 0 {
                if Foundation.connect(s, cur.pointee.ai_addr, cur.pointee.ai_addrlen) == 0 {
                    fd = s
                    var one: Int32 = 1
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    return
                }
                Darwin.close(s)
            }
            ai = cur.pointee.ai_next
        }
        throw SockError.connect
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            let base = raw.baseAddress!
            while off < data.count {
                let n = Foundation.send(fd, base + off, data.count - off, 0)
                if n <= 0 { throw SockError.io("send") }
                off += n
            }
        }
    }

    func recvExact(_ n: Int) throws -> Data {
        var buf = Data(); buf.reserveCapacity(n)
        var tmp = [UInt8](repeating: 0, count: 65536)
        while buf.count < n {
            let want = min(n - buf.count, tmp.count)
            let got = tmp.withUnsafeMutableBytes { Foundation.recv(fd, $0.baseAddress, want, 0) }
            if got <= 0 { throw SockError.io("peer closed during recvExact") }
            buf.append(contentsOf: tmp[0..<got])
        }
        return buf
    }

    func recvSome(_ n: Int) -> Data {
        var tmp = [UInt8](repeating: 0, count: n)
        let got = tmp.withUnsafeMutableBytes { Foundation.recv(fd, $0.baseAddress, n, 0) }
        return got > 0 ? Data(tmp[0..<got]) : Data()
    }

    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
}

enum HPRFB {
    static let protocolVersion = Data("RFB 003.889\n".utf8)

    enum RFBError: Error { case handshake(String), rsa(String), auth(String) }

    private static func be32(_ d: Data, _ o: Int) -> UInt32 {
        (UInt32(d[d.startIndex + o]) << 24) | (UInt32(d[d.startIndex + o + 1]) << 16)
            | (UInt32(d[d.startIndex + o + 2]) << 8) | UInt32(d[d.startIndex + o + 3])
    }
    private static func u32be(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }
    private static func u16be(_ v: Int) -> Data { Data([UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }

    // MARK: DER / RSA

    /// Extract the PKCS#1 RSAPublicKey DER from a SubjectPublicKeyInfo DER by
    /// walking to the BIT STRING and dropping its leading unused-bits byte.
    static func pkcs1FromSPKI(_ spki: Data) throws -> Data {
        let b = [UInt8](spki)
        var i = 0
        func readTLV() throws -> (tag: UInt8, valueStart: Int, length: Int) {
            guard i < b.count else { throw RFBError.rsa("der eof") }
            let tag = b[i]; i += 1
            guard i < b.count else { throw RFBError.rsa("der eof len") }
            var len = Int(b[i]); i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7f; len = 0
                for _ in 0..<n { len = len << 8 | Int(b[i]); i += 1 }
            }
            return (tag, i, len)
        }
        let outer = try readTLV()                 // SEQUENCE (SPKI)
        guard outer.tag == 0x30 else { throw RFBError.rsa("spki not sequence") }
        let algo = try readTLV()                  // SEQUENCE (AlgorithmIdentifier)
        guard algo.tag == 0x30 else { throw RFBError.rsa("algid not sequence") }
        i = algo.valueStart + algo.length         // skip AlgorithmIdentifier
        let bitstr = try readTLV()                 // BIT STRING
        guard bitstr.tag == 0x03 else { throw RFBError.rsa("no bit string") }
        // first content byte = unused bits count (expect 0)
        return Data(b[(bitstr.valueStart + 1)..<(bitstr.valueStart + bitstr.length)])
    }

    static func rsaEncryptPKCS1(_ plaintext: Data, pkcs1PubDER: Data) throws -> Data {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1PubDER as CFData, attrs as CFDictionary, &err) else {
            throw RFBError.rsa("SecKeyCreateWithData: \(err.map { String(describing: $0.takeRetainedValue()) } ?? "nil")")
        }
        guard let ct = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plaintext as CFData, &err) else {
            throw RFBError.rsa("encrypt: \(err.map { String(describing: $0.takeRetainedValue()) } ?? "nil")")
        }
        return ct as Data
    }

    // MARK: handshake

    struct HandshakeResult { let width: Int; let height: Int; let ecbKey: Data }

    /// Version handshake + security types. Returns the raw security-type bytes.
    static func doVersionHandshake(_ s: HPSocket) throws -> Data {
        _ = try s.recvExact(12)
        try s.send(protocolVersion)
        let nt = try s.recvExact(1)
        let count = Int(nt[nt.startIndex])
        guard count > 0 else { throw RFBError.handshake("no security types") }
        return try s.recvExact(count)
    }

    /// Send auth-type 0x21 selection + empty RSA1 init, read server pubkey.
    static func rsa1Init(_ s: HPSocket) throws -> Data {
        try s.send(Data([0x21]) + Data([0x00, 0x00, 0x00, 0x0a, 0x01, 0x00]) + Data("RSA1".utf8) + Data([0,0,0,0]))
        let lenD = try s.recvExact(4)
        let pktLen = Int(be32(lenD, 0))
        let pkt = try s.recvExact(pktLen)
        let keyLen = Int(be32(pkt, 2))
        let spki = pkt.subdata(in: (pkt.startIndex + 6)..<(pkt.startIndex + 6 + keyLen))
        return try pkcs1FromSPKI(spki)
    }

    /// Full SRP auth. Returns 16-byte enc1103 master key = SHA256(K)[:16].
    static func doSRPAuth(_ s: HPSocket, username: String, password: String,
                          aOverride: BigUInt? = nil) throws -> Data {
        let pkcs1 = try rsa1Init(s)

        // c2s1: username RSA-encrypted into the modulus slot.
        let userB = Data(username.utf8)
        let inner = u32be(UInt32(userB.count)) + userB + Data([0,0,0])
        let payload = u32be(UInt32(inner.count)) + inner
        let encrypted = try rsaEncryptPKCS1(payload, pkcs1PubDER: pkcs1)
        guard encrypted.count == 256 else { throw RFBError.rsa("rsa block \(encrypted.count) != 256") }
        var c2s1 = Data([0x01, 0x00]) + Data("RSA1".utf8) + Data([0x00, 0x02])
        c2s1 += u16be(256) + encrypted + Data(count: 384)
        try s.send(u32be(650) + c2s1)

        // s2c1 challenge
        let chLenD = try s.recvExact(4)
        let chLen = Int(be32(chLenD, 0))
        guard chLen >= 1000 else { throw RFBError.auth("challenge too short (\(chLen)); non-SRP fallback") }
        let s2c1 = try s.recvExact(chLen)
        let challenge = try HPSRP.parseChallenge(s2c1)

        // solve + c2s2
        let proof = HPSRP.solve(challenge, password: password, aOverride: aOverride)
        var civ = Data(count: 16)
        _ = civ.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        var sd = u16be(HPSRP.modulusLen) + proof.Ab
        sd += Data([UInt8(HPSRP.hashLen)]) + proof.M1
        sd += u16be(challenge.cap.count) + challenge.cap
        sd += Data([16]) + civ
        var pay = Data([0x01, 0x00]) + Data("RSA1".utf8) + Data([0x00, 0x02])
        pay += u16be(sd.count + 4) + u32be(UInt32(sd.count)) + sd
        if pay.count < 1076 { pay += Data(count: 1076 - pay.count) }
        try s.send(u32be(1076) + pay)

        // M2 + result
        let m2LenD = try s.recvExact(4)
        let m2Len = Int(be32(m2LenD, 0))
        _ = try s.recvExact(m2Len)
        let resultD = try s.recvExact(4)
        let result = be32(resultD, 0)
        guard result == 0 else { throw RFBError.auth("SRP rejected result=\(result)") }
        return HPCrypto.sha256(proof.K).prefix(16)
    }

    /// ClientInit (shared) + read ServerInit. Returns (width, height).
    static func clientInit(_ s: HPSocket) throws -> (Int, Int) {
        try s.send(Data([0xc1]))
        let head = try s.recvExact(24)
        let w = Int(head[head.startIndex]) << 8 | Int(head[head.startIndex + 1])
        let h = Int(head[head.startIndex + 2]) << 8 | Int(head[head.startIndex + 3])
        let nameLen = Int(be32(head, 20))
        if nameLen > 0 { _ = try s.recvExact(nameLen) }
        return (w, h)
    }

    /// Drive version + SRP auth + ServerInit. Proves the full native crypto path.
    static func connectThroughServerInit(host: String, port: UInt16,
                                         username: String, password: String) throws -> HandshakeResult {
        let s = HPSocket()
        try s.connect(host: host, port: port)
        defer { s.close() }
        _ = try doVersionHandshake(s)
        let ecbKey = try doSRPAuth(s, username: username, password: password)
        let (w, h) = try clientInit(s)
        return HandshakeResult(width: w, height: h, ecbKey: ecbKey)
    }
}
