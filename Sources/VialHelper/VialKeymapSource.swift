import Foundation
import Combine

/// Settings → "Keymap source".
enum KeymapSourceSetting: String, CaseIterable, Identifiable {
    case file, keyboard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .file: return "File"
        case .keyboard: return "Keyboard when connected (fall back to file)"
        }
    }
}

/// The keymap as read live from the keyboard over the Vial protocol (`VialReader`).
///
/// `keymap` is non-nil only while the keyboard source is selected, the keyboard is connected
/// and the last read succeeded; `KeymapModel` shows it in place of the `.vil` file then, and
/// the file otherwise. The protocol has no cheap "keymap changed" indicator, so the cached
/// keymap is shown at once and re-read in the background (about 170 requests, well under a
/// second) on connect, whenever the overlay opens and on "Reload Keymap"; `onChange` fires
/// only when the result differs. A failed read drops back to the file and is retried twice.
final class VialLiveKeymap {
    /// Called on the main thread when `keymap` or `note` changed.
    var onChange: (() -> Void)?
    private(set) var keymap: VilFile?
    private(set) var snapshot: VialSnapshot?
    /// One line for the settings window: reading, or why the keyboard keymap is not shown.
    private(set) var note: String?
    /// Matrix shape to assume without a usable definition (set from the last loaded `.vil`).
    var fallback = VialReader.Fallback()
    /// Per-request timeout; debug runs lower it to force a failure.
    var timeout: TimeInterval = 0.4
    /// Debug: never fetch the definition.
    var skipDefinition = false
    /// A re-read this soon after a successful one is skipped unless forced.
    static let minInterval: TimeInterval = 2
    static let retryDelay: TimeInterval = 3
    static let maxRetries = 2

    private var link: KeyboardLink?
    private var cancellables = Set<AnyCancellable>()
    private var enabled = true
    private var connected = false
    private var reading = false
    private var rereadWhenDone = false
    private var lastSuccess = Date.distantPast
    private var definition: (uid: UInt64, definition: VialDefinition)?
    private var failures = 0
    /// Bumped on disconnect / disable so a read that was in flight is ignored.
    private var generation = 0

    /// Starts following the keyboard connection and the "Keymap source" setting.
    func start(link: KeyboardLink, settings: AppSettings) {
        self.link = link
        settings.$keymapSource.removeDuplicates()
            .sink { [weak self] in self?.update(enabled: $0 == .keyboard) }
            .store(in: &cancellables)
        link.$isConnected.removeDuplicates()
            .sink { [weak self] in self?.update(connected: $0) }
            .store(in: &cancellables)
    }

    private func update(enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled { refresh(force: true) } else { reset(note: nil) }
    }

    private func update(connected: Bool) {
        guard connected != self.connected else { return }
        self.connected = connected
        if connected {
            failures = 0
            refresh(force: true)
        } else {
            definition = nil // may be another keyboard, or new firmware, next time
            reset(note: nil)
        }
    }

    private func reset(note: String?) {
        generation += 1
        reading = false
        rereadWhenDone = false
        let changed = keymap != nil || self.note != note
        keymap = nil
        snapshot = nil
        self.note = note
        if changed { onChange?() }
    }

