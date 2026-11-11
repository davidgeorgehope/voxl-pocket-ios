import Foundation

/// Minimal protobuf wire encoder/decoder for the AVCMediaStreamNegotiator
/// media blob. Only the field types Apple's offer uses.
enum PB {
    static func varint(_ v: UInt64) -> Data {
        var x = v; var out = Data()
        while x > 0x7f { out.append(UInt8((x & 0x7f) | 0x80)); x >>= 7 }
        out.append(UInt8(x & 0x7f))
        return out
    }
    static func fieldVarint(_ field: Int, _ value: UInt64) -> Data {
        varint(UInt64(field << 3 | 0)) + varint(value)
    }
    static func fieldBytes(_ field: Int, _ value: Data) -> Data {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value
    }

    /// Read a varint at `pos`; returns (value, newPos).
    static func readVarint(_ d: Data, _ pos: Int) -> (UInt64, Int) {
        var val: UInt64 = 0, shift: UInt64 = 0, p = pos
        while p < d.endIndex {
            let b = d[p]; p += 1
            val |= UInt64(b & 0x7f) << shift
            shift += 7
            if b & 0x80 == 0 { break }
        }
        return (val, p)
    }
}
