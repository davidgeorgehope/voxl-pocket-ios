# Mac Screen Sharing (High Performance) mode — status

Native client for macOS built-in Screen Sharing ("High Performance" / Apple HPSS)
over TCP 5900, targeting the Mac mini (M2 Pro, macOS 26) at
`davids-mac-mini-1.taile209c0.ts.net`. Clean-room Swift; the AGPL iShareScreen
project was used only as a protocol spec and for live testing, never copied.

## Live streaming: WORKING (2026-11-11, iOS Simulator on the mini)

`hpss://127.0.0.1:5900?user=davidhope` in the iPhone Simulator, host = the mini
with its HDMI monitor attached (3840x2160 panel, "looks like" 1920x1080):

- 0x1c answer → **3840x2160 canvas, 4 tiles**, HEVC 4:4:4, 0 decode errors.
- Sustained over 50 s: **30-33 fps** composited canvas, **~600-700 video pkt/s
  (~6-7 Mbit/s)**, **rx→canvas ~14 ms** (first RTP packet of a frame →
  composited 4K BGRA buffer; Simulator VT is software decode).
- Audio: AAC-ELD-SBR RTP arrives at **100 pkt/s** on the ctrl port, decrypts and
  decodes; the self-test proves the decoder with the host's magic cookie on a
  1 kHz tone (RMS 0.355). Playback is muted in the same-host Simulator test
  (playing the host's audio out of the host feeds it back into the capture).
- Connect → first frame ~15 s: dominated by screensharingd's own 0x1c
  re-query loop (the reference client takes the same ~11-15 s).

### Why it used to stall after ~45 packets (root causes, all fixed)

1. **Same-host port collision.** The viewer's UDP ports are symmetric with the
   host's (5900/5901). Running on the host itself (Simulator, harness) with a
   wildcard bind steals screensharingd's sockets, so the host stalls after the
   session-start burst. This is what both clients hit — the headless/HDMI
   question was a red herring. Fix: for a same-host target, bind UDP and the TCP
   source to a different local interface (`HPMediaSession.autoBindIP`); on a
   real iPhone nothing changes (wildcard bind).
2. **Media endpoint in the 0x1c offer vs RTCP.** The offer's session id IS our
   SSRC. We sent RTCP as `0x12345678` to the video port; AVConference only
   accepts RTCP from the negotiated SSRC, on the **ctrl** port (5900). Now:
   RR (+SR every 5 s) from our video SSRC to :5900 every 0.5 s, FIR+PLI+legacy
   FIR addressed to the tile SSRC, and the PT=101 SRTP keepalive (`00683400`,
   our audio SSRC, audio key) every 0.5 s.
3. **Tiles are one HEVC stream.** The 4 consecutive SSRCs share one DPB (Apple
   IDRs tile 0 only; tiles 1-3 reference across tiles). One VT session, every
   tile's VCL NAL fed in arrival order (one NAL per sample, synchronous decode),
   output routed back to its tile; canvas = stripes at `tile * pictureHeight`
   (CTU-padded, 544 rows for 2160/4). Per-tile decoders failed every P-frame.
4. SSRC group adoption (Apple rotates groups during session start; never flip
   back to an abandoned group), enc1103 TCP kept drained, and the video RTP
   clock is **~24 kHz** (not 90 kHz).

Run it: `VOXL_URL='hpss://127.0.0.1:5900?user=davidhope' VOXL_AUTOCONNECT=127.0.0.1
VOXL_HP_PWFILE=<0600 file, deleted on read> VOXL_HP_AUDIO_MUTE=1` (as
`SIMCTL_CHILD_*`). Self-test: `VOXL_HP_SELFTEST=1` → 13/13.

## Verified working (against the real mini, `127.0.0.1:5900`, user `davidhope`)

Control-plane crypto, implemented natively in Swift and run against Apple's real
`screensharingd`:

- **RFB 003.889** version + security-types handshake.
- **RSA1 init** — parses the server's 2048-bit RSA SubjectPublicKeyInfo and
  PKCS#1 v1.5-encrypts the username slot (Security.framework `SecKey`).
- **SRP-6a** RFC-5054 4096-bit group, g=5, SHA-512, with Apple's
  SALTED-SHA512-PBKDF2 password expansion (140 845 iterations observed).
  BigUInt modular-exponentiation via attaswift/BigInt.
- **AUTH OK** → **ClientInit/ServerInit 1920x1080** read back.
- **enc1103** control-channel stream cipher (AES-128-CBC, per-direction counter,
  plain-SHA1 record tag) — key/IV unwrap + encrypt→decrypt round-trip unit test.

All of the above compiles into the iOS app target (device + simulator slices,
`BUILD SUCCEEDED`) and is reusable on-device unchanged (CryptoKit / CommonCrypto /
Security / BigInt are all available on iOS).

### Reproduce the verification

```
cd ~/voxl-scratch/hp/swift-harness      # SwiftPM wrapper that links Sources/HP
swift build
./.build/debug/harness 127.0.0.1 5900 davidhope < <password-file>
# -> [PASS] enc1103 … / [PASS] RFB+RSA1+SRP AUTH OK + ServerInit / ServerInit: 1920x1080
```

The harness links the exact same `Sources/HP/*.swift` files the app uses.

## Files (Sources/HP)

- `HPCrypto.swift`    — SHA-512/256/1, PBKDF2-HMAC-SHA512, AES-128 ECB/CBC.
- `HPSRP.swift`       — Apple SRP-6a challenge parse + solve (BigUInt).
- `HPStreamCipher.swift` — enc1103 AES-CBC + SHA1-tag record cipher.
- `HPRFB.swift`       — POSIX transport, RFB handshake, RSA1, SRP driver, ServerInit.

## Not yet built (the large remaining pieces)

1. **enc1103 live bring-up over the wire**: ViewerInfo (msg 0x21) + the Apple
   0x12 follow-up, plaintext SetEncodings, read the 1103 reply to build the
   cipher, PostEncryptionToggle, encrypted SetEncodings + 0x1c media offer /
   answer. (Cipher itself is done + unit-tested; only the negotiation plumbing
   around it remains.)
2. **UDP media transport + SRTP** decrypt (video on :5901, audio rtcp-muxed on
   :5900), RTCP SR/RR, FIR/PLI/NACK, dynamic SSRC adoption.
3. **HEVC tiled decode**: Apple's RFC-7798 DONL deviations (AP/FU/single-NAL),
   4-tile reassembly + composite, VideoToolbox decode, AVSampleBufferDisplayLayer
   or Metal render.
   - **OPEN RISK (documented, not yet device-verified):** the host streams HEVC
     **4:4:4** (nv24). Apple VideoToolbox HW HEVC decode is 4:2:0/10-bit only;
     A18 Pro (iPhone 16 Pro) has **no HW 4:4:4 path**, so decode likely falls to
     software. Must verify on-device (`VTIsHardwareDecodeSupported` + a real
     decode) and, if too slow, investigate requesting a 4:2:0 stream in the 0x1c
     offer.
4. **AAC-ELD audio** decode (AudioToolbox) from the muxed ctrl port.
5. **Cursor** (enc 1104 pseudo-encoding), **AppleDisplayLayout** (0x451),
   **dynamic resolution** (SetDisplayConfiguration 0x1d) to the external
   monitor's native size.
6. **Input**: map the existing gesture/keyboard/mouse layer to RFB pointer
   (msg 0x05, Apple's swapped button mask) and key (msg 0x04) events instead of
   voxl's text protocol; reuse trackpad mode, key repeat, external-display scene.
7. **UI**: a "Mac Screen Sharing (High Performance)" connection type beside voxl,
   credentials stored in the iOS Keychain (seeded for test from 1Password via
   `op`, vault Grokbot — never committed).

## UI (done)

Each saved connection has a **High Performance mode** switch (host settings, the
(i) button or swipe > Edit), off by default. On: Mac username, Mac password
(Keychain, key `hp:<url>`), port (5900), **Mute Mac audio** (default on) and
**Stats overlay** (default off); both also in the in-session bolt menu, which
has **Switch to voxl**. Failing to connect (wrong password at once, otherwise
after two failed attempts or 40 s with no picture) offers "Use voxl", which turns
the switch off. Bare `hpss://host:port?user=name` addresses still work (always HP,
no fallback). The virtual-display request (0x1d) is no longer sent (the stream
works without it; `VOXL_HP_VD=1` brings it back).

## Feel / latency / connect (Nov 11 pass)

Measured on the mini (Simulator + macOS harness, 1920x1080 host display):

- **Connect 11.6 s -> 2.9-3.4 s.** The host was never slow: `drainInto` after the
  encryption toggle did four blocking reads, each waiting for the host's next 2 s
  heartbeat (7.9 s). It now reads with a 0.3 s timeout. Warmup dwell 1.4 -> 0.5 s
  (4/4 clean connects). Remaining: warmup 0.5, SRP 0.45 (Release; Debug BigInt is
  ~8 s), offer answer 0.9, host encoder start ~1.05 s (host side), first frame.
  The stats overlay shows the timeline ("connect ...").
- **Pointer.** The host never draws the cursor into the video (it sends shapes via
  enc 1104 for the client to draw), and taps/pans were absolute with pan = drag.
  Now: local cursor (host shapes, decoded from 1104; arrow until the first one),
  trackpad mode by default like voxl (1.5x gain + mild acceleration), tap = click,
  two-finger tap = right click, hold-drag = drag, two-finger scroll (wheel ticks),
  pinch zoom; Touch mode in the bolt menu. Pointer events go out on their own queue
  and coalesce to the newest position (main thread never blocks on the socket).
  1x1 incremental FBU poll keeps cursor shapes flowing.
- **Display.** Tiles go straight to one AVSampleBufferDisplayLayer each (stacked
  stripes); no CPU composite (was a 4K BGRA copy per frame).
- **Latency.** Marker test (time code drawn on the host, read back from decoded
  pixels, same clock): host screen -> decoded 10-11 ms in the Simulator (software
  VT). Screenshot comparison on the same machine: HP shows a 7-13 ms newer frame
  than voxl. Receive and decode are split (queue depth in stats).
- **Loss (the Wi-Fi problem).** Generic NACKs are sent at once, but the host never
  retransmitted HEVC packets (0 recovered across runs with simulated loss), so a
  picture with a hole is dropped right away (no repair wait). Apple LTR acks are
  sent for clean tile-0 pictures; a keyframe is asked for only after 150 ms without
  a clean decode (max 2/s, tile 0). Simulated random loss: 0% -> 0 decode errors;
  0.5% -> recovers, ~1000 decode errors/20 s; 1-2% -> 1-25 fps, keyframe storms.
  voxl runs over TCP/WebSocket and never sees loss; HP has no loss resilience
  beyond keyframes, so on Wi-Fi with any loss it stutters. The overlay shows loss,
  dropped pictures, decode errors, keyframe requests, HW/SOFTWARE decode and
  whether the device's hardware decodes HEVC 4:4:4.

## Branch / merge

Built on `hp-mode`, which contains `hevc444-audio` (HEVC 4:4:4, Mac audio + mute,
"Fit this screen"); fast-forwarded into `hevc444-audio` and `main`.