    /// Re-reads the keymap in the background if the keyboard source is on and the keyboard is
    /// there. Not forced: skipped right after a successful read.
    func refresh(force: Bool) {
        guard enabled, connected, let link else { return }
        if reading {
            rereadWhenDone = rereadWhenDone || force
            return
        }
        if !force, Date().timeIntervalSince(lastSuccess) < Self.minInterval { return }
        reading = true
        if keymap == nil, note == nil {
            note = "Reading the keymap from the keyboard…"
            onChange?()
        }
        let generation = self.generation
        Self.read(link: link, timeout: timeout, cached: definition, fallback: fallback, skipDefinition: skipDefinition) { [weak self] result, reader in
            guard let self, generation == self.generation else { return }
            self.reading = false
            switch result {
            case .success(let snapshot):
                if let d = reader.definition { self.definition = (snapshot.uid, d) }
                self.failures = 0
                self.lastSuccess = Date()
                self.adopt(snapshot, productName: link.productName)
            case .failure(let error):
                self.failures += 1
                self.reset(note: "Keyboard keymap not read (\(error.localizedDescription)); showing the file.")
                if self.failures <= Self.maxRetries {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                        guard let self, self.keymap == nil else { return }
                        self.refresh(force: true)
                    }
                }
                return
            }
            if self.rereadWhenDone {
                self.rereadWhenDone = false
                self.refresh(force: true)
            }
        }
    }

    /// Makes `snapshot` the live keymap (also used directly by the debug renders).
    func adopt(_ snapshot: VialSnapshot, productName: String?) {
        guard snapshot != self.snapshot || keymap == nil || note != nil else { return }
        do {
            let name = (productName ?? "Keyboard") + " · live"
            keymap = try VilFile.parse(root: snapshot.vilJSON(), path: "", liveName: name)
            self.snapshot = snapshot
            note = nil
        } catch {
            keymap = nil
            self.snapshot = nil
            note = "Keyboard keymap not usable (\(error.localizedDescription)); showing the file."
        }
        onChange?()
    }

    /// One read; the reader is handed back for its statistics and the definition it fetched.
    static func read(link: KeyboardLink, timeout: TimeInterval = 0.4, cached: (uid: UInt64, definition: VialDefinition)? = nil,
                     fallback: VialReader.Fallback = VialReader.Fallback(), skipDefinition: Bool = false,
                     completion: @escaping (Result<VialSnapshot, VialReadError>, VialReader) -> Void) {
        let reader = VialReader(transport: link.transport, timeout: timeout, cached: cached, fallback: fallback,
                                skipDefinition: skipDefinition)
        reader.read { completion($0, reader) }
    }
}

extension VialReader.Fallback {
    /// The shape of a loaded `.vil`: its matrix size, which positions hold "-1", its encoder slots.
    init(file: VilFile) {
        var positions = Set<Int>()
        for (r, row) in (file.layers.first ?? []).enumerated() {
            for (c, code) in row.enumerated() where code != "-1" { positions.insert(VialDefinition.position(row: r, col: c)) }
        }
        self.init(rows: file.rows, cols: file.cols, positions: positions.isEmpty ? nil : positions,
                  encoderCount: file.encoders.first?.count ?? 0, label: "last loaded .vil (\(file.fileName))")
    }
}

// MARK: - Debug command line

/// `--vial-dump out.json`  read everything live, write it as .vil-like JSON, exit.
/// `--vial-diff [file]`    compare the live read with a .vil (default: the configured one)
///                         field by field, print every difference, exit 0 (same) / 2 (differs).
/// `--render out.png --live`  render the overlay from the live read (falls back to the file,
///                         saying why, when the read fails).
/// Modifiers: `--vial-timeout S` per-request timeout (a tiny one forces the fallback),
/// `--vial-no-definition` skip the definition and use the .vil's matrix shape.
enum VialDebug {
    static func handleCommandLine(model: KeymapModel, settings: AppSettings, link: KeyboardLink,
                                  render: @escaping () -> Void) -> Bool {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
            return args[i + 1]
        }
        let dumpPath = value(after: "--vial-dump")
        let wantsDiff = args.contains("--vial-diff")
        let wantsRender = args.contains("--render") && args.contains("--live")
        guard dumpPath != nil || wantsDiff || wantsRender else { return false }

        let filePath = value(after: "--vial-diff").map { ($0 as NSString).expandingTildeInPath } ?? settings.expandedPath
        let timeout = value(after: "--vial-timeout").flatMap(TimeInterval.init) ?? 0.4
        let skipDefinition = args.contains("--vial-no-definition")
        let file = try? VilFile.load(path: settings.expandedPath)
        let fallback = file.map(VialReader.Fallback.init(file:)) ?? VialReader.Fallback()

        func fail(_ why: String) {
            if wantsRender {
                print("live read failed: \(why); rendering from the file")
                return render()
            }
            print("live read failed: \(why)")
            exit(1)
        }

