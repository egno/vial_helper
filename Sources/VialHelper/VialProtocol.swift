import Foundation
import Compression

// Read-only client for the VIA/Vial raw HID protocol, as implemented in vial-qmk
// (quantum/via.c `raw_hid_receive`, quantum/vial.c `vial_handle_cmd`, quantum/qmk_settings.c).
// Nothing here changes keyboard state: no set/reset/unlock/lock/bootloader command is ever sent.
//
// Requests are 32-byte reports; the firmware answers in the same buffer, so what a reply
// "echoes" is whatever the handler did not overwrite. That decides how a reply is recognised
// on a device shared with the Vial GUI and with this app's other polling:
//
//   VIA commands keep byte 0 and their arguments -> matched by prefix
//     0x01            protocol version      reply [01, hi, lo]
//     0x02 0x02       layout options        reply [02, 02, u32 big-endian]
//     0x0C            macro count           reply [0C, n]
//     0x11            layer count           reply [11, n]
//     0x12 hi lo n    keymap buffer         reply [12, hi, lo, n, n bytes]: u16 big-endian
//                     keycodes, offset = ((layer * rows) + row) * cols + col, times 2; n <= 28
//
//   Vial commands (0xFE, sub) write the answer from byte 0 -> "next report is the reply",
//   filtered by what the reply layout lets us check (zero padding, status byte, ordering)
//     FE 00           keyboard id           [u32 LE protocol, u64 LE uid, vialrgb flag, 0...]
//     FE 01           definition size       [u32 LE, 0...]
//     FE 02 lo hi     definition page       32 bytes of the XZ-compressed vial.json (no check
//                                           possible per page; the XZ CRC covers the whole)
//     FE 03 layer i   encoder               [ccw u16 BE, cw u16 BE, 0...]
//     FE 05           unlock status         [unlocked, in progress, key rows/cols..., FF...]
//     FE 09 lo hi     settings query        up to 16 u16 LE QSIDs greater than the argument,
//                                           ascending, FFFF-padded
//     FE 0A lo hi     settings get          [status 0, value LE (1/2/4 bytes), request tail]
//     FE 0D 00        dynamic entry counts  [tap dances, combos, key overrides, alt repeat,
//                                           0..., feature bits in byte 31]
//     FE 0D 01/03/05 i  tap dance / combo / key override i   [status 0, 10-byte entry, 0...]
//                     (u16 fields little-endian: the structs of quantum/vial.h as stored)
//
// A 0xF7 subscription (LiveKeyboard) may be running during a read: the keyboard then sends
// state / matrix events between the replies. `HIDTransport` takes those out by their exact
// shape before any of the matching above, so none can stand in for a reply (a definition page
// would accept anything). Of the replies here only a definition page could itself have that
// shape, which takes 32 bytes of XZ data that begin f7 01 00 / f7 02 00 and end in zeros.
//
// While an unlock is in progress the firmware answers every non-Vial command with the
// unchanged request (`goto skip`), which would read as an all-zero keymap; the read therefore
// checks FE 05 first and gives up if one is running.

enum VialReadError: LocalizedError, Equatable {
    case notConnected
    case timeout(String)
    case notVial
    case unsupported(String)
    case busy
    case malformed(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "keyboard not connected"
        case .timeout(let what): return "no reply to \"\(what)\""
        case .notVial: return "the firmware does not speak the Vial protocol"
        case .unsupported(let why): return "unsupported: \(why)"
        case .busy: return "a Vial unlock is in progress"
        case .malformed(let what): return "unexpected reply to \"\(what)\""
        case .sendFailed(let what): return "could not send \"\(what)\""
        }
    }
}

/// The parts of the keyboard definition (`vial.json`, served XZ-compressed by the firmware)
/// that a keymap read needs.
struct VialDefinition: Equatable {
    var rows: Int
    var cols: Int
    /// Matrix positions that have a key, as `row * 256 + col`.
    var positions: Set<Int>
    var encoderCount: Int
    /// `customKeycodes[].shortName`, nil when the definition has no custom keycodes.
    var customKeycodeNames: [String]?
    /// "basic" / "advanced", nil without MIDI.
    var midi: String?

