import Foundation
import CryptoKit
import CommonCrypto

/// Low-level crypto primitives for the Apple High Performance Screen Sharing
/// control plane. Clean-room Swift; no third-party code copied.
enum HPCrypto {
    static func sha512(_ d: Data) -> Data { Data(SHA512.hash(data: d)) }
    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }
    static func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }

    /// PBKDF2-HMAC-SHA512(password, salt, iterations) -> `length` bytes.
    static func pbkdf2SHA512(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        var out = Data(count: length)
        let rc = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { pwPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        UInt32(iterations),
                        outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        precondition(rc == kCCSuccess, "PBKDF2 failed: \(rc)")
        return out
    }

    /// AES-128 ECB, no padding. Block-aligned input required.
    static func aesECB(_ data: Data, key: Data, encrypt: Bool) -> Data {
        aes(data, key: key, iv: Data(count: kCCBlockSizeAES128), encrypt: encrypt, ecb: true)
    }

    /// AES-128 CBC, no padding, explicit IV.
    static func aesCBC(_ data: Data, key: Data, iv: Data, encrypt: Bool) -> Data {
        aes(data, key: key, iv: iv, encrypt: encrypt, ecb: false)
    }

    private static func aes(_ data: Data, key: Data, iv: Data, encrypt: Bool, ecb: Bool) -> Data {
        let op = encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        let options: CCOptions = ecb ? CCOptions(kCCOptionECBMode) : 0
        let outCap = data.count + kCCBlockSizeAES128
        var out = Data(count: outCap)
        var moved = 0
        let rc = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), options,
                                keyPtr.baseAddress, key.count,
                                ecb ? nil : ivPtr.baseAddress,
                                inPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCap, &moved)
                    }
                }
            }
        }
        precondition(rc == kCCSuccess, "AES failed: \(rc)")
        out.removeSubrange(moved..<out.count)
        return out
    }
}
