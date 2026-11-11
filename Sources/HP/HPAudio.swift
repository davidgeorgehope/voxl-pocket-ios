import Foundation
import AudioToolbox
import AVFoundation

/// AAC-ELD-SBR (48 kHz stereo, 480-sample frames) decoder for the host's PT=101
/// system-audio RTP. One raw access unit per RTP packet, no AU headers; the
/// stream's MPEG-4 ES_Descriptor magic cookie is static for this codec config.
/// Decodes with AudioToolbox and (optionally) plays through AVAudioEngine.
final class HPAudioDecoder {
    static let sampleRate = 48_000.0
    static let channels: UInt32 = 2
    static let framesPerPacket: UInt32 = 480
    /// ES_Descriptor wrapping AudioSpecificConfig f8e65132e000 (AOT 39 ELD, 48k, stereo, 480, LD-SBR).
    static let magicCookie: [UInt8] = [
        0x03,0x80,0x80,0x80,0x26,0x00,0x00,0x00,0x04,0x80,0x80,0x80,0x18,0x40,0x14,0x00,
        0x18,0x00,0x00,0x01,0x38,0x80,0x00,0x00,0x00,0x00,0x05,0x80,0x80,0x80,0x06,0xf8,
        0xe6,0x51,0x32,0xe0,0x00,0x06,0x80,0x80,0x80,0x01,0x02]

    private var converter: AudioConverterRef?
    private var pending: Data?
    private let inBuf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    private let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private(set) var decodedFrames = 0
    private(set) var lastRMS: Float = 0
    private(set) var peakRMS: Float = 0
    private(set) var lastStatus: OSStatus = noErr

    init?() {
        var inFmt = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatMPEG4AAC_ELD_SBR, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: Self.framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: Self.channels, mBitsPerChannel: 0, mReserved: 0)
        var outFmt = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: Self.channels * 4, mFramesPerPacket: 1, mBytesPerFrame: Self.channels * 4,
            mChannelsPerFrame: Self.channels, mBitsPerChannel: 32, mReserved: 0)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&inFmt, &outFmt, &conv) == noErr, let conv else { return nil }
        var cookie = Self.magicCookie
        let st = AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), &cookie)
        guard st == noErr else { AudioConverterDispose(conv); return nil }
        converter = conv
    }
    deinit {
        if let c = converter { AudioConverterDispose(c) }
        inBuf.deallocate(); desc.deallocate()
    }

    /// Decode one AU → interleaved float32 stereo (≤480 frames), nil while priming.
    func decode(_ au: Data) -> [Float]? {
        guard let converter, !au.isEmpty, au.count <= 4096 else { return nil }
        pending = au
        var out = [Float](repeating: 0, count: Int(Self.framesPerPacket * Self.channels))
        var nPackets: UInt32 = Self.framesPerPacket
        let st: OSStatus = out.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: Self.channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            let st = AudioConverterFillComplexBuffer(converter, { _, ioN, ioData, outDesc, user in
                let me = Unmanaged<HPAudioDecoder>.fromOpaque(user!).takeUnretainedValue()
                guard let pkt = me.pending else { ioN.pointee = 0; return 1 }   // 1 = "no more input now"
                me.pending = nil
                pkt.withUnsafeBytes { me.inBuf.copyMemory(from: $0.baseAddress!, byteCount: pkt.count) }
                ioData.pointee.mBuffers.mData = me.inBuf
                ioData.pointee.mBuffers.mDataByteSize = UInt32(pkt.count)
                ioData.pointee.mBuffers.mNumberChannels = HPAudioDecoder.channels
                me.desc.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(pkt.count))
                if let outDesc { outDesc.pointee = me.desc }
                ioN.pointee = 1
                return noErr
            }, Unmanaged.passUnretained(self).toOpaque(), &nPackets, &abl, nil)
            return st
        }
        lastStatus = st
        guard (st == noErr || st == 1), nPackets > 0 else { return nil }
        let n = Int(nPackets * Self.channels)
        let pcm = Array(out.prefix(n))
        var acc: Float = 0; for s in pcm { acc += s * s }
        lastRMS = (acc / Float(max(n, 1))).squareRoot()
        peakRMS = max(peakRMS, lastRMS)
        decodedFrames += Int(nPackets)
        return pcm
    }
}

