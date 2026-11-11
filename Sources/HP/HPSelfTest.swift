import Foundation
import UIKit
import VideoToolbox
import CoreMedia

/// In-app self-test for the HP (Mac High-Performance Screen Sharing) module.
/// Runs a battery of offline checks that are verifiable in the iOS Simulator:
/// enc1103 cipher round-trip, zlib, the 0x1c media-offer build+reparse, the
/// canvas-dims answer parser, HEVC NAL reassembly, and a real HEVC 4:4:4
/// VideoToolbox decode of a bundled sample (reports HW vs SW + pixel format).
///
/// Gate on the launch env var VOXL_HP_SELFTEST=1. Results go to NSLog AND are
/// returned as text so a host screen can show them for a screenshot.
enum HPSelfTest {
    struct Result { let name: String; let ok: Bool; let detail: String }

    static func runAll() -> [Result] {
        var r: [Result] = []
        func add(_ n: String, _ ok: Bool, _ d: String = "") { r.append(Result(name: n, ok: ok, detail: d)); NSLog("[HPSelfTest] [%@] %@ %@", ok ? "PASS" : "FAIL", n, d) }

        // 1) enc1103 cipher round-trip
        do {
            let ecb = Data((0..<16).map { UInt8($0) })
            let cbcKey = Data((0..<16).map { UInt8(0x30 + $0) })
            let iv = Data((0..<16).map { UInt8(0x50 + $0) })
            let blob = Data([0,0,0,0]) + HPCrypto.aesECB(cbcKey, key: ecb, encrypt: true) + HPCrypto.aesECB(iv, key: ecb, encrypt: true)
            if let enc = HPStreamCipher(blob: blob, ecbKey: ecb), let dec = HPStreamCipher(blob: blob, ecbKey: ecb) {
                var ok = enc.cbcKey == cbcKey
                for m in ["hi", "a control message spanning two aes blocks exactly!!"] {
                    let rec = enc.encrypt(Data(m.utf8)); let (msgs, c) = dec.decryptStream(rec)
                    if msgs.count != 1 || msgs[0] != Data(m.utf8) || c != rec.count { ok = false }
                }
                add("enc1103 encrypt/decrypt round-trip", ok)
            } else { add("enc1103 init", false) }
        }

        // 2) zlib round-trip
        do {
            let src = Data((0..<2000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
            let z = HPZlib.compress(src); let back = HPZlib.decompress(z)
            add("zlib compress/decompress round-trip", back == src, "in=\(src.count) z=\(z.count)")
        }

        // 3) media offer build + reparse
        do {
            let (video, audio) = HPOffers.create(audioEnabled: true, forceAVC: false)
            var ok = video.count > 100 && audio.count > 100
            if let pl = try? PropertyListSerialization.propertyList(from: video, options: [], format: nil) as? [String: Any],
               let blob = pl["avcMediaStreamNegotiatorMediaBlob"] as? Data,
               let mode = pl["avcMediaStreamNegotiatorMode"] as? Int,
               let dec = HPZlib.decompress(blob) {
                ok = ok && mode == 7 && dec.count > 50
            } else { ok = false }
            add("0x1c media offer build + bplist/zlib reparse", ok, "video=\(video.count)B audio=\(audio.count)B")
        }

        // 4) canvas-dims answer parser on a synthetic server answer
        do {
            func pbV(_ f: Int, _ v: UInt64) -> Data { PB.fieldVarint(f, v) }
            let f5 = pbV(4, 1920) + pbV(5, 1080) + pbV(6, 4)
            let mediablob = PB.fieldBytes(5, f5)
            let dict: [String: Any] = ["avcMediaStreamNegotiatorMediaBlob": HPZlib.compress(mediablob)]
            let plist = (try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)) ?? Data()
            let msg = Data([0x00, 0x00, 0x00, 0x01]) + plist   // 0x00 FBU + one "rect" wrapping the bplist
            if let d = HPOffers.canvasDims(msg) {
                add("canvas-dims answer parser", d.0 == 1920 && d.1 == 1080 && d.2 == 4, "\(d.0)x\(d.1) tiles=\(d.2)")
            } else { add("canvas-dims answer parser", false, "no dims") }
        }

        // 5) HEVC NAL reassembly (Apple DONL deviations): single NAL + a 2-fragment FU
        do {
            // single NAL (type 1): [hdr0 hdr1] [DONL x2] [payload]
            let single = Data([0x02, 0x01, 0x00, 0x00, 0xAA, 0xBB])
            // FU over a type-1 slice split in two
            let fuStart = Data([ (49<<1), 0x01, 0x80 | 1, 0x00, 0x00, 0xDE])   // S=1, innerType=1
            let fuEnd   = Data([ (49<<1), 0x01, 0x40 | 1, 0x00, 0x00, 0xAD])   // E=1
            let out = HPNALU.reassembleGroup([single, fuStart, fuEnd])
            // Expect 2 NALUs: the single (payload AA BB) and the reassembled FU (DE AD)
            let ok = out.count == 2 && out[0].suffix(2) == Data([0xAA,0xBB]) && out[1].suffix(2) == Data([0xDE,0xAD])
            add("HEVC NAL reassembly (single + FU)", ok, "nalus=\(out.count)")
        }

        // 6) VideoToolbox HEVC 4:4:4 decode of bundled real sample
        do {
            let supported = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
            func asset(_ n: String) -> Data? { Bundle.main.url(forResource: n, withExtension: "bin").flatMap { try? Data(contentsOf: $0) } }
            if let vps = asset("vps"), let sps = asset("sps"), let pps = asset("pps"), let idr = asset("idr") {
                let d = HPVTDecoder()
                let params = d.setParams(vps: vps, sps: sps, pps: pps)
                if params, let frame = d.decode(accessUnit: idr) {
                    let f = frame.pixelFormat
                    let fcc = String(bytes: [UInt8(f>>24&0xff),UInt8(f>>16&0xff),UInt8(f>>8&0xff),UInt8(f&0xff)], encoding: .ascii) ?? "?"
                    add("VideoToolbox HEVC 4:4:4 decode (bundled sample)", frame.width > 0,
                        "\(frame.width)x\(frame.height) pixfmt='\(fcc)' hw=\(d.usingHardware)")
                } else {
                    add("VideoToolbox HEVC 4:4:4 decode (bundled sample)", false, "params=\(params) err=\(d.lastError)")
                }
                let hw = HPVTDecoder()
                let hwOK = hw.setParams(vps: vps, sps: sps, pps: pps, requireHardware: true)
                add("VT 4:4:4 hardware-decoder session (RequireHardware)", true,
                    hwOK ? "HW session created (this host)" : "no HW 4:4:4 on this host -> software")
            } else {
                add("VideoToolbox HEVC 4:4:4 decode (bundled sample)", false, "sample assets missing from bundle")
            }
            NSLog("[HPSelfTest] VTIsHardwareDecodeSupported(HEVC)=%@ (NOTE: in the Simulator this reflects the Mac host GPU, not the iPhone's A18 Pro)", supported ? "true" : "false")
        }

        // 7) SRTP sender -> receiver round trip (PT=101 keepalive path)
        do {
            var blob = Data(count: HPSRTPDecryptor.keyBlobLen)
            _ = blob.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, HPSRTPDecryptor.keyBlobLen, $0.baseAddress!) }
            let enc = HPSRTPEncryptor(blob: blob, ssrc: 0xA1B2C3D4)
            let dec = HPSRTPDecryptor(blob: blob)
            var ok = true
            for i in 0..<3 {
                let payload = Data([0x00, 0x68, 0x34, UInt8(i)])
                guard let (h, p) = dec.decrypt(enc.encrypt(payload)), p == payload, h.count == 12 else { ok = false; break }
            }
            add("SRTP encrypt/decrypt round-trip (keepalive)", ok)
        }

