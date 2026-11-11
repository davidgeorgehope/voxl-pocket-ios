import AVFoundation

/// Desktop audio: the host's Opus packets (48 kHz stereo, 10 ms each, message 0x02)
/// decoded with AudioToolbox's Opus decoder and played through AVAudioEngine.
/// Packets that would queue more than ~120 ms are dropped, so audio stays live
/// instead of drifting behind the picture.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pcm = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private let opus: AVAudioFormat = {
        var d = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                            mBytesPerPacket: 0, mFramesPerPacket: 480, mBytesPerFrame: 0,
                                            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &d)!
    }()
    private lazy var converter = AVAudioConverter(from: opus, to: pcm)
    private let q = DispatchQueue(label: "voxl.audio")
    private var queued = 0 // frames scheduled but not yet played (on q)
    private var running = false
    private(set) var packets = 0, dropped = 0, failed = 0

    private static let maxQueued = 48000 * 12 / 100

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcm)
    }

    func start() {
        q.async { [self] in
            guard !running else { return }
            do {
                let s = AVAudioSession.sharedInstance()
                try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try s.setPreferredIOBufferDuration(0.005)
                try s.setActive(true)
                try engine.start()
                player.play()
                running = true
            } catch {
                NSLog("voxl audio: \(error)")
            }
        }
    }

    func stop() {
        q.async { [self] in
            guard running else { return }
            player.stop()
            engine.stop()
            queued = 0
            running = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// One Opus packet from the host.
    func enqueue(_ packet: Data) {
        q.async { [self] in
            guard running, !packet.isEmpty, let converter else { return }
            packets += 1
            if queued > Self.maxQueued { dropped += 1; return }
            let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: max(packet.count, 1500))
            packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
            input.byteLength = UInt32(packet.count)
            input.packetCount = 1
            input.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                        mDataByteSize: UInt32(packet.count))
            guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 960) else { return }
            var fed = false
            var err: NSError?
            let st = converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            guard st != .error, out.frameLength > 0 else { failed += 1; return }
            let n = Int(out.frameLength)
            queued += n
            player.scheduleBuffer(out) { [weak self] in
                guard let self else { return }
                self.q.async { self.queued = max(0, self.queued - n) }
            }
        }
    }
}
