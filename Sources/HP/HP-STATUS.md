# Mac Screen Sharing (High Performance) mode — status

Native client for macOS built-in Screen Sharing ("High Performance" / Apple HPSS)
over TCP 5900, targeting the Mac mini (M2 Pro, macOS 26) at
`davids-mac-mini-1.taile209c0.ts.net`. Clean-room Swift; the AGPL iShareScreen
project was used only as a protocol spec and for live testing, never copied.

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

## Branch / merge

On `hp-mode`. Not merged to `main` — the feature is incomplete and another worker
is changing the voxl path on `main` concurrently; merge only when HP mode is
functional, rebasing onto their audio/HEVC changes.
