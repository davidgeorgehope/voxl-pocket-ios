import Foundation

/// HEVC NAL reassembly from Apple's RTP payload format (RFC 7798 with Apple's
/// DONL deviations: AP has one 2-byte DONL after the header; FU carries a
/// 2-byte DONL in every fragment; single NAL has a leading 2-byte DONL).
enum HPNALU {
    static let NAL_VPS = 32, NAL_SPS = 33, NAL_PPS = 34, NAL_AP = 48, NAL_FU = 49
    static let IDR_RANGE = 16...21

    static func nalType(_ nalu: Data) -> Int { nalu.count >= 2 ? Int((nalu[nalu.startIndex] >> 1) & 0x3f) : -1 }

    /// pps_pic_parameter_set_id: the first ue(v) after the 2-byte NAL header.
    static func ppsID(_ nalu: Data) -> Int {
        let b = [UInt8](nalu.dropFirst(2).prefix(8))
        var bit = 0
        func next() -> Int? { guard bit / 8 < b.count else { return nil }; let v = Int(b[bit / 8] >> (7 - UInt8(bit % 8))) & 1; bit += 1; return v }
        var zeros = 0
        while let v = next(), v == 0 { zeros += 1; if zeros > 16 { return 0 } }
        var val = 0
        for _ in 0..<zeros { guard let v = next() else { return 0 }; val = val << 1 | v }
        return (1 << zeros) - 1 + val
    }

    /// Reassemble the RTP payloads belonging to one timestamp group into NALUs.
    static func reassembleGroup(_ payloads: [Data]) -> [Data] {
        var out: [Data] = []
        var fu = Data(); var fuActive = false
        for pay in payloads {
            guard pay.count >= 2 else { continue }
            let p = [UInt8](pay)
            let nt = Int((p[0] >> 1) & 0x3f)
            if nt == NAL_AP {
                var pos = 4
                let n = p.count
                while pos + 2 <= n {
                    let size = Int(p[pos]) << 8 | Int(p[pos+1]); pos += 2
                    if size == 0 || pos + size > n { break }
                    out.append(Data(p[pos..<pos+size])); pos += size
                }
            } else if nt == NAL_FU {
                if pay.count < 6 { continue }
                let fuHdr = p[2]
                let start = fuHdr & 0x80 != 0, end = fuHdr & 0x40 != 0
                let innerType = fuHdr & 0x3f
                if start {
                    let hdr0 = (p[0] & 0x81) | (innerType << 1)
                    fu = Data([hdr0, p[1]]); fu.append(Data(p[5...])); fuActive = true
                } else if fuActive {
                    fu.append(Data(p[5...]))
                    if end { out.append(fu); fuActive = false }
                }
            } else {
                if pay.count < 4 { continue }
                out.append(Data(p[0..<2]) + Data(p[4...]))
            }
        }
        return out
    }
}