        link.start()
        link.whenConnected(timeout: 2) { connected in
            guard connected else { return fail("keyboard not connected") }
            let started = Date()
            VialLiveKeymap.read(link: link, timeout: timeout, fallback: fallback, skipDefinition: skipDefinition) { result, reader in
                let snapshot: VialSnapshot
                switch result {
                case .success(let s): snapshot = s
                case .failure(let error): return fail(error.localizedDescription)
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                print("read \(link.productName ?? "keyboard") in \(ms) ms, \(reader.requestCount) requests: "
                    + "\(snapshot.layerCount) layers, \(snapshot.rows)x\(snapshot.cols) matrix (\(snapshot.dimensionSource)), "
                    + "\(snapshot.encoders.first?.count ?? 0) encoders, \(snapshot.tapDances.count) tap dances, "
                    + "\(snapshot.combos.count) combos, \(snapshot.keyOverrides.count) key overrides, "
                    + "\(snapshot.settings.count) settings, \(snapshot.macroCount) macros (not read)")
                if let names = snapshot.customKeycodeNames { print("custom keycodes: \(names.joined(separator: ", "))") }
                if let path = dumpPath {
                    do {
                        let data = try JSONSerialization.data(withJSONObject: snapshot.vilJSON(), options: [.sortedKeys])
                        try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                        print("wrote \(path)")
                    } catch {
                        print("could not write \(path): \(error.localizedDescription)")
                        exit(1)
                    }
                }
                var differs = false
                if wantsDiff {
                    let lines = diff(snapshot, against: filePath)
                    lines.forEach { print($0) }
                    differs = lines.count > 1
                }
                if wantsRender {
                    model.live.adopt(snapshot, productName: link.productName)
                    return render()
                }
                exit(differs ? 2 : 0)
            }
        }
        return true
    }

