import Foundation

struct TapDance {
    var tap: String
    var hold: String
    var doubleTap: String
    var tapHold: String
    var term: Int
}

struct Combo {
    var keys: [String]
    var result: String
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
struct VilFile {
    var path: String
    /// layer -> matrix row -> matrix column -> keycode string ("-1" = no key at this position)
    var layers: [[[String]]]
    /// layer -> encoder index -> [counter-clockwise, clockwise]
    var encoders: [[[String]]]
    var combos: [Combo]
    var tapDances: [TapDance]
    var layoutOptions: Int

    var rows: Int { layers.first?.count ?? 0 }
    var cols: Int { layers.first?.first?.count ?? 0 }
    var fileName: String { (path as NSString).lastPathComponent }

    /// A layer is empty when every key is absent, KC_NO or KC_TRNS.
    func isLayerEmpty(_ index: Int) -> Bool {
        guard index < layers.count else { return true }
        return layers[index].allSatisfy { row in
            row.allSatisfy { Keycode.isEmpty($0) || Keycode.isTransparent($0) }
        }
    }

    /// Indices of layers that have at least one real binding.
    var nonEmptyLayers: [Int] { layers.indices.filter { !isLayerEmpty($0) } }

    static func load(path: String) throws -> VilFile {
        guard FileManager.default.fileExists(atPath: path) else { throw VilError.notFound(path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch { throw VilError.invalid("not JSON (\(error.localizedDescription))") }
        guard let root = json as? [String: Any] else { throw VilError.invalid("root is not an object") }
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
            layoutOptions: root["layout_options"] as? Int ?? 0
        )
    }

    private static func keycodeString(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? Int { return n < 0 ? "-1" : "KC_\(n)" }
        if let n = v as? NSNumber { return n.intValue < 0 ? "-1" : "KC_\(n.intValue)" }
        return "KC_NO"
    }
}
