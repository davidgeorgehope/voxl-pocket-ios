import AVFoundation
import UIKit

/// A small JSON file (Documents/diag.json) with what the decoder check and the last
/// session saw, readable from a Mac with `devicectl device copy from` (no secrets).
enum Diagnostics {
    private static var values: [String: String] = [:]

    static func note(_ key: String, _ value: String) {
        DispatchQueue.main.async {
            values[key] = value
            values["updated"] = ISO8601DateFormatter().string(from: Date())
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? data.write(to: dir.appendingPathComponent("diag.json"))
        }
    }

    /// Launched with VOXL_SELFTEST=1: shows the 4:4:4 sample on an AVSampleBufferDisplayLayer
    /// and records whether it was displayed (and in which pixel format).
    static func displayTest(in window: UIWindow) {
        note("decoder", DecoderCheck.result.detail)
        note("preferred", DecoderCheck.preferred.joined(separator: ","))
        for (name, file) in [("display444", "sample444"), ("display420", "sample420")] {
            guard let url = Bundle.main.url(forResource: file, withExtension: "h265"),
                  let data = try? Data(contentsOf: url) else { continue }
            let st = Stripe(y: name == "display444" ? 0 : 150, height: 144, width: 256)
            st.codec = "hevc"
            window.layer.addSublayer(st.layer)
            st.waitingKey = false
            let ok = st.decode(data)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let r = st.layer.sampleBufferRenderer
                var fmt = "none"
                if let pb = r.displayedPixelBuffer() {
                    fmt = DecoderCheck.fourcc(CVPixelBufferGetPixelFormatType(pb)) + " \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"
                }
                note(name, "enqueued=\(ok) status=\(r.status == .failed ? "failed" : "ok") shown=\(fmt) err=\(r.error.map { "\($0)" } ?? "-")")
                st.layer.removeFromSuperlayer()
            }
        }
    }
}