    static func position(row: Int, col: Int) -> Int { row * 256 + col }

    /// Decodes the XZ stream `util/vial_generate_definition.py` produces (`lzma.compress`
    /// with Python's defaults: XZ container, LZMA2, CRC64). Apple's COMPRESSION_LZMA reads it.
    static func decompress(_ xz: [UInt8]) -> Data? {
        guard xz.count >= 12, Array(xz[..<6]) == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] else { return nil }
        var capacity = max(64 * 1024, xz.count * 16)
        while capacity <= 4 * 1024 * 1024 {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = compression_decode_buffer(&out, capacity, xz, xz.count, nil, COMPRESSION_LZMA)
            if n == 0 { return nil }
            if n < capacity { return Data(out[..<n]) }
            capacity *= 4
        }
        return nil
    }

    /// Reads matrix size, key positions and encoders the way the Vial GUI does: every key of the
    /// KLE `layouts.keymap` carries "row,col" in its first label; encoders are marked with "e"
    /// in label 9 and carry "index,direction" instead.
    static func parse(json: Data) -> VialDefinition? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let matrix = root["matrix"] as? [String: Any],
              let rows = (matrix["rows"] as? NSNumber)?.intValue,
              let cols = (matrix["cols"] as? NSNumber)?.intValue,
              rows > 0, cols > 0, rows <= 255, cols <= 255 else { return nil }
        var positions = Set<Int>()
        var encoders = Set<Int>()
        let keymap = (root["layouts"] as? [String: Any])?["keymap"] as? [Any] ?? []
        for case let row as [Any] in keymap {
            for case let label as String in row {
                let fields = label.components(separatedBy: "\n")
                let pair = fields[0].split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard pair.count == 2, let a = pair[0], let b = pair[1], a >= 0, b >= 0 else { continue }
                if fields.count > 9, fields[9] == "e" {
                    encoders.insert(a)
                } else if a < rows, b < cols {
                    positions.insert(position(row: a, col: b))
                }
            }
        }
        guard !positions.isEmpty else { return nil }
        let custom = (root["customKeycodes"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 }
        return VialDefinition(
            rows: rows, cols: cols, positions: positions,
            encoderCount: (encoders.max() ?? -1) + 1,
            customKeycodeNames: custom?.map { ($0["shortName"] as? String) ?? ($0["name"] as? String) ?? "" },
            midi: root["midi"] as? String
        )
    }
}

/// `vial_key_override_entry_t`.
struct VialKeyOverrideEntry: Equatable {
    var trigger: UInt16
    var replacement: UInt16
    var layers: UInt16
    var triggerMods: UInt8
    var negativeMods: UInt8
    var suppressedMods: UInt8
    var options: UInt8
}

/// Everything one live read returns, as raw numbers.
struct VialSnapshot: Equatable {
    var uid: UInt64
    var vialProtocol: Int
    var viaProtocol: Int
    var layerCount: Int
    var macroCount: Int
    var rows: Int
    var cols: Int
    /// Positions with a key (`VialDefinition.position`), nil = every position.
    var positions: Set<Int>?
    /// Where rows/cols/positions/encoder count came from: "definition", or the fallback's label.
    var dimensionSource: String
    var layoutOptions: Int
    /// `layerCount * rows * cols` keycodes.
    var keymap: [UInt16]
    /// layer -> encoder -> [counter-clockwise, clockwise]
    var encoders: [[[UInt16]]]
    /// on tap, on hold, on double tap, on tap + hold, tapping term
    var tapDances: [[UInt16]]
    /// four inputs, output
    var combos: [[UInt16]]
    var keyOverrides: [VialKeyOverrideEntry]
    /// QSID -> value, for the settings the firmware lists and the Vial GUI knows.
    var settings: [Int: Int]
    var naming: VialKeycodes.Context
    var customKeycodeNames: [String]?