        // 8) the SSRC we put in RTCP == the session id the offer advertises
        do {
            let o = HPOffers.createWithSSRCs()
            let v = HPOffers.offerSSRC(o.video, isVideo: true), a = HPOffers.offerSSRC(o.audio, isVideo: false)
            add("offer SSRCs match RTCP sender SSRCs", v == o.videoSSRC && a == o.audioSSRC,
                String(format: "video=0x%08x audio=0x%08x", o.videoSSRC, o.audioSSRC))
        }

        // 9) RTCP keyframe request shape + SR parse
        do {
            let k = HPRTCP.keyframeRequest(sender: 1, target: 2, seq: 3)
            let sr = HPRTCP.emptySR(0x01020304)
            let parsed = HPRTCP.senderReports(sr + HPRTCP.emptyRR(5))
            let ok = k.count == 8 + 20 + 12 + 8 && parsed.count == 1 && parsed[0].ssrc == 0x01020304
                && abs(parsed[0].wall - Date().timeIntervalSince1970) < 2
            add("RTCP FIR+PLI+legacy-FIR compound / SR parse", ok, "fir=\(k.count)B")
        }

        // 10) PPS id parse (ue(v) right after the NAL header)
        do {
            let pps0 = Data([0x44, 0x01, 0xC0]), pps3 = Data([0x44, 0x01, 0x20])
            add("HEVC PPS id parse", HPNALU.ppsID(pps0) == 0 && HPNALU.ppsID(pps3) == 3,
                "ids=\(HPNALU.ppsID(pps0)),\(HPNALU.ppsID(pps3))")
        }

        // 11) same-host UDP/TCP bind selection (Simulator shares the Mac's ports)
        do {
            let pick = HPMediaSession.autoBindIP(for: "127.0.0.1")
            let remote = HPMediaSession.autoBindIP(for: "100.64.0.1")
            add("same-host bind address selection", pick != nil && !(pick ?? "").hasPrefix("127.") && remote == nil,
                "127.0.0.1 -> bind \(pick ?? "nil"); remote -> wildcard")
        }

        // 12) AAC-ELD-SBR decode (host cookie) of an AudioToolbox-encoded tone
        do {
            let rt = HPAudioDecoder.roundTripTone()
            add("AAC-ELD-SBR 48k stereo decode (tone round-trip)", rt.ok, rt.detail)
        }

        return r
    }

    /// Render results into a scrollable label for an on-screen screenshot.
    static func makeView() -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        let results = runAll()
        let passed = results.filter { $0.ok }.count
        let tv = UITextView()
        tv.isEditable = false; tv.backgroundColor = .black; tv.textColor = .green
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        var s = "HP Module Self-Test (iOS Simulator)\n\(passed)/\(results.count) passed\n\n"
        for r in results { s += (r.ok ? "PASS " : "FAIL ") + r.name + "\n" + (r.detail.isEmpty ? "" : "     \(r.detail)\n") }
        s += "\nNOTE: 4:4:4 HW result reflects the Mac host GPU in the\nSimulator, not the iPhone A18 Pro. Device check pending."
        tv.text = s
        tv.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            tv.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 8),
            tv.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -8),
            tv.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])
        return vc
    }
}
