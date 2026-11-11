import Foundation

/// AVCMediaStreamNegotiator offer builder. Produces the (video, audio) binary
/// plists embedded in the 0x1c message. Clean-room rebuild of the documented
/// protobuf shape; default is Apple's "both" codec order (server picks HEVC
/// 4:4:4). `forceAVC` requests the H.264 4:2:0 fallback bank.
enum HPOffers {
    static let tilesPerFrame = 4

    private static let audioF9Tiers: [(Int, UInt64, Int?)] = [
        (0, 40_000_000, 12288), (0, 6_000_000, 131072), (4074, 0, 16384),
        (16, 4100, nil), (0, 75_000_000, 524288), (0, 20_000_000, 98304),
        (4, 6500, nil), (0, 60_000_000, 262144), (1, 299, nil),
        (0, 100_000_000, 1048576),
    ]
    private static func audioF9() -> Data {
        var out = Data()
        for (f1, f2, f3) in audioF9Tiers {
            var body = Data([0x08]) + PB.varint(UInt64(f1)) + Data([0x10]) + PB.varint(f2)
            if let f3 { body += Data([0x18]) + PB.varint(UInt64(f3)) }
            out += Data([0x4a]) + PB.varint(UInt64(body.count)) + body
        }
        return out
    }

    private static let hevcParamsLTR = Data("FLS;MS:-1;LF:-1;LTR;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;".utf8)
    private static let avcParams = Data("FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;AR:16/9,5/8;XR:16/9,5/8;".utf8)

    private static func remoteEndpointInfo() -> Data {
        func str(_ tag: UInt8, _ s: String) -> Data { let b = Data(s.utf8.prefix(127)); return Data([tag, UInt8(b.count)]) + b }
        return Data([0x08,0x00, 0x10,0x01]) + str(0x1A, "Generic") + str(0x22, "1.0.0") + str(0x2A, "0")
    }

    private static func mediaBlob(mode: Int, sessionId: UInt64, timestamp: UInt64,
                                  audioEnabled: Bool, forceAVC: Bool) -> Data {
        var descField = Data()
        if mode == 7 {
            let ltrpOn = !forceAVC
            let resA = PB.fieldVarint(1,1)+PB.fieldVarint(2,1)+PB.fieldVarint(3,50115)+PB.fieldVarint(4,0)
            let resB = PB.fieldVarint(1,1)+PB.fieldVarint(2,2)+PB.fieldVarint(3,50115)+PB.fieldVarint(4,0)
            let hevcBank = PB.fieldVarint(1,123) + PB.fieldBytes(2,resA)+PB.fieldBytes(2,resB)
                + PB.fieldBytes(2,resA)+PB.fieldBytes(2,resB) + PB.fieldBytes(3,hevcParamsLTR) + PB.fieldVarint(4,1)
            let avcBank = PB.fieldVarint(1,100) + PB.fieldBytes(2,resA)+PB.fieldBytes(2,resB)
                + PB.fieldBytes(3,avcParams) + PB.fieldVarint(4,14)
            // INVERTED mapping (verified in reference): field1=123 bank -> server sends H.264;
            // field1=100 bank -> server sends HEVC 4:4:4. "both" = 123 then 100 (server picks HEVC).
            let banks: Data = forceAVC ? PB.fieldBytes(3, hevcBank)
                                       : (PB.fieldBytes(3, hevcBank) + PB.fieldBytes(3, avcBank))
            var desc = PB.fieldVarint(1, sessionId) + PB.fieldVarint(2, ltrpOn ? 1 : 0)
            desc += banks
            desc += PB.fieldVarint(6, UInt64(tilesPerFrame)) + PB.fieldVarint(7, ltrpOn ? 1 : 0)
            desc += PB.fieldVarint(8, 63) + PB.fieldVarint(9, 1) + PB.fieldVarint(12, 1)
            descField = PB.fieldBytes(5, desc)
        } else { // mode 8 (audio)
            let f4: UInt64 = audioEnabled ? 24191 : 1000
            let desc = PB.fieldVarint(1, sessionId) + PB.fieldVarint(2,0) + PB.fieldVarint(3,0)
                + PB.fieldVarint(4, f4) + PB.fieldVarint(5,0) + PB.fieldVarint(6,0)
            descField = PB.fieldBytes(3, desc)
        }
        var out = PB.fieldVarint(1,1) + PB.fieldVarint(2,1) + descField
        out += PB.fieldBytes(6, Data("iShareScreen 0.0".utf8))
        out += PB.fieldVarint(8, 0) + audioF9() + PB.fieldVarint(13, timestamp)
        out += PB.fieldVarint(14,2) + PB.fieldVarint(16,0) + PB.fieldVarint(18,1)
        return out
    }