    func code(layer: Int, row: Int, col: Int) -> UInt16 {
        keymap[(layer * rows + row) * cols + col]
    }

    func name(_ code: UInt16) -> String { VialKeycodes.name(code, context: naming) }

    /// The read in the shape of a `.vil` (what `KeyboardComm.save_layout` of vial-gui writes),
    /// minus "macro" and "alt_repeat_key", which are not read.
    func vilJSON() -> [String: Any] {
        var layout: [[[Any]]] = []
        for l in 0..<layerCount {
            var layer: [[Any]] = []
            for r in 0..<rows {
                layer.append((0..<cols).map { c -> Any in
                    if let positions, !positions.contains(VialDefinition.position(row: r, col: c)) { return -1 }
                    return name(code(layer: l, row: r, col: c))
                })
            }
            layout.append(layer)
        }
        var settingsJSON: [String: Any] = [:]
        for (id, value) in settings { settingsJSON[String(id)] = value }
        return [
            "version": 1,
            "uid": NSNumber(value: uid),
            "layout": layout,
            "encoder_layout": encoders.map { $0.map { $0.map { name($0) as Any } } },
            "layout_options": layoutOptions,
            "vial_protocol": vialProtocol,
            "via_protocol": viaProtocol,
            "tap_dance": tapDances.map { e -> [Any] in e.prefix(4).map { name($0) as Any } + [Int(e[4])] },
            "combo": combos.map { $0.map { name($0) as Any } },
            "key_override": keyOverrides.map { e -> [String: Any] in
                [
                    "trigger": name(e.trigger), "replacement": name(e.replacement), "layers": Int(e.layers),
                    "trigger_mods": Int(e.triggerMods), "negative_mod_mask": Int(e.negativeMods),
                    "suppressed_mods": Int(e.suppressedMods), "options": Int(e.options),
                ]
            },
            "settings": settingsJSON,
        ]
    }
}

/// One full read of the keyboard. Create, call `read`, drop. Everything runs on the main
/// thread; requests go through the shared serialized transport, so other users' requests
/// may interleave freely.
final class VialReader {
    /// Matrix shape to assume when the definition cannot be fetched or decoded.
    struct Fallback: Equatable {
        var rows = 8
        var cols = 6
        var positions: Set<Int>? = nil
        var encoderCount = 0
        var label = "default 8x6"
    }

    /// QSID -> value width in bytes, from vial-gui's qmk_settings.json (which matches the field
    /// sizes of `qmk_settings_t`; bit settings are served as one 0/1 byte). The GUI ignores
    /// QSIDs it does not know, and so does this.
    static let settingWidths: [Int: Int] = [
        1: 1, 2: 2, 3: 1, 4: 2, 5: 1, 6: 2, 7: 2, 8: 1, 9: 2, 10: 2, 11: 2, 12: 2, 13: 2, 14: 2, 15: 2, 16: 2,
        17: 2, 18: 2, 19: 2, 20: 1, 21: 4, 22: 1, 23: 1, 24: 1, 25: 2, 26: 1, 27: 2,
    ]
    static let supportedVialProtocol = 6
    static let chunk = 28

    private let transport: HIDTransport
    private let timeout: TimeInterval
    private let retries: Int
    private let fallback: Fallback
    private let skipDefinition: Bool
    /// Definition already fetched from the keyboard with this uid (it cannot change while plugged in).
    private var cached: (uid: UInt64, definition: VialDefinition)?
    private var completion: ((Result<VialSnapshot, VialReadError>) -> Void)?
    private(set) var requestCount = 0
    /// The definition this read used (fetched or cached), nil if the fallback shape was used.
    private(set) var definition: VialDefinition?

