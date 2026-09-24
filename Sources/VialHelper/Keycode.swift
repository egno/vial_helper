import Foundation

/// What to print on a keycap.
struct KeyLabel: Equatable {
    enum Style { case normal, transparent, none, layer, modifier, special }
    enum SecondaryKind { case mod, layer, info }

    var primary: String
    var secondary: String? = nil
    var secondaryKind: SecondaryKind = .info
    var style: Style = .normal

    static let none = KeyLabel(primary: "", style: .none)
    static let transparent = KeyLabel(primary: "▽", style: .transparent)
}

/// Extra information needed to render some keycodes.
struct LabelContext {
    var tapDances: [TapDance] = []
    /// User-defined layer names, indexed by layer number ("" = unnamed).
    var layerNames: [String] = []
    /// Active-keyboard-layout override for basic keycodes ("KC_A" -> "Ф", "KC_GRV" -> "Щ", etc.).
    var keyOverrides: [String: String] = [:]

    func layerName(_ n: Int) -> String {
        if n < layerNames.count, !layerNames[n].isEmpty { return layerNames[n] }
        return "L\(n)"
    }
}

/// QMK/Vial keycode string -> human-readable label.
enum Keycode {
    static func isEmpty(_ code: String) -> Bool {
        code == "-1" || code == "KC_NO" || code == "XXXXXXX" || code.isEmpty
    }

    static func isTransparent(_ code: String) -> Bool {
        code == "KC_TRNS" || code == "KC_TRANSPARENT" || code == "_______"
    }

    static func label(_ code: String, context: LabelContext = LabelContext()) -> KeyLabel {
        label(parse(code), context: context)
    }

    /// Short single-line text, used in combo lists and encoder legends.
    static func short(_ code: String, context: LabelContext = LabelContext()) -> String {
        let l = label(code, context: context)
        switch l.style {
        case .none: return "∅"
        case .transparent: return "▽"
        default:
            if let s = l.secondary, l.secondaryKind != .info { return "\(l.primary)/\(s)" }
            return l.primary
        }
    }

    // MARK: - Parsing

    indirect enum Expr {
        case atom(String)
        case call(String, [Expr])
    }

