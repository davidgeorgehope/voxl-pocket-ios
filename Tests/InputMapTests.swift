/// Logic checks for InputMap. Compiled and run with `swift Tests/InputMapTests.swift`
/// after dropping InputMap.swift in (see verify-input-map.sh). Kept free of XCTest
/// so it can run without a signed test host.

import Foundation

@main
enum Tests {
    static func main() {
        var failed = 0
        func expect(_ cond: Bool, _ msg: String) {
            if !cond {
                fputs("FAIL: \(msg)\n", stderr)
                failed += 1
            }
        }

        expect(!InputMap.cmdAsCtrl(style: .auto, hostOS: "macos"), "auto+macos => Command")
        expect(!InputMap.cmdAsCtrl(style: .auto, hostOS: "macOS"), "auto+macOS => Command")
        expect(InputMap.cmdAsCtrl(style: .auto, hostOS: "linux"), "auto+linux => Control")
        expect(!InputMap.cmdAsCtrl(style: .auto, hostOS: nil), "auto+unknown => Command")
        expect(!InputMap.cmdAsCtrl(style: .command, hostOS: "linux"), "manual Command stays Command")
        expect(InputMap.cmdAsCtrl(style: .control, hostOS: "macos"), "manual Control stays Control")

        expect(InputMap.remap(0xffeb, cmdAsCtrl: true) == 0xffe3, "Super_L -> Control_L")
        expect(InputMap.remap(0xffec, cmdAsCtrl: true) == 0xffe4, "Super_R -> Control_R")
        expect(InputMap.remap(0xffeb, cmdAsCtrl: false) == 0xffeb, "Super_L unchanged")
        expect(InputMap.remap(0x63, cmdAsCtrl: true) == 0x63, "letter c unchanged")

        expect(InputMap.isModifier(0xffe1) && InputMap.isModifier(0xffeb) && InputMap.isModifier(0xfe03), "modifiers")
        expect(!InputMap.isModifier(0x63) && !InputMap.isModifier(0xff0d), "non-modifiers")

        expect(InputMap.keysym(hid: 0x3A, characters: "", charactersIgnoringModifiers: "", commandControlAlt: false) == 0xffbe, "F1")
        expect(InputMap.keysym(hid: 0x45, characters: "", charactersIgnoringModifiers: "", commandControlAlt: false) == 0xffc9, "F12")
        expect(InputMap.keysym(hid: 0x29, characters: "", charactersIgnoringModifiers: "", commandControlAlt: false) == 0xff1b, "Esc")
        expect(InputMap.keysym(hid: 0x50, characters: "", charactersIgnoringModifiers: "", commandControlAlt: false) == 0xff51, "Left")
        expect(InputMap.keysym(hid: 0x04, characters: "c", charactersIgnoringModifiers: "c", commandControlAlt: true) == 0x63, "c with Cmd")
        expect(InputMap.keysym(hid: 0x04, characters: "©", charactersIgnoringModifiers: "c", commandControlAlt: true) == 0x63, "c ignoring opt/cmd glyph")

        expect(InputMap.pointerButton(primary: true, secondary: false, middle: false) == 1, "left")
        expect(InputMap.pointerButton(primary: false, secondary: true, middle: false) == 3, "right")
        expect(InputMap.pointerButton(primary: false, secondary: false, middle: true) == 2, "middle")
        expect(InputMap.pointerButton(primary: true, secondary: true, middle: false) == 3, "right wins")

        expect(InputMap.nativePixels(widthPoints: 1920, heightPoints: 1080, scale: 1) == (1920, 1080), "1080p @1x")
        expect(InputMap.nativePixels(widthPoints: 1920, heightPoints: 1080, scale: 2) == (3840, 2160), "1080p @2x")
        let odd = InputMap.nativePixels(widthPoints: 100.9, heightPoints: 50.9, scale: 1)
        expect(odd.0 % 8 == 0 && odd.1 % 2 == 0, "rounded to 8-wide even-high, got \(odd)")
        expect(InputMap.nativePixels(widthPoints: 0, heightPoints: 0, scale: 1) == (1, 1), "min 1x1")

        expect(InputMap.isSystemShortcutInput(" "), "space shortcut")
        expect(InputMap.isSystemShortcutInput("h"), "h shortcut")
        expect(!InputMap.isSystemShortcutInput("1"), "digit not a captured shortcut")

        if failed == 0 {
            print("InputMapTests: all passed")
        } else {
            fputs("InputMapTests: \(failed) failed\n", stderr)
            exit(1)
        }
    }
}
