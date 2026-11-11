import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Direct VideoToolbox HEVC decoder for one tile stream. Builds a format
/// description from VPS/SPS/PPS and decodes length-prefixed (4-byte) access
/// units, requesting 4:4:4 (nv24 / '444f') output. Reports whether the session
/// is hardware-accelerated.
final class HPVTDecoder {
    static let nv24Format: OSType = 0x34343466  // kCVPixelFormatType_444YpCbCr8BiPlanarFullRange

    private var fmt: CMFormatDescription?
    private var session: VTDecompressionSession?
    private(set) var usingHardware = false
    private(set) var lastError: OSStatus = noErr

    struct Decoded { let pixelBuffer: CVPixelBuffer; let width: Int; let height: Int; let pixelFormat: OSType }
    private var latest: Decoded?

    /// Build format desc + session. `requireHardware` forces a HW decoder
    /// (create fails if unavailable) — used to answer the 4:4:4 HW question.
    @discardableResult
    func setParams(vps: Data, sps: Data, pps: Data, requireHardware: Bool = false) -> Bool {
        teardown()
        var fmtOut: CMFormatDescription?
        let st: OSStatus = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            let ptrs: [UnsafePointer<UInt8>] = [
                v.baseAddress!.assumingMemoryBound(to: UInt8.self),
                s.baseAddress!.assumingMemoryBound(to: UInt8.self),
                p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
            let sizes = [vps.count, sps.count, pps.count]
            return ptrs.withUnsafeBufferPointer { pp in sizes.withUnsafeBufferPointer { ss in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 3,
                    parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmtOut)
            }}
        }}}
        lastError = st
        guard st == noErr, let fmtOut else { return false }
        fmt = fmtOut

        let destAttrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: HPVTDecoder.nv24Format]
        var spec: [CFString: Any] = [:]
        if requireHardware {
            spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
        }
        var cb = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer, let refCon else { return }
                let me = Unmanaged<HPVTDecoder>.fromOpaque(refCon).takeUnretainedValue()
                let w = CVPixelBufferGetWidth(imageBuffer), h = CVPixelBufferGetHeight(imageBuffer)
                me.latest = Decoded(pixelBuffer: imageBuffer, width: w, height: h,
                                    pixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer))
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var sess: VTDecompressionSession?
        let cst = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: fmtOut,
            decoderSpecification: spec.isEmpty ? nil : (spec as CFDictionary),
            imageBufferAttributes: destAttrs as CFDictionary,
            outputCallback: &cb, decompressionSessionOut: &sess)
        lastError = cst
        guard cst == noErr, let sess else { return false }
        session = sess
        if let v = try? sess.hardwareAccelerated { usingHardware = v }
        return true
    }

    /// Decode one access unit (concatenated 4-byte-length-prefixed NALUs).
    @discardableResult
    func decode(accessUnit: Data) -> Decoded? {
        guard let session, let fmt else { return nil }
        latest = nil
        var bb: CMBlockBuffer?
        var mutable = accessUnit
        let n = mutable.count
        let ok = mutable.withUnsafeMutableBytes { raw -> Bool in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: raw.baseAddress, blockLength: n,
                blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0,
                dataLength: n, flags: 0, blockBufferOut: &bb) == noErr
        }
        guard ok, let bb else { return nil }
        var sb: CMSampleBuffer?
        var sizes = [n]
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sb) == noErr,
            let sb else { return nil }
        var flagsOut = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], frameRefcon: nil,
            infoFlagsOut: &flagsOut)
        lastError = st
        if st == noErr { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        return latest
    }

    func teardown() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil; fmt = nil
    }
    deinit { teardown() }
}

private extension VTDecompressionSession {
    var hardwareAccelerated: Bool {
        get throws {
            var cf: Unmanaged<CFTypeRef>?
            let st = VTSessionCopyProperty(self,
                key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: kCFAllocatorDefault, valueOut: &cf)
            if st == noErr, let v = cf?.takeRetainedValue(), CFGetTypeID(v) == CFBooleanGetTypeID() {
                return CFBooleanGetValue((v as! CFBoolean))
            }
            return false
        }
    }
}
