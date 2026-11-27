import Foundation

struct TapDance: Equatable {
    var tap: String
    var hold: String
    var doubleTap: String
    var tapHold: String
    var term: Int
}

struct Combo: Equatable {
    var keys: [String]
    var result: String
}

/// One entry of the `.vil` "key_override" list (`vial_key_override_entry_t` in vial-qmk's vial.h).
struct KeyOverride: Equatable {
    var trigger: String
    var replacement: String
    /// Bit n = active on layer n (16 bits).
    var layers: Int
    /// `MOD_BIT_*` masks: bits 0-3 left Ctrl/Shift/Alt/GUI, bits 4-7 the right ones.
    var triggerMods: Int
    var negativeMods: Int
    var suppressedMods: Int
    /// `vial_ko_*` bits; bit 7 = enabled, bit 3 = any one of the trigger mods is enough.
    var options: Int

    var isEnabled: Bool { options & 0x80 != 0 }
    var anyOneMod: Bool { options & 0x08 != 0 }
    /// Enabled and it does something: has a trigger key or trigger mods, and a replacement.
    var isActive: Bool {
        isEnabled && layers & 0xFFFF != 0 && !Keycode.isEmpty(replacement)
            && (!Keycode.isEmpty(trigger) || triggerMods != 0)
    }

    /// Layers it is limited to, or nil when it applies on every one of the `count` layers.
    func layerRestriction(layerCount count: Int) -> [Int]? {
        let all = (0..<min(count, 16)).filter { layers & (1 << $0) != 0 }
        return all.count == min(count, 16) ? nil : all
    }
}

/// Vial "QMK Settings" (`settings` in the `.vil`), keyed by QSID as in quantum/qmk_settings.c.
struct QmkSettings: Equatable {
    var values: [Int: Int]

    // QSIDs, from the `protos` table in quantum/qmk_settings.c. 22/23/24/26 are single bits of
    // QS.tapping_v2 (permissive hold, hold on other key press, retro tapping, chordal hold);
    // Vial exports each as its own 0/1 value.
    static let tappingTerm = 7, permissiveHold = 22, holdOnOtherKeyPress = 23, retroTapping = 24
    static let quickTapTerm = 25, chordalHold = 26, flowTapTerm = 27

    /// Tap-hold settings as short phrases, e.g. ["Tapping 200 ms", "Chordal Hold on"].
    /// Only settings present in the file are listed.
    var tapHoldSummary: [String] {
        var out: [String] = []
        func ms(_ id: Int, _ name: String, zeroIsOff: Bool = false) {
            guard let v = values[id] else { return }
            out.append(v == 0 && zeroIsOff ? "\(name) off" : "\(name) \(v) ms")
        }
        func flag(_ id: Int, _ name: String, onlyWhenOn: Bool = false) {
            guard let v = values[id], v != 0 || !onlyWhenOn else { return }
            out.append("\(name) \(v != 0 ? "on" : "off")")
        }
        ms(QmkSettings.tappingTerm, "Tapping")
        ms(QmkSettings.quickTapTerm, "Quick Tap")
        flag(QmkSettings.permissiveHold, "Permissive Hold")
        flag(QmkSettings.holdOnOtherKeyPress, "Hold On Other Key")
        flag(QmkSettings.retroTapping, "Retro Tapping", onlyWhenOn: true)
        flag(QmkSettings.chordalHold, "Chordal Hold")
        ms(QmkSettings.flowTapTerm, "Flow Tap", zeroIsOff: true)
        return out
    }
}

enum VilError: LocalizedError {
    case notFound(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "File not found: \(p)"
        case .invalid(let why): return "Invalid .vil file: \(why)"
        }
    }
}

/// Parsed Vial keymap export (`.vil`).
struct VilFile: Equatable {
    var path: String
    /// layer -> matrix row -> matrix column -> keycode string ("-1" = no key at this position)
    var layers: [[[String]]]
    /// layer -> encoder index -> [counter-clockwise, clockwise]
    var encoders: [[[String]]]
    var combos: [Combo]
    var tapDances: [TapDance]
    var layoutOptions: Int
    /// Enabled, non-empty key overrides.
    var keyOverrides: [KeyOverride] = []
    /// nil when the file has no "settings" object.
    var settings: QmkSettings? = nil

    /// Non-nil when the keymap was read from the keyboard (`VialSnapshot`) instead of a file:
    /// what to show in place of the file name, e.g. "Aurora Corne rev1 · live". `path` is "" then.
    var liveName: String? = nil

    var rows: Int { layers.first?.count ?? 0 }
    var cols: Int { layers.first?.first?.count ?? 0 }
    var isLive: Bool { liveName != nil }
    /// Where the keymap came from, for headers and menus: the file name, or `liveName`.
    var fileName: String { liveName ?? (path as NSString).lastPathComponent }

