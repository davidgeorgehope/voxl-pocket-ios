import AVFoundation
import VideoToolbox

/// What this device's hardware decodes, checked once by decoding real HEVC samples
/// (4:2:0 and 4:4:4 keyframes made by a Mac's VideoToolbox encoder, in Samples/)
/// with a hardware-only VTDecompressionSession. Decides which codec to ask for.
enum DecoderCheck {
    struct Result {
        var hevcHW = false      // VTIsHardwareDecodeSupported(HEVC)
        var hevc420 = false     // the 4:2:0 sample decoded in hardware
        var hevc444 = false     // the 4:4:4 sample decoded in hardware
        var detail = ""
    }

    static let result: Result = run()

    /// Codecs to ask the host for, best first. A 4:4:4 stream the display layer turned
    /// out not to show (see `RemoteViewController`) is not asked for again.
    static var preferred: [String] {
        var c: [String] = []
        if result.hevc444 && !UserDefaults.standard.bool(forKey: "hevc444Broken") { c.append("hevc444") }
        if result.hevc420 { c.append("hevc") }
        c.append("h264")
        return c
    }

    private static func run() -> Result {
        var r = Result()
        r.hevcHW = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let (ok420, d420) = decode(sample: "sample420")
        let (ok444, d444) = decode(sample: "sample444")
        r.hevc420 = r.hevcHW && ok420
        r.hevc444 = r.hevcHW && ok444
        r.detail = "hw=\(r.hevcHW) 420:\(d420) 444:\(d444)"
        return r
    }

    static func fourcc(_ v: OSType) -> String {
        let b = [v >> 24, v >> 16, v >> 8, v].map { UInt8($0 & 0xff) }
        return String(bytes: b, encoding: .ascii) ?? "\(v)"
    }

    /// Decodes the sample's keyframe on the hardware decoder only.
    static func decode(sample: String) -> (Bool, String) {
        guard let url = Bundle.main.url(forResource: sample, withExtension: "h265"),
              let data = try? Data(contentsOf: url) else { return (false, "no sample") }
        var vps: Data?, sps: Data?, pps: Data?
        var avcc = Data()
        for nal in Stripe.nals(data) {
            switch (nal.first! >> 1) & 0x3f {
            case 32: vps = nal
            case 33: sps = nal
            case 34: pps = nal
            default:
                var n = UInt32(nal.count).bigEndian
                avcc.append(Data(bytes: &n, count: 4)); avcc.append(nal)
            }
        }
        guard let vps, let sps, let pps, let fmt = Stripe.makeHEVCFormat(vps, sps, pps),
              let sb = Stripe.sample(avcc, fmt) else { return (false, "bad sample") }
        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        var session: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: spec,
                                              imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        guard st == noErr, let session else { return (false, "no hw session (\(st))") }
        defer { VTDecompressionSessionInvalidate(session) }
        var result = (false, "no frame")
        let dst = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image {
                result = (true, "ok \(fourcc(CVPixelBufferGetPixelFormatType(image)))")
            } else {
                result = (false, "decode error \(status)")
            }
        }
        if dst != noErr { return (false, "decode call \(dst)") }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return result
    }
}