    static func parse(_ raw: String) -> Expr {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return .atom(s) }
        let name = String(s[..<open])
        let inner = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        var args: [Expr] = []
        var depth = 0
        var cur = ""
        for ch in inner {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == "," && depth == 0 {
                args.append(parse(cur)); cur = ""
            } else {
                cur.append(ch)
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { args.append(parse(cur)) }
        return .call(name, args)
    }

    // MARK: - Labelling

    static func label(_ expr: Expr, context: LabelContext) -> KeyLabel {
        switch expr {
        case .atom(let a):
            return atomLabel(a, context: context)

        case .call(let name, let args):
            let first = args.first
            let firstAtom: String? = { if case .atom(let a)? = first { return a }; return nil }()

            // Layer-tap: LT3(KC_X) or LT(3, KC_X)
            if name.hasPrefix("LT"), let n = Int(name.dropFirst(2)), let kc = first {
                return layerTap(n, kc, context)
            }
            if name == "LT", args.count == 2, let n = firstAtom.flatMap(Int.init) {
                return layerTap(n, args[1], context)
            }
            // Mod-tap: LCTL_T(KC_X), HYPR_T(...), ALL_T(...)
            if name.hasSuffix("_T"), let mods = modSymbols(String(name.dropLast(2))), let kc = first {
                var l = label(kc, context: context)
                l.secondary = mods
                l.secondaryKind = .mod
                return l
            }
            // Layer switches
            if ["MO", "TG", "TO", "TT", "DF", "PDF", "OSL"].contains(name), let n = firstAtom.flatMap(Int.init) {
                return KeyLabel(primary: context.layerName(n), secondary: name, secondaryKind: .layer, style: .layer)
            }
            if name == "LM", args.count == 2, let n = firstAtom.flatMap(Int.init), case .atom(let m) = args[1] {
                return KeyLabel(primary: context.layerName(n), secondary: "LM " + (modMaskSymbols(m) ?? m), secondaryKind: .layer, style: .layer)
            }
            if name == "OSM", let m = firstAtom {
                return KeyLabel(primary: modMaskSymbols(m) ?? m, secondary: "OSM", secondaryKind: .info, style: .modifier)
            }
            if name == "TD", let n = firstAtom.flatMap(Int.init) {
                return tapDanceLabel(n, context)
            }
            if name == "SH_T", let kc = first {
                var l = label(kc, context: context)
                l.secondary = "SH"
                return l
            }
            // Modifier wrappers: LSFT(KC_1), LCA(KC_X), HYPR(KC_X) ...
            if let mods = modSymbols(name), let kc = first {
                let inner = label(kc, context: context)
                if mods == "⇧", let shifted = shiftedSymbols[inner.primary], inner.secondary == nil {
                    return KeyLabel(primary: shifted, style: inner.style == .none ? .normal : inner.style)
                }
                var l = inner
                l.primary = mods + inner.primary
                if l.style == .none { l.style = .normal }
                return l
            }
            // Unknown wrapper: show it raw but compact.
            let innerText = args.map { label($0, context: context).primary }.joined(separator: ",")
            return KeyLabel(primary: "\(name)(\(innerText))", style: .special)
        }
    }

    private static func layerTap(_ n: Int, _ kc: Expr, _ ctx: LabelContext) -> KeyLabel {
        var l = label(kc, context: ctx)
        l.secondary = ctx.layerName(n)
        l.secondaryKind = .layer
        return l
    }

    private static func tapDanceLabel(_ n: Int, _ ctx: LabelContext) -> KeyLabel {
        guard n < ctx.tapDances.count else { return KeyLabel(primary: "TD\(n)", style: .special) }
        let d = ctx.tapDances[n]
        if isEmpty(d.tap) { return KeyLabel(primary: "TD\(n)", style: .special) }
        var l = label(d.tap, context: LabelContext(layerNames: ctx.layerNames))
        l.style = .special
        let hold = isEmpty(d.hold) ? nil : short(d.hold, context: LabelContext(layerNames: ctx.layerNames))
        l.secondary = "TD" + (hold.map { " " + $0 } ?? "")
        l.secondaryKind = .info
        return l
    }

    private static func atomLabel(_ a: String, context: LabelContext) -> KeyLabel {
        if isEmpty(a) { return .none }
        if isTransparent(a) { return .transparent }

        // Macros: M0, M1 ...
        if a.hasPrefix("M"), let n = Int(a.dropFirst()) {
            return KeyLabel(primary: "M\(n)", secondary: "macro", style: .special)
        }
        if let l = specials[a] { return l }
        if let override = context.keyOverrides[a] { return KeyLabel(primary: override) }
        if let t = basic[a] { return KeyLabel(primary: t) }
        if let m = modKeys[a] { return KeyLabel(primary: m, style: .modifier) }

        // Fallbacks
        var s = a
        for p in ["KC_", "QK_", "RM_", "RGB_"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        let words = s.split(separator: "_").map { w -> String in
            let w = String(w)
            return w.count <= 3 ? w : w.prefix(1) + w.dropFirst().lowercased()
        }
        return KeyLabel(primary: words.joined(separator: " "), style: .special)
    }

    // MARK: - Modifier symbols

    private static let modBase: [String: String] = [
        "LCTL": "⌃", "CTL": "⌃", "C": "⌃", "RCTL": "⌃",
        "LSFT": "⇧", "SFT": "⇧", "S": "⇧", "RSFT": "⇧",
        "LALT": "⌥", "ALT": "⌥", "A": "⌥", "LOPT": "⌥", "OPT": "⌥", "RALT": "⌥", "ROPT": "⌥", "ALGR": "⌥",
        "LGUI": "⌘", "GUI": "⌘", "G": "⌘", "LCMD": "⌘", "CMD": "⌘", "LWIN": "⌘", "WIN": "⌘",
        "RGUI": "⌘", "RCMD": "⌘", "RWIN": "⌘",
        "LCA": "⌃⌥", "LSA": "⇧⌥", "LCG": "⌃⌘", "LAG": "⌥⌘", "LSG": "⇧⌘",
        "SGUI": "⇧⌘", "SCMD": "⇧⌘", "SWIN": "⇧⌘",
        "RCS": "⌃⇧", "C_S": "⌃⇧", "LCS": "⌃⇧", "RSA": "⇧⌥", "RCG": "⌃⌘", "RAG": "⌥⌘", "RSG": "⇧⌘",
        "LCAG": "⌃⌥⌘", "RCAG": "⌃⌥⌘",
        "MEH": "⌃⌥⇧", "HYPR": "⌃⌥⇧⌘", "ALL": "⌃⌥⇧⌘",
    ]

    static func modSymbols(_ name: String) -> String? { modBase[name] }

    /// "MOD_LSFT|MOD_LCTL" -> "⇧⌃"
    static func modMaskSymbols(_ mask: String) -> String? {
        let parts = mask.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        var out = ""
        for p in parts {
            let base = p.hasPrefix("MOD_") ? String(p.dropFirst(4)) : p
            guard let s = modBase[base] else { return nil }
            out += s
        }
        return out.isEmpty ? nil : out
    }

    static let shiftedSymbols: [String: String] = [
        "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
    ]

    // MARK: - Tables

    private static let modKeys: [String: String] = [
        "KC_LCTRL": "⌃", "KC_LCTL": "⌃", "KC_RCTRL": "⌃", "KC_RCTL": "⌃",
        "KC_LSHIFT": "⇧", "KC_LSFT": "⇧", "KC_RSHIFT": "⇧", "KC_RSFT": "⇧",
        "KC_LALT": "⌥", "KC_LOPT": "⌥", "KC_RALT": "⌥", "KC_ROPT": "⌥", "KC_ALGR": "⌥",
        "KC_LGUI": "⌘", "KC_LCMD": "⌘", "KC_LWIN": "⌘", "KC_RGUI": "⌘", "KC_RCMD": "⌘", "KC_RWIN": "⌘",
        "KC_HYPR": "⌃⌥⇧⌘", "KC_MEH": "⌃⌥⇧",
    ]

    private static let specials: [String: KeyLabel] = [
        "QK_CAPS_WORD_TOGGLE": KeyLabel(primary: "CapsWd", style: .special),
        "CAPS_WORD": KeyLabel(primary: "CapsWd", style: .special),
        "CW_TOGG": KeyLabel(primary: "CapsWd", style: .special),
        "QK_LAYER_LOCK": KeyLabel(primary: "LyrLk", style: .layer),
        "QK_LLCK": KeyLabel(primary: "LyrLk", style: .layer),
        "MAGIC_TOGGLE_NKRO": KeyLabel(primary: "NKRO", style: .special),
        "NK_TOGG": KeyLabel(primary: "NKRO", style: .special),
        "QK_CLEAR_EEPROM": KeyLabel(primary: "EE clr", style: .special),
        "EE_CLR": KeyLabel(primary: "EE clr", style: .special),
        "QK_BOOT": KeyLabel(primary: "Boot", style: .special),
        "RESET": KeyLabel(primary: "Boot", style: .special),
        "QK_REBOOT": KeyLabel(primary: "Reboot", style: .special),
        "QK_REPEAT_KEY": KeyLabel(primary: "Rep", style: .special),
        "QK_REP": KeyLabel(primary: "Rep", style: .special),
        "QK_ALT_REPEAT_KEY": KeyLabel(primary: "ARep", style: .special),
        "QK_AREP": KeyLabel(primary: "ARep", style: .special),
        "QK_DYNAMIC_TAPPING_TERM_UP": KeyLabel(primary: "TT+", style: .special),
        "QK_DYNAMIC_TAPPING_TERM_DOWN": KeyLabel(primary: "TT-", style: .special),
        "QK_DYNAMIC_TAPPING_TERM_PRINT": KeyLabel(primary: "TT?", style: .special),
        "KC_LSPO": KeyLabel(primary: "(", secondary: "⇧", secondaryKind: .mod),
        "KC_RSPC": KeyLabel(primary: ")", secondary: "⇧", secondaryKind: .mod),
        "KC_LCPO": KeyLabel(primary: "(", secondary: "⌃", secondaryKind: .mod),
        "KC_RCPC": KeyLabel(primary: ")", secondary: "⌃", secondaryKind: .mod),
        "KC_LAPO": KeyLabel(primary: "(", secondary: "⌥", secondaryKind: .mod),
        "KC_RAPC": KeyLabel(primary: ")", secondary: "⌥", secondaryKind: .mod),
        "KC_SFTENT": KeyLabel(primary: "⏎", secondary: "⇧", secondaryKind: .mod),
        "SH_TOGG": KeyLabel(primary: "Swap", style: .special),
        "SH_MON": KeyLabel(primary: "Swap", style: .special),
        "SH_OS": KeyLabel(primary: "Swap", style: .special),
        "SH_ON": KeyLabel(primary: "Swap", style: .special),
        "SH_OFF": KeyLabel(primary: "Swap", style: .special),
        "SH_TT": KeyLabel(primary: "Swap", style: .special),
    ]

    /// QMK basic keycode -> the character it prints under the reference US ANSI layout.
    /// Not private: `KeyboardLayoutObserver` reverse-looks-up physical key positions from this.
    static let basic: [String: String] = {
        var t: [String: String] = [:]
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { t["KC_\(c)"] = String(c) }
        for d in "1234567890" { t["KC_\(d)"] = String(d) }
        for i in 1...24 { t["KC_F\(i)"] = "F\(i)" }
        let pairs: [(String, [String])] = [
            ("⏎", ["KC_ENTER", "KC_ENT", "KC_KP_ENTER", "KC_PENT"]),
            ("⎋", ["KC_ESCAPE", "KC_ESC"]),
            ("⌫", ["KC_BSPACE", "KC_BSPC"]),
            ("⇥", ["KC_TAB"]),
            ("␣", ["KC_SPACE", "KC_SPC"]),
            ("-", ["KC_MINUS", "KC_MINS"]),
            ("=", ["KC_EQUAL", "KC_EQL"]),
            ("[", ["KC_LBRACKET", "KC_LBRC"]),
            ("]", ["KC_RBRACKET", "KC_RBRC"]),
            ("\\", ["KC_BSLASH", "KC_BSLS"]),
            ("#", ["KC_NONUS_HASH", "KC_NUHS"]),
            (";", ["KC_SCOLON", "KC_SCLN"]),
            ("'", ["KC_QUOTE", "KC_QUOT"]),
            ("`", ["KC_GRAVE", "KC_GRV"]),
            (",", ["KC_COMMA", "KC_COMM"]),
            (".", ["KC_DOT"]),
            ("/", ["KC_SLASH", "KC_SLSH"]),
            ("⇪", ["KC_CAPSLOCK", "KC_CAPS"]),
            ("PrtSc", ["KC_PSCREEN", "KC_PSCR"]),
            ("ScrLk", ["KC_SCROLLLOCK", "KC_SLCK", "KC_SCRL", "KC_BRMD"]),
            ("Pause", ["KC_PAUSE", "KC_PAUS", "KC_BRK", "KC_BRMU"]),
            ("Ins", ["KC_INSERT", "KC_INS"]),
            ("Home", ["KC_HOME"]),
            ("PgUp", ["KC_PGUP"]),
            ("⌦", ["KC_DELETE", "KC_DEL"]),
            ("End", ["KC_END"]),
            ("PgDn", ["KC_PGDOWN", "KC_PGDN"]),
            ("→", ["KC_RIGHT", "KC_RGHT"]),
            ("←", ["KC_LEFT"]),
            ("↓", ["KC_DOWN"]),
            ("↑", ["KC_UP"]),
            ("Num", ["KC_NUMLOCK", "KC_NLCK", "KC_NUM"]),
            ("Menu", ["KC_APPLICATION", "KC_APP"]),
            ("Power", ["KC_POWER", "KC_PWR", "KC_SYSTEM_POWER", "KC_SYSTEM_POWER"]),
            ("Sleep", ["KC_SYSTEM_SLEEP", "KC_SLEP"]),
            ("Wake", ["KC_SYSTEM_WAKE", "KC_WAKE"]),
            ("Mute", ["KC_AUDIO_MUTE", "KC_MUTE"]),
            ("Vol+", ["KC_AUDIO_VOL_UP", "KC_VOLU"]),
            ("Vol-", ["KC_AUDIO_VOL_DOWN", "KC_VOLD"]),
            ("⏭", ["KC_MEDIA_NEXT_TRACK", "KC_MNXT"]),
            ("⏮", ["KC_MEDIA_PREV_TRACK", "KC_MPRV"]),
            ("⏹", ["KC_MEDIA_STOP", "KC_MSTP"]),
            ("⏯", ["KC_MEDIA_PLAY_PAUSE", "KC_MPLY"]),
            ("⏏", ["KC_MEDIA_EJECT", "KC_EJCT"]),
            ("Bri+", ["KC_BRIGHTNESS_UP", "KC_BRIU"]),
            ("Bri-", ["KC_BRIGHTNESS_DOWN", "KC_BRID"]),
            ("Calc", ["KC_CALCULATOR", "KC_CALC"]),
            ("Mail", ["KC_MAIL"]),
            ("Www", ["KC_WWW_HOME", "KC_WHOM"]),
            ("Back", ["KC_WWW_BACK", "KC_WBAK"]),
            ("Fwd", ["KC_WWW_FORWARD", "KC_WFWD"]),
            ("Ms↑", ["KC_MS_UP", "KC_MS_U", "MS_UP"]),
            ("Ms↓", ["KC_MS_DOWN", "KC_MS_D", "MS_DOWN"]),
            ("Ms←", ["KC_MS_LEFT", "KC_MS_L", "MS_LEFT"]),
            ("Ms→", ["KC_MS_RIGHT", "KC_MS_R", "MS_RGHT"]),
            ("Btn1", ["KC_MS_BTN1", "KC_BTN1", "MS_BTN1"]),
            ("Btn2", ["KC_MS_BTN2", "KC_BTN2", "MS_BTN2"]),
            ("Btn3", ["KC_MS_BTN3", "KC_BTN3", "MS_BTN3"]),
            ("Btn4", ["KC_MS_BTN4", "KC_BTN4", "MS_BTN4"]),
            ("Btn5", ["KC_MS_BTN5", "KC_BTN5", "MS_BTN5"]),
            ("Wh↑", ["KC_MS_WH_UP", "KC_WH_U", "MS_WHLU"]),
            ("Wh↓", ["KC_MS_WH_DOWN", "KC_WH_D", "MS_WHLD"]),
            ("Wh←", ["KC_MS_WH_LEFT", "KC_WH_L", "MS_WHLL"]),
            ("Wh→", ["KC_MS_WH_RIGHT", "KC_WH_R", "MS_WHLR"]),
            ("Acc0", ["KC_MS_ACCEL0", "KC_ACL0", "MS_ACL0"]),
            ("Acc1", ["KC_MS_ACCEL1", "KC_ACL1", "MS_ACL1"]),
            ("Acc2", ["KC_MS_ACCEL2", "KC_ACL2", "MS_ACL2"]),
            ("KP/", ["KC_KP_SLASH", "KC_PSLS"]),
            ("KP*", ["KC_KP_ASTERISK", "KC_PAST"]),
            ("KP-", ["KC_KP_MINUS", "KC_PMNS"]),
            ("KP+", ["KC_KP_PLUS", "KC_PPLS"]),
            ("KP.", ["KC_KP_DOT", "KC_PDOT"]),
            ("KP=", ["KC_KP_EQUAL", "KC_PEQL"]),
            ("KP,", ["KC_KP_COMMA", "KC_PCMM"]),
            ("~", ["KC_TILDE", "KC_TILD"]),
            ("!", ["KC_EXCLAIM", "KC_EXLM"]),
            ("@", ["KC_AT"]),
            ("#", ["KC_HASH"]),
            ("$", ["KC_DOLLAR", "KC_DLR"]),
            ("%", ["KC_PERCENT", "KC_PERC"]),
            ("^", ["KC_CIRCUMFLEX", "KC_CIRC"]),
            ("&", ["KC_AMPERSAND", "KC_AMPR"]),
            ("*", ["KC_ASTERISK", "KC_ASTR"]),
            ("(", ["KC_LEFT_PAREN", "KC_LPRN"]),
            (")", ["KC_RIGHT_PAREN", "KC_RPRN"]),
            ("_", ["KC_UNDERSCORE", "KC_UNDS"]),
            ("+", ["KC_PLUS"]),
            ("{", ["KC_LEFT_CURLY_BRACE", "KC_LCBR"]),
            ("}", ["KC_RIGHT_CURLY_BRACE", "KC_RCBR"]),
            ("|", ["KC_PIPE"]),
            (":", ["KC_COLON", "KC_COLN"]),
            ("\"", ["KC_DOUBLE_QUOTE", "KC_DQUO", "KC_DQT"]),
            ("<", ["KC_LEFT_ANGLE_BRACKET", "KC_LABK", "KC_LT"]),
            (">", ["KC_RIGHT_ANGLE_BRACKET", "KC_RABK", "KC_GT"]),
            ("?", ["KC_QUESTION", "KC_QUES"]),
            ("§", ["KC_NONUS_BSLASH", "KC_NUBS"]),
            ("RGB", ["RGB_TOG", "RM_TOGG"]),
            ("RGB▸", ["RGB_MOD", "RM_NEXT"]),
            ("RGB◂", ["RGB_RMOD", "RM_PREV"]),
            ("Hue+", ["RGB_HUI", "RM_HUEU"]),
            ("Hue-", ["RGB_HUD", "RM_HUED"]),
            ("Sat+", ["RGB_SAI", "RM_SATU"]),
            ("Sat-", ["RGB_SAD", "RM_SATD"]),
            ("RGB+", ["RGB_VAI", "RM_VALU"]),
            ("RGB-", ["RGB_VAD", "RM_VALD"]),
            ("Spd+", ["RGB_SPI", "RM_SPDU"]),
            ("Spd-", ["RGB_SPD", "RM_SPDD"]),
            ("BL", ["BL_TOGG"]),
            ("BL+", ["BL_INC", "BL_UP"]),
            ("BL-", ["BL_DEC", "BL_DOWN"]),
        ]
        for (label, codes) in pairs { for c in codes { t[c] = label } }
        for d in "1234567890" { t["KC_KP_\(d)"] = "KP\(d)"; t["KC_P\(d)"] = "KP\(d)" }
        return t
    }()
}