    /// A layer is empty when every key is absent, KC_NO or KC_TRNS.
    func isLayerEmpty(_ index: Int) -> Bool {
        guard index < layers.count else { return true }
        return layers[index].allSatisfy { row in
            row.allSatisfy { Keycode.isEmpty($0) || Keycode.isTransparent($0) }
        }
    }

    /// Indices of layers that have at least one real binding.
    var nonEmptyLayers: [Int] { layers.indices.filter { !isLayerEmpty($0) } }

    func keycode(layer: Int, row: Int, col: Int) -> String {
        guard layer < layers.count, row < layers[layer].count, col < layers[layer][row].count else { return "-1" }
        return layers[layer][row][col]
    }

    /// Why a hold-alone binding at this position can never fire, or nil if it can (or there is none).
    func holdAloneProblem(layer: Int, row: Int, col: Int) -> String? {
        let code = keycode(layer: layer, row: row, col: col)
        if code == "-1" || Keycode.isEmpty(code) || Keycode.isTransparent(code) { return nil }
        if !Keycode.isHoldAloneSendable(code) { return "not sendable" }
        let armed = layers.indices.contains { $0 != layer && Keycode.isTapHold(keycode(layer: $0, row: row, col: col)) }
        return armed ? nil : "no tap-hold key"
    }

    static func load(path: String) throws -> VilFile {
        guard FileManager.default.fileExists(atPath: path) else { throw VilError.notFound(path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch { throw VilError.invalid("not JSON (\(error.localizedDescription))") }
        guard let root = json as? [String: Any] else { throw VilError.invalid("root is not an object") }
        return try parse(root: root, path: path)
    }

    /// Builds the model from the decoded JSON object of a `.vil` (also used for a live read,
    /// which is first put into the same shape: see `VialSnapshot.vilJSON`).
    static func parse(root: [String: Any], path: String, liveName: String? = nil) throws -> VilFile {
        guard let layout = root["layout"] as? [[[Any]]] else { throw VilError.invalid("missing \"layout\"") }

        let layers = layout.map { $0.map { $0.map(keycodeString) } }
        guard let first = layers.first, !first.isEmpty else { throw VilError.invalid("no layers") }

        let encoders = (root["encoder_layout"] as? [[[Any]]] ?? []).map { $0.map { $0.map(keycodeString) } }

        let combos: [Combo] = (root["combo"] as? [[Any]] ?? []).compactMap { raw in
            let items = raw.map(keycodeString)
            guard items.count >= 2 else { return nil }
            let result = items[items.count - 1]
            let keys = items.dropLast().filter { !Keycode.isEmpty($0) }
            guard !keys.isEmpty, !Keycode.isEmpty(result) else { return nil }
            return Combo(keys: keys, result: result)
        }

        let tapDances: [TapDance] = (root["tap_dance"] as? [[Any]] ?? []).map { raw in
            let s = raw.map(keycodeString)
            func at(_ i: Int) -> String { i < s.count ? s[i] : "KC_NO" }
            let term = (raw.count > 4 ? raw[4] as? Int : nil) ?? 200
            return TapDance(tap: at(0), hold: at(1), doubleTap: at(2), tapHold: at(3), term: term)
        }

        return VilFile(
            path: path,
            layers: layers,
            encoders: encoders,
            combos: combos,
            tapDances: tapDances,
            layoutOptions: root["layout_options"] as? Int ?? 0,
            keyOverrides: keyOverrides(root["key_override"]),
            settings: settings(root["settings"]),
            liveName: liveName
        )
    }

    private static func keyOverrides(_ raw: Any?) -> [KeyOverride] {
        (raw as? [[String: Any]] ?? []).map { e in
            func int(_ k: String) -> Int { (e[k] as? NSNumber)?.intValue ?? 0 }
            return KeyOverride(
                trigger: keycodeString(e["trigger"] ?? "KC_NO"),
                replacement: keycodeString(e["replacement"] ?? "KC_NO"),
                layers: int("layers"),
                triggerMods: int("trigger_mods"),
                negativeMods: int("negative_mod_mask"),
                suppressedMods: int("suppressed_mods"),
                options: int("options")
            )
        }.filter(\.isActive)
    }

    private static func settings(_ raw: Any?) -> QmkSettings? {
        guard let dict = raw as? [String: Any] else { return nil }
        var values: [Int: Int] = [:]
        for (k, v) in dict {
            if let id = Int(k), let n = v as? NSNumber { values[id] = n.intValue }
        }
        return values.isEmpty ? nil : QmkSettings(values: values)
    }

    static func keycodeString(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? Int { return n < 0 ? "-1" : "KC_\(n)" }
        if let n = v as? NSNumber { return n.intValue < 0 ? "-1" : "KC_\(n.intValue)" }
        return "KC_NO"
    }
}
