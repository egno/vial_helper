import AppKit
import Carbon.HIToolbox
import Combine

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt // NSEvent.ModifierFlags raw value
    var keyName: String

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + keyName
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static let defaultCombo = KeyCombo(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue,
        keyName: "K"
    )

    /// Builds a combo from a key-down event, or nil if the event is not a usable shortcut.
    static func from(event: NSEvent) -> KeyCombo? {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let code = Int(event.keyCode)
        let isFunctionKey = functionKeyNames[code] != nil
        guard isFunctionKey || !mods.intersection([.command, .control, .option]).isEmpty else { return nil }
        return KeyCombo(keyCode: UInt32(code), modifiers: mods.rawValue, keyName: keyName(for: event))
    }

    static func keyName(for event: NSEvent) -> String {
        let code = Int(event.keyCode)
        if let n = specialKeyNames[code] ?? functionKeyNames[code] { return n }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.uppercased()
        }
        return "#\(code)"
    }

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "PgUp", kVK_PageDown: "PgDn",
        kVK_ANSI_Grave: "`", kVK_ANSI_KeypadEnter: "⌤",
    ]
}

enum EncoderMode: String, CaseIterable, Identifiable {
    case both, left, right, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return "Both"
        case .left: return "Left only"
        case .right: return "Right only"
        case .none: return "None"
        }
    }
    /// Encoder slot 0 is the left half, slot 1 the right half.
    func shows(index: Int) -> Bool {
        switch self {
        case .both: return true
        case .left: return index == 0
        case .right: return index == 1
        case .none: return false
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let vilPath = "vilPath"
        static let hotKey = "hotKey"
        static let layerNames = "layerNames"
        static let encoderMode = "encoderMode"
    }

    static let defaultPath = "~/aurora.vil"

    @Published var vilPath: String {
        didSet { defaults.set(vilPath, forKey: Key.vilPath) }
    }

    /// nil = no global shortcut.
    @Published var hotKey: KeyCombo? {
        didSet {
            if let hk = hotKey, let data = try? JSONEncoder().encode(hk) {
                defaults.set(data, forKey: Key.hotKey)
            } else {
                defaults.set(Data(), forKey: Key.hotKey)
            }
        }
    }

    /// Comma-separated layer names, e.g. "Base, Nav, Sym".
    @Published var layerNames: String {
        didSet { defaults.set(layerNames, forKey: Key.layerNames) }
    }

    /// Which encoder legends to draw.
    @Published var encoderMode: EncoderMode {
        didSet { defaults.set(encoderMode.rawValue, forKey: Key.encoderMode) }
    }

    private init() {
        encoderMode = EncoderMode(rawValue: defaults.string(forKey: Key.encoderMode) ?? "") ?? .both
        vilPath = defaults.string(forKey: Key.vilPath) ?? AppSettings.defaultPath
        layerNames = defaults.string(forKey: Key.layerNames) ?? ""
        if let data = defaults.data(forKey: Key.hotKey) {
            hotKey = data.isEmpty ? nil : try? JSONDecoder().decode(KeyCombo.self, from: data)
        } else {
            hotKey = .defaultCombo
        }
    }

    var expandedPath: String {
        let p = vilPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return ((p.isEmpty ? AppSettings.defaultPath : p) as NSString).expandingTildeInPath
    }

    /// Layer names as a list indexed by layer number ("" where unnamed).
    var layerNameList: [String] {
        layerNames.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func layerName(_ index: Int) -> String? {
        let names = layerNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard index < names.count, !names[index].isEmpty else { return nil }
        return names[index]
    }
}