    private static func plist(mode: Int, audioEnabled: Bool, forceAVC: Bool) -> (Data, UInt32) {
        var sid = Data(count: 4)
        _ = sid.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        let sessionId = UInt64(sid[0]) << 24 | UInt64(sid[1]) << 16 | UInt64(sid[2]) << 8 | UInt64(sid[3])
        let ts = UInt64(Date().timeIntervalSince1970 * 1e9)
        let blob = mediaBlob(mode: mode, sessionId: sessionId, timestamp: ts,
                             audioEnabled: audioEnabled, forceAVC: forceAVC)
        let dict: [String: Any] = [
            "avcMediaStreamOptionRemoteEndpointInfo": remoteEndpointInfo(),
            "avcMediaStreamNegotiatorMode": mode,
            "avcMediaStreamNegotiatorMediaBlob": HPZlib.compress(blob),
            "avcMediaStreamOptionCallID": UUID().uuidString.uppercased(),
        ]
        let data = (try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)) ?? Data()
        return (data, UInt32(truncatingIfNeeded: sessionId))
    }

    /// (videoOffer, audioOffer)
    static func create(audioEnabled: Bool = true, forceAVC: Bool = false) -> (Data, Data) {
        let o = createWithSSRCs(audioEnabled: audioEnabled, forceAVC: forceAVC)
        return (o.video, o.audio)
    }

    /// Offers plus the SSRCs they advertise. The offer's session id IS our
    /// media SSRC: the host accepts RTCP/RTP only from these (video: field
    /// 5→1, audio: field 3→1); anything else times the session out.
    static func createWithSSRCs(audioEnabled: Bool = true, forceAVC: Bool = false)
        -> (video: Data, audio: Data, videoSSRC: UInt32, audioSSRC: UInt32) {
        let v = plist(mode: 7, audioEnabled: audioEnabled, forceAVC: forceAVC)
        let a = plist(mode: 8, audioEnabled: audioEnabled, forceAVC: forceAVC)
        return (v.0, a.0, v.1, a.1)
    }

    /// Re-read our advertised SSRC from a built offer (self-test cross-check).
    static func offerSSRC(_ offer: Data, isVideo: Bool) -> UInt32? {
        guard let pl = try? PropertyListSerialization.propertyList(from: offer, options: [], format: nil) as? [String: Any],
              let z = pl["avcMediaStreamNegotiatorMediaBlob"] as? Data, let blob = HPZlib.decompress(z) else { return nil }
        let target = isVideo ? 5 : 3
        var pos = blob.startIndex
        while pos < blob.endIndex {
            let (tag, p1) = PB.readVarint(blob, pos); pos = p1
            let fn = Int(tag >> 3), wt = Int(tag & 7)
            if wt == 0 { pos = PB.readVarint(blob, pos).1 }
            else if wt == 2 {
                let (ln, p2) = PB.readVarint(blob, pos)
                if fn == target {
                    let (itag, q) = PB.readVarint(blob, p2)
                    if itag == 0x08 { return UInt32(truncatingIfNeeded: PB.readVarint(blob, q).0) }
                }
                pos = p2 + Int(ln)
            } else if wt == 1 { pos += 8 } else if wt == 5 { pos += 4 } else { break }
        }
        return nil
    }

    /// Parse the server's 0x1c answer msg (0x00 FBU carrying an embedded bplist)
    /// for (canvasW, canvasH, tiles). Returns nil if not present/parseable.
    static func canvasDims(_ msg: Data) -> (Int, Int, Int)? {
        guard let first = msg.first, first == 0x00 else { return nil }
        let bytes = [UInt8](msg)
        let needle = Array("bplist".utf8)
        // The 0x1c video answer can contain several embedded bplists (e.g. a
        // remote-endpoint-info blob before the AVCMediaStreamNegotiator video
        // config). Walk every "bplist" occurrence until one yields canvas dims,
        // mirroring the reference's `idx += 6` scan.
        var searchFrom = 0
        while true {
            var start = -1
            if needle.count <= bytes.count {
                for i in searchFrom...(bytes.count - needle.count) where Array(bytes[i..<i+needle.count]) == needle {
                    start = i; break
                }
            }
            guard start >= 0 else { return nil }
            searchFrom = start + needle.count
            if let dims = dimsFromBplist(bytes, start: start) { return dims }
        }
    }

    /// Try to parse one embedded bplist starting at `start` into canvas dims.
    private static func dimsFromBplist(_ bytes: [UInt8], start: Int) -> (Int, Int, Int)? {
        var dict: [String: Any]?
        var e = start + 8
        while e <= bytes.count {
            let sub = Data(bytes[start..<e])
            if let o = try? PropertyListSerialization.propertyList(from: sub, options: [], format: nil),
               let d = o as? [String: Any], d["avcMediaStreamNegotiatorMediaBlob"] != nil {
                dict = d; break
            }
            e += 1
        }
        guard let dict, let blob = dict["avcMediaStreamNegotiatorMediaBlob"] as? Data,
              let dec = HPZlib.decompress(blob) else { return nil }
        var pos = dec.startIndex
        var cw = 0, ch = 0, ct = 0
        while pos < dec.endIndex {
            let (tag, p1) = PB.readVarint(dec, pos); pos = p1
            let fn = Int(tag >> 3), wt = Int(tag & 7)
            if wt == 0 { let (_, p2) = PB.readVarint(dec, pos); pos = p2 }
            else if wt == 2 {
                let (ln, p2) = PB.readVarint(dec, pos); pos = p2
                let end = pos + Int(ln)
                if fn == 5 {
                    var sp = pos
                    while sp < end {
                        let (st, q1) = PB.readVarint(dec, sp); sp = q1
                        let sf = Int(st >> 3), sw = Int(st & 7)
                        if sw == 0 { let (v, q2) = PB.readVarint(dec, sp); sp = q2
                            if sf == 4 { cw = Int(v) } else if sf == 5 { ch = Int(v) } else if sf == 6 { ct = Int(v) }
                        } else if sw == 2 { let (sl, q2) = PB.readVarint(dec, sp); sp = q2 + Int(sl) }
                        else if sw == 1 { sp += 8 } else if sw == 5 { sp += 4 } else { break }
                    }
                }
                pos = end
            } else if wt == 1 { pos += 8 } else if wt == 5 { pos += 4 } else { break }
        }
        return (cw != 0 && ch != 0) ? (cw, ch, ct) : nil
    }
}