    init(transport: HIDTransport, timeout: TimeInterval = 0.4, retries: Int = 1,
         cached: (uid: UInt64, definition: VialDefinition)? = nil, fallback: Fallback = Fallback(),
         skipDefinition: Bool = false) {
        self.transport = transport
        self.timeout = timeout
        self.retries = retries
        self.cached = cached
        self.fallback = fallback
        self.skipDefinition = skipDefinition
    }

    func read(completion: @escaping (Result<VialSnapshot, VialReadError>) -> Void) {
        self.completion = completion
        readIdentity()
    }

    // MARK: - Plumbing

    private func finish(_ result: Result<VialSnapshot, VialReadError>) {
        guard let done = completion else { return }
        completion = nil
        done(result)
    }

    /// Sends one request; `then` gets the 32-byte reply. Timeouts are retried, every other
    /// failure ends the read. `unhandled` (optional) takes a byte-0-is-0xFF answer instead.
    private func send(_ what: String, _ bytes: [UInt8], prefix: Int = 1, accept: (([UInt8]) -> Bool)? = nil,
                      unhandled: (() -> Void)? = nil, attempt: Int = 0, then: @escaping ([UInt8]) -> Void) {
        guard completion != nil else { return }
        requestCount += 1
        let handler: (HIDReply) -> Void = { [self] reply in
            switch reply {
            case .reply(let b): then(b)
            case .timeout:
                if attempt < retries {
                    send(what, bytes, prefix: prefix, accept: accept, unhandled: unhandled, attempt: attempt + 1, then: then)
                } else {
                    finish(.failure(.timeout(what)))
                }
            case .unhandled:
                if let unhandled { unhandled() } else { finish(.failure(bytes[0] == 0xFE ? .notVial : .malformed(what))) }
            case .notConnected: finish(.failure(.notConnected))
            case .sendFailed: finish(.failure(.sendFailed(what)))
            }
        }
        if let accept {
            transport.request(bytes, timeout: timeout, accept: accept, completion: handler)
        } else {
            transport.request(bytes, timeout: timeout, matchPrefix: prefix, completion: handler)
        }
    }

    /// Runs `body(i, next)` for i in 0..<count one after another, then `done`.
    private func each(_ count: Int, _ body: @escaping (Int, @escaping () -> Void) -> Void, done: @escaping () -> Void) {
        func step(_ i: Int) {
            guard i < count else { return done() }
            body(i) { step(i + 1) }
        }
        step(0)
    }

    private static func zero(_ b: [UInt8], from: Int, to: Int = 32) -> Bool {
        b[from..<to].allSatisfy { $0 == 0 }
    }

