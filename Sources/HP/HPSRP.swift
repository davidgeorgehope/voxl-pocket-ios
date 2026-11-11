import Foundation
import BigInt

/// Apple's SRP-RFC5054-4096-SHA512 with SALTED-SHA512-PBKDF2 password
/// expansion, as used by screensharingd (macOS 15+). Clean-room port of the
/// documented wire math; computed, not copied.
enum HPSRP {
    static let hashLen = 64        // SHA-512
    static let modulusLen = 512    // 4096 bits / 8
    static let pbkdf2DKLen = 128   // bytes

    struct Challenge {
        let N: BigUInt
        let Nb: Data      // N as 512-byte big-endian
        let g: BigUInt
        let salt: Data
        let B: BigUInt
        let Bb: Data
        let iterations: Int
        let cap: Data
    }

    struct Proof {
        let A: BigUInt
        let Ab: Data      // 512-byte BE
        let M1: Data      // 64 bytes
        let K: Data       // SHA-512(S)
    }

    enum SRPError: Error { case parse(String) }

    /// Parse the s2c1 challenge body (1165 bytes, fixed shape).
    static func parseChallenge(_ s2c1: Data) throws -> Challenge {
        let b = [UInt8](s2c1)
        var p = 12
        guard b.count > p, b[p] == 0 else { throw SRPError.parse("missing DER zero marker at 12") }
        p += 1
        let Nb = Data(b[p..<p + modulusLen]); p += modulusLen
        let gLen = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
        let g = BigUInt(Data(b[p..<p + gLen])); p += gLen
        let saltLen = Int(b[p]); p += 1
        let salt = Data(b[p..<p + saltLen]); p += saltLen
        let BLen = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
        let Bb = Data(b[p..<p + BLen]); p += BLen
        var iters = 0
        for i in 0..<8 { iters = iters << 8 | Int(b[p + i]) }
        p += 8
        let capLen = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
        let cap = Data(b[p..<p + capLen])
        guard Nb.count == modulusLen else { throw SRPError.parse("modulus not 4096-bit") }
        guard iters <= 1_000_000 else { throw SRPError.parse("iteration count too high") }
        return Challenge(N: BigUInt(Nb), Nb: Nb, g: g, salt: salt,
                         B: BigUInt(Bb), Bb: Bb, iterations: iters, cap: cap)
    }

    /// Apple's SALTED-SHA512-PBKDF2 x derivation:
    ///   dk    = PBKDF2-HMAC-SHA512(password, salt, iterations, 128)
    ///   inner = SHA512(":" || dk)           (empty username before ':')
    ///   x     = SHA512(salt || inner)
    static func deriveX(salt: Data, iterations: Int, password: String) -> BigUInt {
        let pw = Data(password.utf8)
        let dk = HPCrypto.pbkdf2SHA512(password: pw, salt: salt, iterations: iterations, length: pbkdf2DKLen)
        let inner = HPCrypto.sha512(Data([0x3a]) + dk)   // ":" = 0x3a
        return BigUInt(HPCrypto.sha512(salt + inner))
    }

    private static func padded(_ x: BigUInt, _ len: Int) -> Data {
        var d = x.serialize()
        if d.count < len { d = Data(count: len - d.count) + d }
        return d
    }

    /// Run SRP-6a. `aOverride` lets tests pin the ephemeral; nil = random.
    static func solve(_ c: Challenge, password: String, aOverride: BigUInt? = nil) -> Proof {
        let KL = modulusLen
        let gPadded = padded(c.g, KL)
        let k = BigUInt(HPCrypto.sha512(c.Nb + gPadded))

        let a: BigUInt
        if let o = aOverride { a = o } else {
            var rnd = Data(count: 64)
            _ = rnd.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 64, $0.baseAddress!) }
            a = BigUInt(rnd) % (c.N - 1) + 1
        }
        let A = c.g.power(a, modulus: c.N)
        let Ab = padded(A, KL)

        let u = BigUInt(HPCrypto.sha512(Ab + c.Bb))
        let x = deriveX(salt: c.salt, iterations: c.iterations, password: password) % c.N

        // S = (B - k*g^x)^(a + u*x) mod N
        let gx = c.g.power(x, modulus: c.N)
        let base = (c.B + c.N - (k * gx) % c.N) % c.N
        let S = base.power(a + u * x, modulus: c.N)
        let K = HPCrypto.sha512(padded(S, KL))

        // M1 = H( H(N) XOR H(g) || H("") || salt || A || B || K )
        let hN = HPCrypto.sha512(c.Nb)
        let hG = HPCrypto.sha512(gPadded)
        var xorNG = Data(count: hashLen)
        for i in 0..<hashLen { xorNG[i] = hN[i] ^ hG[i] }
        let m1 = HPCrypto.sha512(xorNG + HPCrypto.sha512(Data()) + c.salt + Ab + c.Bb + K)
        return Proof(A: A, Ab: Ab, M1: m1, K: K)
    }
}