    /// Every difference between the live read and the `.vil` at `path`, one per line, after a
    /// summary line. Keycodes of the live side carry their raw value.
    static func diff(_ snapshot: VialSnapshot, against path: String) -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["cannot read \(path)", "(no comparison)"]
        }
        let live = snapshot.vilJSON()
        var out: [String] = []
        func text(_ v: Any?) -> String {
            guard let v else { return "(missing)" }
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return "\(v)"
        }
        func hex(_ code: UInt16) -> String { String(format: "0x%04X", code) }
        func compare(_ what: String, _ a: Any?, _ b: Any?, raw: UInt16? = nil) {
            let (l, f) = (text(a), text(b))
            if l != f { out.append("\(what): keyboard \(l)\(raw.map { " [\(hex($0))]" } ?? "") | file \(f)") }
        }
        func count(_ what: String, _ a: Int, _ b: Int) {
            if a != b { out.append("\(what): keyboard has \(a), file has \(b)") }
        }

        for key in ["uid", "vial_protocol", "via_protocol", "layout_options"] { compare(key, live[key], file[key]) }

        let fileLayout = file["layout"] as? [[[Any]]] ?? []
        count("layers", snapshot.layerCount, fileLayout.count)
        for l in 0..<min(snapshot.layerCount, fileLayout.count) {
            count("layer \(l) rows", snapshot.rows, fileLayout[l].count)
            for r in 0..<min(snapshot.rows, fileLayout[l].count) {
                count("layer \(l) row \(r) columns", snapshot.cols, fileLayout[l][r].count)
                for c in 0..<min(snapshot.cols, fileLayout[l][r].count) {
                    let mine = (live["layout"] as! [[[Any]]])[l][r][c]
                    compare("layout[\(l)][\(r)][\(c)]", mine, fileLayout[l][r][c], raw: snapshot.code(layer: l, row: r, col: c))
                }
            }
        }

        let fileEncoders = file["encoder_layout"] as? [[[Any]]] ?? []
        count("encoder layers", snapshot.encoders.count, fileEncoders.count)
        for l in 0..<min(snapshot.encoders.count, fileEncoders.count) {
            count("layer \(l) encoders", snapshot.encoders[l].count, fileEncoders[l].count)
            for e in 0..<min(snapshot.encoders[l].count, fileEncoders[l].count) {
                for (d, dir) in ["ccw", "cw"].enumerated() where d < fileEncoders[l][e].count {
                    let code = snapshot.encoders[l][e][d]
                    compare("encoder_layout[\(l)][\(e)] \(dir)", snapshot.name(code), fileEncoders[l][e][d], raw: code)
                }
            }
        }

        func entries(_ key: String, _ mine: [[UInt16]], keycodes: Int) {
            let theirs = file[key] as? [[Any]] ?? []
            count(key + " entries", mine.count, theirs.count)
            for i in 0..<min(mine.count, theirs.count) {
                count("\(key)[\(i)] fields", mine[i].count, theirs[i].count)
                for j in 0..<min(mine[i].count, theirs[i].count) {
                    if j < keycodes {
                        compare("\(key)[\(i)][\(j)]", snapshot.name(mine[i][j]), theirs[i][j], raw: mine[i][j])
                    } else {
                        compare("\(key)[\(i)][\(j)]", Int(mine[i][j]), theirs[i][j])
                    }
                }
            }
        }
        entries("tap_dance", snapshot.tapDances, keycodes: 4)
        entries("combo", snapshot.combos, keycodes: 5)

        let fileOverrides = file["key_override"] as? [[String: Any]] ?? []
        let liveOverrides = live["key_override"] as? [[String: Any]] ?? []
        count("key_override entries", liveOverrides.count, fileOverrides.count)
        for i in 0..<min(liveOverrides.count, fileOverrides.count) {
            let e = snapshot.keyOverrides[i]
            for key in Set(liveOverrides[i].keys).union(fileOverrides[i].keys).sorted() {
                let raw: UInt16? = key == "trigger" ? e.trigger : key == "replacement" ? e.replacement : nil
                compare("key_override[\(i)].\(key)", liveOverrides[i][key], fileOverrides[i][key], raw: raw)
            }
        }

        let fileSettings = file["settings"] as? [String: Any] ?? [:]
        let liveSettings = live["settings"] as? [String: Any] ?? [:]
        for key in Set(liveSettings.keys).union(fileSettings.keys).sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            compare("settings[\(key)]", liveSettings[key], fileSettings[key])
        }

        let compared = "compared with \(path): layout, encoder_layout, tap_dance, combo, key_override, settings, layout_options, uid, protocols"
        return [out.isEmpty ? "no differences (\(compared))" : "\(out.count) difference(s) (\(compared)):"] + out
    }

    /// Offline checks for `--selftest`: keycode naming, and that the app can label what is emitted.
    static func selfChecks() -> [(String, Bool)] {
        let ctx = VialKeycodes.Context(layers: 7, macros: 16, userKeycodes: 2)
        let expected: [(UInt16, String)] = [
            (0x0000, "KC_NO"), (0x0001, "KC_TRNS"), (0x0004, "KC_A"), (0x002A, "KC_BSPACE"), (0x0226, "LSFT(KC_9)"),
            (0x0235, "LSFT(KC_GRAVE)"), (0x0080 | 0x0800, "LGUI(KC__VOLUP)"), (0x2804, "LGUI_T(KC_A)"), (0x3211, "RSFT_T(KC_N)"),
            (0x412A, "LT1(KC_BSPACE)"), (0x45E7, "LT5(KC_RGUI)"), (0x4704, "0x4704"), (0x5224, "MO(4)"), (0x5227, "0x5227"),
            (0x5700, "TD(0)"), (0x770A, "M10"), (0x7710, "0x7710"), (0x7E00, "USER00"), (0x7E01, "USER01"), (0x7E02, "0x7e02"),
            (0x7C7B, "QK_LAYER_LOCK"), (0x7C73, "QK_CAPS_WORD_TOGGLE"), (0x7C03, "QK_CLEAR_EEPROM"), (0x7013, "MAGIC_TOGGLE_NKRO"),
            (0x7842, "RM_TOGG"), (0x784A, "RM_VALD"), (0x00CD, "KC_MS_U"), (0x00D9, "KC_WH_U"), (0x00A8, "KC_MUTE"),
            (0x00BD, "KC_BRIU"), (0x00A5, "KC_PWR"), (0x0622, "LSA(KC_5)"), (0x1421, "RALT(KC_4)"), (0x52A2, "OSM(MOD_LSFT)"),
            (0x7103, "0x7103"), (0xFFFF, "0xffff"), (0x1304, "0x1304"),
        ]
        let wrong = expected.filter { VialKeycodes.name($0.0, context: ctx) != $0.1 }
        // No code may crash the namer or the labeller, or come out blank unless it is "no key".
        var unlabelled = 0
        for code in 0...UInt16.max {
            let name = VialKeycodes.name(code, context: ctx)
            let label = Keycode.label(name, context: LabelContext())
            // (Blank primary is fine with a secondary: "LT1(KC_NO)" is a bare layer hold.)
            if name.isEmpty || (label.primary.isEmpty && label.secondary == nil && code != 0) {
                unlabelled += 1
                if unlabelled <= 5 { print("  no label: \(name)") }
            }
        }
        return [
            ("Vial keycode names" + (wrong.isEmpty ? "" : " (wrong: \(wrong.map { String(format: "0x%04X", $0.0) }.joined(separator: " ")))"), wrong.isEmpty),
            ("every keycode has a label", unlabelled == 0),
        ]
    }
}