/// Minimal low-latency PCM sink: AVAudioEngine + player node fed 20 ms buffers.
final class HPAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: HPAudioDecoder.sampleRate, channels: 2)!
    private var started = false
    private var queued = 0
    private let lock = NSLock()

    func start() {
        guard !started else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.005)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start(); node.play(); started = true } catch { started = false }
    }

    func stop() { if started { node.stop(); engine.stop(); started = false } }

    /// Enqueue interleaved stereo float32; drops when >120 ms is already queued
    /// so latency can't build up behind a stall.
    func play(interleaved pcm: [Float]) {
        guard started else { return }
        lock.lock(); let q = queued; lock.unlock()
        if q > 6 { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = frames
        for i in 0..<Int(frames) { ch[0][i] = pcm[2*i]; ch[1][i] = pcm[2*i + 1] }
        lock.lock(); queued += 1; lock.unlock()
        node.scheduleBuffer(buf) { [weak self] in guard let self else { return }; self.lock.lock(); self.queued -= 1; self.lock.unlock() }
    }
}

extension HPAudioDecoder {
    /// Offline check: AudioToolbox-encode a 1 kHz stereo tone to AAC-ELD-SBR
    /// (480-frame packets) and decode it back through this decoder (host cookie).
    static func roundTripTone(packets: Int = 50) -> (ok: Bool, detail: String) {
        var inFmt = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var outFmt = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC_ELD_SBR,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var enc: AudioConverterRef?
        guard AudioConverterNew(&inFmt, &outFmt, &enc) == noErr, let enc else { return (false, "no AAC-ELD encoder") }
        defer { AudioConverterDispose(enc) }
        guard let dec = HPAudioDecoder() else { return (false, "decoder init failed") }

        final class Src { var phase = 0.0; var buf = [Float](repeating: 0, count: 960) }
        let src = Src()
        var outRMS: [Float] = []
        var aus = 0
        let outCap = 2048
        let outBuf = UnsafeMutableRawPointer.allocate(byteCount: outCap, alignment: 16); defer { outBuf.deallocate() }
        for _ in 0..<packets {
            var n: UInt32 = 1
            var desc = AudioStreamPacketDescription()
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outCap), mData: outBuf))
            let st = AudioConverterFillComplexBuffer(enc, { _, ioN, ioData, _, user in
                let s = Unmanaged<Src>.fromOpaque(user!).takeUnretainedValue()
                for i in 0..<480 {
                    let v = Float(sin(s.phase) * 0.5); s.phase += 2 * .pi * 1000 / 48000
                    s.buf[2*i] = v; s.buf[2*i+1] = v
                }
                s.buf.withUnsafeMutableBytes { ioData.pointee.mBuffers.mData = $0.baseAddress }
                ioData.pointee.mBuffers.mDataByteSize = UInt32(960 * 4)
                ioData.pointee.mBuffers.mNumberChannels = 2
                ioN.pointee = 480
                return noErr
            }, Unmanaged.passUnretained(src).toOpaque(), &n, &abl, &desc)
            guard st == noErr, n > 0 else { continue }
            aus += 1
            let au = Data(bytes: outBuf, count: Int(abl.mBuffers.mDataByteSize))
            if dec.decode(au) != nil { outRMS.append(dec.lastRMS) }
        }
        let tail = outRMS.suffix(20)
        let rms = tail.isEmpty ? 0 : tail.reduce(0, +) / Float(tail.count)
        // a 0.5-amplitude sine has RMS ~0.354
        return (rms > 0.15, String(format: "AUs=%d decoded=%d rms=%.3f (expect ~0.35)", aus, outRMS.count, rms))
    }
}
