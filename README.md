# voxl-pocket-ios

A native iPad client for [voxl](https://github.com/tembo/voxl), the low-latency remote
desktop server.

## Features

- H.264 video decoded in hardware (AVSampleBufferDisplayLayer), one layer per stripe
- Trackpad and touch input, pinch to zoom, two-finger scroll
- Hardware keyboards and mice, plus the soft keyboard with a key bar for Esc, Tab,
  sticky Shift/Cmd/Ctrl/Opt, ⌘Space, ⌘Tab and arrows
- Keeps the host at its own resolution by default; can resize it to fit the iPad
  (Large, Medium, More space) when the server runs with `--enable-resize`
- Switch between the host's displays
- Clipboard both ways, text and images
- Split View, Slide Over and any orientation

## Use

Tap **+** and enter the server's address, for example `wss://my-mac.example.com:6901/ws`,
and its password. The password is stored in the iOS Keychain.

## Privacy

Voxl Pocket collects no data and has no analytics, ads or accounts. The servers you add
are stored on your device, and their passwords in the iOS Keychain. The app talks only to
the servers you add: it sends your input, and your clipboard when it changes, and receives
the screen and the server's clipboard. Nothing goes to the developer or anyone else.

## Build

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen
open VoxlPocket.xcodeproj
```

To sign with your own Apple account, change `DEVELOPMENT_TEAM` and the bundle identifier
in `project.yml`.

## License

MIT
