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

        // Scroll direction. Default is natural; isolate tests from the host defaults.
        let prevScroll = UserDefaults.standard.object(forKey: InputMap.naturalScrollingKey)
        defer {
            if let prev = prevScroll as? Bool {
                InputMap.naturalScrolling = prev
            } else {
                UserDefaults.standard.removeObject(forKey: InputMap.naturalScrollingKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: InputMap.naturalScrollingKey)
        expect(InputMap.naturalScrolling, "natural scrolling is the default")

        InputMap.naturalScrolling = true
        let up = InputMap.voxlScrollDelta(from: CGPoint(x: 0, y: -10))
        expect(up.x == 0 && up.y == 10, "natural: finger up -> positive voxl sp dy (content follows fingers), got \(up)")
        let down = InputMap.voxlScrollDelta(from: CGPoint(x: 3, y: 10))
        expect(down.x == -3 && down.y == -10, "natural: finger down/right -> negative voxl sp, got \(down)")
        InputMap.naturalScrolling = false
        let trad = InputMap.voxlScrollDelta(from: CGPoint(x: 0, y: -10))
        expect(trad.x == 0 && trad.y == -10, "traditional: finger up -> negative voxl sp dy, got \(trad)")

        InputMap.naturalScrolling = true
        var acc: CGFloat = 0
        let hpUp = InputMap.hpScrollTicks(translationY: -20, accumulated: &acc, perTick: 10)
        expect(hpUp == -2, "natural: finger up -> negative HP ticks (button 4 / scroll up), got \(hpUp)")
        acc = 0
        let hpDown = InputMap.hpScrollTicks(translationY: 25, accumulated: &acc, perTick: 10)
        expect(hpDown == 2, "natural: finger down -> positive HP ticks (button 5), got \(hpDown)")
        expect(abs(acc - 5) < 0.001, "HP remainder kept, got \(acc)")
        InputMap.naturalScrolling = false
        acc = 0
        let hpTrad = InputMap.hpScrollTicks(translationY: -20, accumulated: &acc, perTick: 10)
        expect(hpTrad == 2, "traditional: finger up keeps the old inverted HP ticks, got \(hpTrad)")
        expect(InputMap.hpScrollTicks(translationY: 3, accumulated: &acc, perTick: 10) == 0, "HP sub-tick does not emit")

        if failed == 0 {
            print("InputMapTests: all passed")
        } else {
            fputs("InputMapTests: \(failed) failed\n", stderr)
            exit(1)
        }
    }
}
