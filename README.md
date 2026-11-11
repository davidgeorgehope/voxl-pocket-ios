# voxl-pocket-ios

A native iPhone and iPad client for [voxl](https://github.com/tembo/voxl), the low-latency remote
desktop server.

## Features

- H.264 video decoded in hardware (AVSampleBufferDisplayLayer), one layer per stripe
- Trackpad and touch input, pinch to zoom, two-finger scroll
- Hardware keyboards and mice, plus the soft keyboard with a key bar for Esc, Tab,
  sticky Shift/Cmd/Ctrl/Opt, ⌘Space, ⌘Tab and arrows
- External displays (USB-C/HDMI or AirPlay): the remote desktop is shown full-screen on
  the monitor; the iPhone or iPad becomes a trackpad with the usual chrome. When the
  server runs with `--enable-resize`, the host is resized to the monitor's native pixels.
  Otherwise the stream is scaled and letterboxed. Unplugging returns the desktop to the
  device and restores the host's own size.
- Relative mouse movement (pointer lock and GCMouse) while a monitor is connected; key
  repeat; Command is sent as Control on a Linux host (override in the toolbar)
- Keeps the host at its own resolution by default; can resize it to fit the device in landscape
  (Large, Medium, More space) when the server runs with `--enable-resize`
- Switch between the host's displays
- Clipboard both ways, text and images
- Portrait and landscape; Split View and Slide Over on iPad

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

This fork is signed with David Hope's team (`4P2629648N`) and bundle id
`com.davidhope.voxlpocket` so an already-installed copy keeps its hosts and Keychain
items. To sign with your own Apple account, change `DEVELOPMENT_TEAM` and the bundle
identifier in `project.yml`.

## License

MIT
