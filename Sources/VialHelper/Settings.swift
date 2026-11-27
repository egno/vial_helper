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

    static let defaultGhostCombo = KeyCombo(
        keyCode: UInt32(kVK_ANSI_G),
        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue,
        keyName: "G"
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

/// Where the ghost sits on the active screen.
enum GhostPosition: String, CaseIterable, Identifiable {
    case bottomLeft, bottom, bottomRight, topLeft, top, topRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .top: return "Top"
        case .topRight: return "Top right"
        }
    }
    var isTop: Bool { self == .topLeft || self == .top || self == .topRight }
    /// 0 = left edge, 0.5 = centred, 1 = right edge.
    var horizontal: CGFloat {
        switch self {
        case .bottomLeft, .topLeft: return 0
        case .bottom, .top: return 0.5
        case .bottomRight, .topRight: return 1
        }
    }
}

/// When the ghost is on screen while ghost mode is on. The layer-dependent modes need the
/// keyboard's 0xF4 live state; without it they behave as `always`.
enum GhostVisibility: String, CaseIterable, Identifiable {
    case always, nonBase, fadeOnBase, whileTyping
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: return "Always"
        case .nonBase: return "Only on other layers"
        case .fadeOnBase: return "Fades out on the base layer"
        case .whileTyping: return "While typing"
        }
    }
    /// The modes that hide the ghost after `AppSettings.ghostHideDelay` without activity.
    var hidesWhenIdle: Bool { self == .fadeOnBase || self == .whileTyping }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let vilPath = "vilPath"
        static let hotKey = "hotKey"
        static let layerNames = "layerNames"
        static let encoderMode = "encoderMode"
        static let holdAloneLayer = "holdAloneLayer"
        static let oledStatus = "oledStatus"
        static let customKeycodeNames = "customKeycodeNames"
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

    /// Comma-separated names of the firmware's custom keycodes (USER00, USER01, …), e.g. "Jiggle, Trainer".
    @Published var customKeycodeNames: String {
        didSet { defaults.set(customKeycodeNames, forKey: Key.customKeycodeNames) }
    }

    /// Custom keycode names indexed by USER number ("" where unnamed).
    var customKeycodeNameList: [String] {
        customKeycodeNames.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Which encoder legends to draw.
    @Published var encoderMode: EncoderMode {
        didSet { defaults.set(encoderMode.rawValue, forKey: Key.encoderMode) }
    }

    /// Layer the firmware reads hold-alone actions from (see vial_full/hold_alone.c).
    /// `holdAloneOff`, `holdAloneLast` or a layer number.
    @Published var holdAloneLayer: Int {
        didSet { defaults.set(holdAloneLayer, forKey: Key.holdAloneLayer) }
    }

    /// Feed the clock and input source to the keyboard's right OLED (see StatusFeeder).
    @Published var oledStatus: Bool {
        didSet { defaults.set(oledStatus, forKey: Key.oledStatus) }
    }

    /// With a single layer zoomed, the overlay switches to the keyboard's highest active layer
    /// as it changes (needs firmware with the 0xF4 live state; see LiveKeyboard). Off by default.
    @Published var followActiveLayer: Bool = UserDefaults.standard.object(forKey: "followActiveLayer") as? Bool ?? true {
        didSet { defaults.set(followActiveLayer, forKey: "followActiveLayer") }
    }

    /// Where the overlay's keymap comes from: the `.vil` file, or the keyboard itself (read over
    /// the Vial protocol) whenever it is connected, with the file as fallback. See VialLiveKeymap.
    @Published var keymapSource: KeymapSourceSetting =
        KeymapSourceSetting(rawValue: UserDefaults.standard.string(forKey: "keymapSource") ?? "") ?? .keyboard {
        didSet { defaults.set(keymapSource.rawValue, forKey: "keymapSource") }
    }

    // MARK: Ghost mode (see GhostOverlay.swift)

    /// The click-through keymap of the active layer is on screen.
    @Published var ghostMode: Bool = UserDefaults.standard.bool(forKey: "ghostMode") {
        didSet { defaults.set(ghostMode, forKey: "ghostMode") }
    }

    /// Global shortcut that toggles ghost mode; nil = none.
    @Published var ghostHotKey: KeyCombo? = AppSettings.loadCombo("ghostHotKey", fallback: .defaultGhostCombo) {
        didSet { AppSettings.saveCombo(ghostHotKey, key: "ghostHotKey") }
    }

    /// Opacity of the ghost's dark plates, `ghostOpacityRange`; the legends on them stay opaque.
    @Published var ghostOpacity: Double = AppSettings.clamped(UserDefaults.standard.object(forKey: "ghostOpacity") as? Double ?? 0.55, ghostOpacityRange) {
        didSet { defaults.set(ghostOpacity, forKey: "ghostOpacity") }
    }

    /// Key unit of the ghost in points, `ghostSizeRange`.
    @Published var ghostSize: Double = AppSettings.clamped(UserDefaults.standard.object(forKey: "ghostSize") as? Double ?? 36, ghostSizeRange) {
        didSet { defaults.set(ghostSize, forKey: "ghostSize") }
    }

    @Published var ghostPosition: GhostPosition =
        GhostPosition(rawValue: UserDefaults.standard.string(forKey: "ghostPosition") ?? "") ?? .bottom {
        didSet { defaults.set(ghostPosition.rawValue, forKey: "ghostPosition") }
    }

    /// The ghost keeps to the tap legend and the hold legend of tap-hold keys, in larger type
    /// (see `KeyLabel.simplified`). On by default.
    @Published var ghostSimplifiedLabels: Bool = AppSettings.bool("ghostSimplifiedLabels", default: true) {
        didSet { defaults.set(ghostSimplifiedLabels, forKey: "ghostSimplifiedLabels") }
    }

    /// On upper layers the ghost leaves out the keys inherited from the layers below (a diff view).
    @Published var ghostHideInherited: Bool = AppSettings.bool("ghostHideInherited", default: false) {
        didSet { defaults.set(ghostHideInherited, forKey: "ghostHideInherited") }
    }

    /// The ghost marks the keys that are physically down (0xF7 matrix events, see LiveKeyboard).
    /// Off by default: it has the keyboard tell the host which key positions are pressed.
    @Published var ghostHighlightPressed: Bool = AppSettings.bool("ghostHighlightPressed", default: false) {
        didSet { defaults.set(ghostHighlightPressed, forKey: "ghostHighlightPressed") }
    }

    /// `bool(forKey:)` rather than a cast, so `-key YES` on the command line works for renders.
    private static func bool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
    }

    /// When the ghost is shown while ghost mode is on.
    @Published var ghostVisibility: GhostVisibility =
        GhostVisibility(rawValue: UserDefaults.standard.string(forKey: "ghostVisibility") ?? "") ?? .always {
        didSet { defaults.set(ghostVisibility.rawValue, forKey: "ghostVisibility") }
    }

    /// The ghost fades almost away while the pointer is over it (it cannot be clicked anyway).
    /// Seconds without activity after which the ghost fades out (`GhostVisibility.hidesWhenIdle`).
    @Published var ghostHideDelay: Double = AppSettings.clamped(UserDefaults.standard.object(forKey: "ghostHideDelay") as? Double ?? 3, ghostHideDelayRange) {
        didSet { defaults.set(ghostHideDelay, forKey: "ghostHideDelay") }
    }
    static let ghostHideDelayRange = 1.0...15.0

    @Published var ghostAvoidPointer: Bool = UserDefaults.standard.object(forKey: "ghostAvoidPointer") as? Bool ?? true {
        didSet { defaults.set(ghostAvoidPointer, forKey: "ghostAvoidPointer") }
    }

    /// Keeps the ghost out of screenshots and screen sharing.
    @Published var ghostHideFromSharing: Bool = UserDefaults.standard.bool(forKey: "ghostHideFromSharing") {
        didSet { defaults.set(ghostHideFromSharing, forKey: "ghostHideFromSharing") }
    }

    /// Places chosen with "Move Ghost…", per screen (display UUID): the fraction [x, y] of the free
    /// room in the screen's visible frame, so a place survives a resolution change. A screen
    /// without an entry uses `ghostPosition`.
    @Published var ghostCustomPlaces: [String: [Double]] =
        UserDefaults.standard.dictionary(forKey: "ghostCustomPlaces") as? [String: [Double]] ?? [:] {
        didSet { defaults.set(ghostCustomPlaces, forKey: "ghostCustomPlaces") }
    }

    static let ghostOpacityRange = 0.2...1.0
    static let ghostSizeRange = 24.0...56.0

    private static func clamped(_ v: Double, _ range: ClosedRange<Double>) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    /// A stored shortcut: absent = `fallback`, empty data = deliberately none.
    private static func loadCombo(_ key: String, fallback: KeyCombo?) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        return data.isEmpty ? nil : try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private static func saveCombo(_ combo: KeyCombo?, key: String) {
        UserDefaults.standard.set(combo.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    func hotKey(for slot: HotKeySlot) -> KeyCombo? { slot == .ghost ? ghostHotKey : hotKey }

    func setHotKey(_ combo: KeyCombo?, for slot: HotKeySlot) {
        if slot == .ghost { ghostHotKey = combo } else { hotKey = combo }
    }

    static let holdAloneOff = -1
    static let holdAloneLast = -2

    private init() {
        holdAloneLayer = defaults.object(forKey: Key.holdAloneLayer) == nil ? AppSettings.holdAloneOff : defaults.integer(forKey: Key.holdAloneLayer)
        encoderMode = EncoderMode(rawValue: defaults.string(forKey: Key.encoderMode) ?? "") ?? .both
        oledStatus = defaults.object(forKey: Key.oledStatus) == nil ? true : defaults.bool(forKey: Key.oledStatus)
        vilPath = defaults.string(forKey: Key.vilPath) ?? AppSettings.defaultPath
        layerNames = defaults.string(forKey: Key.layerNames) ?? ""
        customKeycodeNames = defaults.string(forKey: Key.customKeycodeNames) ?? ""
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
