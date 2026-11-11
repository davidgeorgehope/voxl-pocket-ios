import Foundation

/// RFB message builders + the full HP negotiation that runs after SRP auth:
/// plaintext ViewerInfo/VirtualDisplay/SetEncodings, live enc1103 bring-up,
/// then the encrypted media offer (0x1c) and its canvas-dims answer.
enum HPNeg {
    static let encodings: [Int32] = [1010, 1011, 1002, 6, 16, 1104, 1100, -223, 1101, 1105, 1107, 1109, 1110]

    static func setEncodings() -> Data {
        var d = Data([0x02, 0x00]); let c = encodings.count
        d.append(contentsOf: [UInt8(c >> 8), UInt8(c & 0xff)])
        for e in encodings { let u = UInt32(bitPattern: e)
            d.append(contentsOf: [UInt8(u >> 24 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)]) }
        return d
    }

    static func commandMask() -> Data {
        var m = [UInt8](repeating: 0, count: 32)
        m[0] = 0xb0; m[2] = 0x0c; m[3] = 0x03; m[4] = 0x90; m[10] = 0x40
        return Data(m)
    }

    static func viewerInfo() -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        var h: [UInt8] = [0x21, 0x00]
        h += u16(0x3E)                       // msgSize
        h += u16(1)                          // msgVersion
        h += u32(2)                          // app_id
        h += u32(6) + u32(1) + u32(0)        // app_ver
        h += u32(15) + u32(3) + u32(0)       // os_ver
        return Data(h) + commandMask()
    }

    static func followup0x12() -> Data {
        Data([0x12, 0x00, 0x00,0x01, 0x00,0x01, 0x00,0x01, 0x00,0x00,0x00,0x01])
    }
    static func postEncryptionToggle() -> Data { Data([0x12,0x00,0x00,0x02,0x00,0x01,0x00,0x00]) }

    static func fbuRequest(incremental: Bool) -> Data {
        Data([0x03, incremental ? 1 : 0, 0,0, 0,0, 0xff,0xff, 0xff,0xff])
    }

    static func virtualDisplay(width: Int = 1920, height: Int = 1080, hidpiScale: Double = 2.0) -> Data {
        let modeCount = 5
        let diSize = 0x9C + 28 * modeCount
        var di = [UInt8](repeating: 0, count: diSize)
        func pH(_ o: Int, _ v: Int) { di[o] = UInt8(v >> 8 & 0xff); di[o+1] = UInt8(v & 0xff) }
        func pI(_ o: Int, _ v: UInt32) { di[o] = UInt8(v >> 24 & 0xff); di[o+1] = UInt8(v >> 16 & 0xff); di[o+2] = UInt8(v >> 8 & 0xff); di[o+3] = UInt8(v & 0xff) }
        func pF(_ o: Int, _ v: Float) { pI(o, v.bitPattern) }
        func pD(_ o: Int, _ v: Double) { let b = v.bitPattern; for i in 0..<8 { di[o+i] = UInt8((b >> (56 - 8*i)) & 0xff) } }
        pH(0x00, diSize)
        let name = Array("iShareScreen Virtual Display".utf8.prefix(119))
        for (i, b) in name.enumerated() { di[0x02 + i] = b }
        pI(0x7A, 1)     // display_flags = DYNAMIC_RESOLUTION
        pI(0x7E, 4)     // display_type = virtual
        pF(0x82, 369.4545593261719)
        pF(0x86, 207.81817626953125)
        pI(0x8A, 3840); pI(0x8E, 2160)   // max w/h
        pH(0x92, 0); pH(0x94, 0)
        pI(0x96, 7)
        pH(0x9A, modeCount)
        let nativeModes = [(3840,2160,1920,1080),(2880,1800,1440,900),(3840,2160,1920,1080),(2880,1620,1440,810),(2624,1696,1312,848)]
        let sx = width != 0 ? Double(width) / 1920.0 : 1.0
        let sy = height != 0 ? Double(height) / 1080.0 : 1.0
        for i in 0..<modeCount {
            let base = nativeModes[i % nativeModes.count]
            let msw = Int(Double(base.2) * sx + 0.5), msh = Int(Double(base.3) * sy + 0.5)
            let mw = Int(Double(msw) * hidpiScale + 0.5), mh = Int(Double(msh) * hidpiScale + 0.5)
            let m = 0x9C + 28 * i
            pI(m, UInt32(mw)); pI(m+4, UInt32(mh)); pI(m+8, UInt32(msw)); pI(m+12, UInt32(msh))
            pD(m+0x10, 60.0); pI(m+0x18, 0)
        }
        let msgSize = 8 + diSize
        func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        var head: [UInt8] = [0x1d, 0x00]
        head += u16(msgSize) + u16(1) + u16(1) + [0,0,0,0]  // msgSize, ver=1, ?=1, u32 0
        return Data(head) + Data(di)
    }

    struct Negotiated { let cipher: HPStreamCipher; let videoKeyS: Data; let audioKeyS: Data
                        let canvasW: Int; let canvasH: Int; let tiles: Int }

    /// Full negotiation from a freshly-authed socket (post-ServerInit).
    static func negotiate(_ s: HPSocket, ecbKey: Data, forceAVC: Bool = false) throws -> Negotiated {
        // plaintext phase
        try s.send(viewerInfo() + followup0x12())
        Thread.sleep(forTimeInterval: 0.1)
        try s.send(virtualDisplay())
        try s.send(setEncodings())

        // read until enc1103 1103 entry
        var init_ = Data()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let chunk = s.recvSome(65536)
            if chunk.isEmpty { if !init_.isEmpty { break } else { continue } }
            init_ += chunk
            if init_.count > 40 { break }
        }
        guard let cipher = parseEnc1103(init_, ecbKey: ecbKey) else {
            throw HPRFB.RFBError.handshake("server did not advertise enc1103 (rate-limited? retry)")
        }
        try s.send(postEncryptionToggle())
        Thread.sleep(forTimeInterval: 0.2)
        // Rolling RX buffer: enc1103 CBC framing requires contiguous bytes, so
        // we never drop a partial record -- we keep the unconsumed tail and
        // feed subsequent reads into the same decryptStream call.
        var rx = Data()
        drainInto(&rx, s, cipher)   // advance recv counter past post-toggle traffic

        // encrypted media offer
        try s.send(cipher.encrypt(setEncodings()))
        let (videoOffer, audioOffer) = HPOffers.create(audioEnabled: true, forceAVC: forceAVC)
        let vkv = randBlob(), vks = randBlob(), akv = randBlob(), aks = randBlob()
        let msg1c = build0x1c(audioOffer: audioOffer, videoOffer: videoOffer, akv: akv, aks: aks, vkv: vkv, vks: vks)
        try s.send(cipher.encrypt(msg1c))
        try s.send(cipher.encrypt(fbuRequest(incremental: false)))

        var canvas: (Int, Int, Int)? = readCanvas(&rx, s, cipher)
        var attempts = 0
        while canvas == nil && attempts < 16 {
            Thread.sleep(forTimeInterval: 0.2)
            try s.send(cipher.encrypt(msg1c))
            canvas = readCanvas(&rx, s, cipher)
            attempts += 1
        }
        let (cw, ch, ct) = canvas ?? (0, 0, 0)
        return Negotiated(cipher: cipher, videoKeyS: vks, audioKeyS: aks, canvasW: cw, canvasH: ch, tiles: ct)
    }

    private static func randBlob() -> Data {
        var d = Data(count: HPSRTPDecryptor.keyBlobLen)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, HPSRTPDecryptor.keyBlobLen, $0.baseAddress!) }
        return d
    }

    static func build0x1c(audioOffer: Data, videoOffer: Data, akv: Data, aks: Data, vkv: Data, vks: Data) -> Data {
        let AS = audioOffer.count, VS = videoOffer.count, MS = AS + VS + 0xD8
        var buf = [UInt8](repeating: 0, count: MS + 4)
        func pH(_ o: Int, _ v: Int) { buf[o] = UInt8(v >> 8 & 0xff); buf[o+1] = UInt8(v & 0xff) }
        func pI(_ o: Int, _ v: UInt32) { buf[o] = UInt8(v >> 24 & 0xff); buf[o+1] = UInt8(v >> 16 & 0xff); buf[o+2] = UInt8(v >> 8 & 0xff); buf[o+3] = UInt8(v & 0xff) }
        buf[0] = 0x1C
        pH(2, MS); pH(4, 3); pI(6, 7); pH(10, AS); pH(12, VS)
        var uuid = UUID().uuid
        withUnsafeBytes(of: &uuid) { for i in 0..<16 { buf[0x14 + i] = $0[i] } }
        func put(_ o: Int, _ d: Data) { for (i, b) in d.enumerated() { buf[o + i] = b } }
        put(0x24, akv); put(0x52, aks); put(0x80, audioOffer)
        let vo = 0x80 + AS
        put(vo, vkv); put(vo + 0x2E, vks); put(vo + 0x5C, videoOffer)
        return Data(buf)
    }

    private static func parseEnc1103(_ init_: Data, ecbKey: Data) -> HPStreamCipher? {
        let b = [UInt8](init_); var pos = 0
        while pos < b.count {
            if b[pos] == 0x14 && pos + 8 <= b.count { pos += 8; continue }
            if b[pos] == 0x00 && pos + 4 <= b.count {
                let nRects = Int(b[pos+2]) << 8 | Int(b[pos+3]); var p = pos + 4
                for _ in 0..<nRects {
                    if p + 12 > b.count { break }
                    let enc = Int32(bitPattern: UInt32(b[p+8]) << 24 | UInt32(b[p+9]) << 16 | UInt32(b[p+10]) << 8 | UInt32(b[p+11]))
                    p += 12
                    if enc == 1103 && p + 36 <= b.count {
                        return HPStreamCipher(blob: Data(b[p..<p+36]), ecbKey: ecbKey)
                    } else if (enc == 1010 || enc == 1011) && p + 2 <= b.count {
                        let sz = Int(b[p]) << 8 | Int(b[p+1]); p += 2 + sz
                    } else { break }
                }
                break
            }
            break
        }
        return nil
    }

    /// Read one batch and advance the cipher recv counter, preserving any
    /// partial-record tail in `rx`.
    private static func drainInto(_ rx: inout Data, _ s: HPSocket, _ cipher: HPStreamCipher) {
        for _ in 0..<4 { let c = s.recvSome(65536); if c.isEmpty { break }; rx += c }
        let (_, consumed) = cipher.decryptStream(rx)
        rx.removeSubrange(rx.startIndex..<(rx.startIndex + consumed))
    }

    /// Read into the rolling buffer, decrypt whole records, keep the tail, and
    /// return canvas dims if any decrypted msg carries them.
    private static func readCanvas(_ rx: inout Data, _ s: HPSocket, _ cipher: HPStreamCipher) -> (Int, Int, Int)? {
        for _ in 0..<8 {
            let c = s.recvSome(65536)
            if c.isEmpty { break }
            rx += c
            if rx.count > 100 { break }
        }
        guard !rx.isEmpty else { return nil }
        let (msgs, consumed) = cipher.decryptStream(rx)
        rx.removeSubrange(rx.startIndex..<(rx.startIndex + consumed))
        for m in msgs { if let d = HPOffers.canvasDims(m) { return d } }
        return nil
    }
}