    private static func le16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
    private static func be16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) << 8 | UInt16(b[at + 1]) }

    // MARK: - Steps

    private var uid: UInt64 = 0
    private var vialProtocol = 0
    private var viaProtocol = 0
    private var layers = 0
    private var macros = 0
    private var layoutOptions = 0
    private var rows = 0
    private var cols = 0
    private var positions: Set<Int>?
    private var encoderCount = 0
    private var dimensionSource = ""
    private var keymapBytes: [UInt8] = []
    private var encoders: [[[UInt16]]] = []
    private var tapDances: [[UInt16]] = []
    private var combos: [[UInt16]] = []
    private var keyOverrides: [VialKeyOverrideEntry] = []
    private var settings: [Int: Int] = [:]

    private func readIdentity() {
        // 14 unlock keys at most, so the last two bytes always keep the 0xFF fill.
        send("unlock status", [0xFE, 0x05], accept: { $0[0] <= 1 && $0[1] <= 1 && $0[30] == 0xFF && $0[31] == 0xFF }) { [self] b in
            guard b[1] == 0 else { return finish(.failure(.busy)) }
            send("keyboard id", [0xFE, 0x00], accept: { Self.zero($0, from: 13) && $0[2] == 0 && $0[3] == 0 && ($0[0] | $0[1]) != 0 }) { [self] b in
                vialProtocol = Int(Self.le16(b, 0))
                uid = b[4..<12].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard vialProtocol == Self.supportedVialProtocol else {
                    return finish(.failure(.unsupported("Vial protocol \(vialProtocol) (keycode names are known for \(Self.supportedVialProtocol))")))
                }
                send("VIA protocol version", [0x01]) { [self] b in
                    viaProtocol = Int(Self.be16(b, 1))
                    send("layer count", [0x11]) { [self] b in
                        layers = Int(b[1])
                        guard layers >= 1, layers <= 32 else { return finish(.failure(.malformed("layer count"))) }
                        send("macro count", [0x0C]) { [self] b in
                            macros = Int(b[1])
                            send("layout options", [0x02, 0x02], prefix: 2) { [self] b in
                                layoutOptions = Int(b[2]) << 24 | Int(b[3]) << 16 | Int(b[4]) << 8 | Int(b[5])
                                readDefinition()
                            }
                        }
                    }
                }
            }
        }
    }

    private func readDefinition() {
        if let cached, cached.uid == uid {
            definition = cached.definition
            return readKeymap()
        }
        if skipDefinition { return readKeymap() }
        send("definition size", [0xFE, 0x01], accept: { Self.zero($0, from: 4) }) { [self] b in
            let size = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
            guard size > 0, size <= 256 * 1024 else { return readKeymap() }
            var payload: [UInt8] = []
            each((size + 31) / 32, { [self] page, next in
                send("definition page \(page)", [0xFE, 0x02, UInt8(page & 0xFF), UInt8(page >> 8)], accept: { _ in true }) { b in
                    payload += b
                    next()
                }
            }, done: { [self] in
                if let json = VialDefinition.decompress(Array(payload.prefix(size))) {
                    definition = VialDefinition.parse(json: json)
                }
                readKeymap()
            })
        }
    }

    private func readKeymap() {
        if let d = definition {
            (rows, cols, positions, encoderCount, dimensionSource) = (d.rows, d.cols, d.positions, d.encoderCount, "definition")
        } else {
            (rows, cols, positions, encoderCount, dimensionSource) =
                (fallback.rows, fallback.cols, fallback.positions, fallback.encoderCount, fallback.label)
        }
        let total = layers * rows * cols * 2
        guard total > 0, total <= 0xFFFF else { return finish(.failure(.malformed("keymap size"))) }
        each((total + Self.chunk - 1) / Self.chunk, { [self] i, next in
            let offset = i * Self.chunk
            let size = min(Self.chunk, total - offset)
            send("keymap buffer at \(offset)", [0x12, UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(size)], prefix: 4) { [self] b in
                keymapBytes += b[4..<(4 + size)]
                next()
            }
        }, done: { [self] in readEncoders() })
    }

    private func readEncoders() {
        encoders = Array(repeating: [], count: layers)
        each(layers * encoderCount, { [self] i, next in
            let layer = i / encoderCount, index = i % encoderCount
            send("encoder \(index) on layer \(layer)", [0xFE, 0x03, UInt8(layer), UInt8(index)], accept: { Self.zero($0, from: 4) }) { [self] b in
                encoders[layer].append([Self.be16(b, 0), Self.be16(b, 2)])
                next()
            }
        }, done: { [self] in readDynamicEntries() })
    }

    private func readDynamicEntries() {
        send("dynamic entry counts", [0xFE, 0x0D, 0x00], accept: { Self.zero($0, from: 4, to: 31) }) { [self] b in
            let (tapDanceCount, comboCount, overrideCount) = (Int(b[0]), Int(b[1]), Int(b[2]))
            /// Ten-byte entry after a zero status byte; the rest of the report stays zero.
            func entry(_ what: String, _ sub: UInt8, _ index: Int, _ then: @escaping ([UInt8]) -> Void) {
                send("\(what) \(index)", [0xFE, 0x0D, sub, UInt8(index)], accept: { $0[0] == 0 && Self.zero($0, from: 11) }) { then(Array($0[1..<11])) }
            }
            func words(_ e: [UInt8]) -> [UInt16] { (0..<5).map { Self.le16(e, $0 * 2) } }
            each(tapDanceCount, { [self] i, next in
                entry("tap dance", 0x01, i) { [self] e in tapDances.append(words(e)); next() }
            }, done: { [self] in
                each(comboCount, { [self] i, next in
                    entry("combo", 0x03, i) { [self] e in combos.append(words(e)); next() }
                }, done: { [self] in
                    each(overrideCount, { [self] i, next in
                        entry("key override", 0x05, i) { [self] e in
                            keyOverrides.append(VialKeyOverrideEntry(
                                trigger: Self.le16(e, 0), replacement: Self.le16(e, 2), layers: Self.le16(e, 4),
                                triggerMods: e[6], negativeMods: e[7], suppressedMods: e[8], options: e[9]))
                            next()
                        }
                    }, done: { [self] in querySettings(after: 0, found: []) })
                })
            })
        }
    }

    /// A settings-query reply: QSIDs greater than `after`, ascending, then 0xFFFF to the end.
    private static func isSettingsList(_ b: [UInt8], after: Int) -> Bool {
        var last = after, ended = false
        for i in stride(from: 0, to: 32, by: 2) {
            let id = Int(le16(b, i))
            if id == 0xFFFF { ended = true; continue }
            if ended || id <= last { return false }
            last = id
        }
        return true
    }

    private func querySettings(after: Int, found: [Int]) {
        send("settings list after \(after)", [0xFE, 0x09, UInt8(after & 0xFF), UInt8(after >> 8)],
             accept: { Self.isSettingsList($0, after: after) }) { [self] b in
            let ids = stride(from: 0, to: 32, by: 2).map { Int(Self.le16(b, $0)) }.filter { $0 != 0xFFFF }
            let all = found + ids
            if ids.count == 16, let last = ids.last, all.count < 1024 {
                querySettings(after: last, found: all)
            } else {
                readSettings(all.filter { Self.settingWidths[$0] != nil })
            }
        }
    }

    private func readSettings(_ ids: [Int]) {
        each(ids.count, { [self] i, next in
            let id = ids[i], width = Self.settingWidths[id] ?? 1
            let request: [UInt8] = [0xFE, 0x0A, UInt8(id & 0xFF), UInt8(id >> 8)]
            // Status 0, the value, then whatever the value did not overwrite of the request.
            let tail = Array((request + [UInt8](repeating: 0, count: 28))[(1 + width)...])
            send("setting \(id)", request, accept: { $0[0] == 0 && Array($0[(1 + width)...]) == tail },
                 unhandled: next /* status -1: the firmware lists it but cannot read it; the GUI skips it too */) { [self] b in
                settings[id] = (0..<width).reduce(0) { $0 | Int(b[1 + $1]) << (8 * $1) }
                next()
            }
        }, done: { [self] in complete() })
    }

    private func complete() {
        let keymap = stride(from: 0, to: keymapBytes.count, by: 2).map { Self.be16(keymapBytes, $0) }
        let naming = VialKeycodes.Context(
            layers: layers, macros: macros,
            userKeycodes: definition?.customKeycodeNames?.count ?? 16,
            midi: definition?.midi)
        finish(.success(VialSnapshot(
            uid: uid, vialProtocol: vialProtocol, viaProtocol: viaProtocol, layerCount: layers, macroCount: macros,
            rows: rows, cols: cols, positions: positions, dimensionSource: dimensionSource,
            layoutOptions: layoutOptions, keymap: keymap, encoders: encoders, tapDances: tapDances, combos: combos,
            keyOverrides: keyOverrides, settings: settings, naming: naming,
            customKeycodeNames: definition?.customKeycodeNames)))
    }
}
