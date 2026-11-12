import Foundation

/// Keysyms, shortcut policy and geometry helpers used by the session view.
enum InputMap {
    /// How Command on a hardware or sticky keyboard should be sent.
    /// Auto: Command on a Mac host, Control on Linux (and anything that isn't macOS).
    enum ShortcutStyle: Int, CaseIterable {
        case auto = 0, command, control

        var title: String {
            switch self {
            case .auto: return "Auto (match the host)"
            case .command: return "Command (Mac)"
            case .control: return "Control (Windows / Linux)"
            }
        }
    }

    static func cmdAsCtrl(style: ShortcutStyle, hostOS: String?) -> Bool {
        switch style {
        case .command: return false
        case .control: return true
        case .auto:
            let os = (hostOS ?? "").lowercased()
            return !os.isEmpty && os != "macos" && os != "darwin" && os != "mac"
        }
    }

    /// Super_L/R become Control_L/R when Command should act as Control.
    static func remap(_ sym: Int, cmdAsCtrl: Bool) -> Int {
        guard cmdAsCtrl else { return sym }
        switch sym {
        case 0xffeb: return 0xffe3
        case 0xffec: return 0xffe4
        default: return sym
        }
    }

    static func isModifier(_ sym: Int) -> Bool {
        // Shift, Ctrl, Lock, Alt/Meta/Super, AltGraph, ISO Level3.
        (0xffe1...0xffee).contains(sym) || sym == 0xfe03
    }

    /// HID usage 0x3A...0x45 is F1-F12; anything in `special` wins; otherwise a character keysym.
    static func keysym(hid: UInt32, characters: String, charactersIgnoringModifiers: String, commandControlAlt: Bool) -> Int? {
        if (0x3A...0x45).contains(hid) { return 0xffbe + Int(hid) - 0x3A }
        if let s = specialHID[hid] { return s }
        let text = commandControlAlt ? charactersIgnoringModifiers : characters
        guard let u = text.unicodeScalars.first else { return nil }
        return keysym(for: u)
    }

    static func keysym(for u: Unicode.Scalar) -> Int {
        u.value < 0x100 ? Int(u.value) : 0x0100_0000 + Int(u.value)
    }

    /// Left / right / middle X buttons from a UIEvent button mask (primary, secondary, button(3)).
    static func pointerButton(primary: Bool, secondary: Bool, middle: Bool) -> Int {
        if secondary { return 3 }
        if middle { return 2 }
        return primary ? 1 : 1
    }

    /// Native pixels of a window: points × screen scale, width a multiple of 8 and height even
    /// (H.264 4:2:0), at least 1×1.
    static func nativePixels(widthPoints: Double, heightPoints: Double, scale: Double) -> (Int, Int) {
        let w = max(1, Int((widthPoints * scale).rounded()) & ~7)
        let h = max(1, Int((heightPoints * scale).rounded()) & ~1)
        return (w, h)
    }

    /// Inputs iOS often keeps for itself; asked for with wantsPriorityOverSystemBehavior.
    /// The value is the X keysym of the key (without the Command modifier).
    static let systemShortcutInputs: [(String, Int)] = [
        (" ", 0x20), ("\t", 0xff09),
        ("h", 0x68), ("w", 0x77), ("q", 0x71), ("m", 0x6d),
        ("n", 0x6e), ("p", 0x70), ("r", 0x72), ("f", 0x66),
        (".", 0x2e), (",", 0x2c),
        ("c", 0x63), ("v", 0x76), ("x", 0x78), ("a", 0x61),
        ("z", 0x7a), ("s", 0x73),
    ]

    static func isSystemShortcutInput(_ characters: String) -> Bool {
        let s = characters.lowercased()
        return systemShortcutInputs.contains { $0.0 == s || $0.0 == characters }
    }

    /// USB HID usage page 0x07 codes we treat as special (not characters).
    static let specialHID: [UInt32: Int] = [
        0x28: 0xff0d, // Return
        0x58: 0xff8d, // Keypad Enter
        0x29: 0xff1b, // Escape
        0x2A: 0xff08, // Backspace
        0x2B: 0xff09, // Tab
        0x2C: 0x20,   // Space
        0x4C: 0xffff, // Delete Forward
        0x4A: 0xff50, // Home
        0x4D: 0xff57, // End
        0x4B: 0xff55, // Page Up
        0x4E: 0xff56, // Page Down
        0x49: 0xff63, // Insert
        0x50: 0xff51, 0x52: 0xff52, 0x4F: 0xff53, 0x51: 0xff54, // arrows
        0xE1: 0xffe1, 0xE5: 0xffe2, // Shift
        0xE0: 0xffe3, 0xE4: 0xffe4, // Control
        0xE2: 0xffe9, 0xE6: 0xffea, // Alt
        0xE3: 0xffeb, 0xE7: 0xffec, // GUI / Command
        0x39: 0xffe5, // Caps Lock
    ]


    // MARK: scroll direction

    /// UserDefaults key for macOS-style natural scrolling (content follows the fingers).
    static let naturalScrollingKey = "naturalScrolling"

    /// Default on, like a Mac trackpad. Off is traditional (scrollbar / wheel) direction.
    static var naturalScrolling: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: naturalScrollingKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: naturalScrollingKey) }
    }

    /// voxl `sp` delta from a UIKit translation (points, y-down).
    ///
    /// The host treats positive dy as "scroll down" (see voxl InputEvent::Scroll).
    /// Natural: finger up (negative y) sends a positive `sp` dy, which the macOS
    /// host then turns into content moving up — same as a Mac trackpad.
    /// Traditional inverts that.
    static func voxlScrollDelta(from translation: CGPoint) -> CGPoint {
        let s: CGFloat = naturalScrolling ? -1 : 1
        return CGPoint(x: translation.x * s, y: translation.y * s)
    }

    /// Accumulate a UIKit translation into RFB wheel ticks for High Performance mode.
    ///
    /// `HPMediaSession.scroll` maps negative ticks to button 4 (scroll up) and
    /// positive ticks to button 5 (scroll down). Natural: finger up (negative y)
    /// yields negative ticks so a Mac with natural scrolling moves content up.
    /// Traditional keeps the previous inverted mapping.
    static func hpScrollTicks(translationY dy: CGFloat, accumulated: inout CGFloat, perTick: CGFloat) -> Int {
        guard perTick > 0 else { return 0 }
        accumulated += dy
        let raw = Int(accumulated / perTick)
        guard raw != 0 else { return 0 }
        accumulated -= CGFloat(raw) * perTick
        return naturalScrolling ? raw : -raw
    }
}
