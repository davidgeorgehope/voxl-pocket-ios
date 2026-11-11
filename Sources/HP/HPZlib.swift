import Foundation
import Compression

/// zlib (RFC 1950) compress/decompress — the media blob inside the 0x1c
/// offer/answer is zlib-wrapped. Compression.framework gives us raw DEFLATE;
/// we add/strip the 2-byte header and the Adler-32 trailer ourselves.
enum HPZlib {
    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return (b << 16) | a
    }

    static func compress(_ data: Data) -> Data {
        let cap = data.count + 64
        var dst = Data(count: cap)
        let n = dst.withUnsafeMutableBytes { d in
            data.withUnsafeBytes { s in
                compression_encode_buffer(
                    d.baseAddress!.assumingMemoryBound(to: UInt8.self), cap,
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        dst.removeSubrange(n..<dst.count)
        let adler = adler32(data)
        var out = Data([0x78, 0x9c]) + dst
        out.append(contentsOf: [UInt8(adler >> 24 & 0xff), UInt8(adler >> 16 & 0xff),
                                UInt8(adler >> 8 & 0xff), UInt8(adler & 0xff)])
        return out
    }

    /// Inflate a zlib stream (strip 2-byte header + 4-byte trailer → raw DEFLATE).
    static func decompress(_ zlib: Data, expectedMax: Int = 1 << 20) -> Data? {
        guard zlib.count > 6 else { return nil }
        let raw = zlib.subdata(in: (zlib.startIndex + 2)..<(zlib.endIndex - 4))
        var dst = Data(count: expectedMax)
        let n = dst.withUnsafeMutableBytes { d in
            raw.withUnsafeBytes { s in
                compression_decode_buffer(
                    d.baseAddress!.assumingMemoryBound(to: UInt8.self), expectedMax,
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        dst.removeSubrange(n..<dst.count)
        return dst
    }
}
