import Foundation

// Parsers for the read-only raw HID replies of the vial_full keymap (0xF3-0xF6; the spec is the
// header comment of host_hid.h in the keymap folder). Pure functions from a 32-byte report to a
// struct, so they can be tested without a keyboard (see LiveSelfTest). Multi-byte fields are
// little-endian. Every parser returns nil for a report that is too short, has the wrong command
// id / sub-command, or carries a status that leaves the payload invalid.

enum LiveReport {
    static func u16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    /// A matrix mask (bit `pos % 8` of byte `pos / 8`, pos = row * cols + col) as `KeyPlacement.id`s
    /// (row * 100 + col).
    static func matrixMask(_ bytes: ArraySlice<UInt8>, cols: Int = 6) -> Set<Int> {
        guard cols > 0 else { return [] }
        var out = Set<Int>()
        for (i, byte) in bytes.enumerated() where byte != 0 {
            for bit in 0..<8 where byte & (1 << UInt8(bit)) != 0 {
                let pos = i * 8 + bit
                out.insert(pos / cols * 100 + pos % cols)
            }
        }
        return out
    }

    /// Layer numbers set in a layer bit mask, ascending.
    static func layers(_ mask: UInt32) -> [Int] { (0..<32).filter { mask & (1 << UInt32($0)) != 0 } }

    /// QMK 8-bit mod mask as symbols; left and right variants fold together.
    static func modSymbols(_ mask: UInt8) -> String {
        let m = (mask | mask >> 4) & 0x0F
        var s = ""
        if m & 1 != 0 { s += "⌃" }
        if m & 4 != 0 { s += "⌥" }
        if m & 2 != 0 { s += "⇧" }
        if m & 8 != 0 { s += "⌘" }
        return s
    }

    /// "f4 00 1a" / "f4,00,1a" / "f4001a" -> bytes, zero-padded to one report.
    static func parseHex(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for token in text.split(whereSeparator: { " ,\n\t".contains($0) }) {
            if token.count <= 2 {
                if let v = UInt8(token, radix: 16) { bytes.append(v) }
            } else {
                var rest = Substring(token)
                while !rest.isEmpty {
                    if let v = UInt8(rest.prefix(2), radix: 16) { bytes.append(v) }
                    rest = rest.dropFirst(2)
                }
            }
        }
        if bytes.count < 32 { bytes += [UInt8](repeating: 0, count: 32 - bytes.count) }
        return bytes
    }
}

// MARK: - 0xF3 misfire log

/// One tracked base-layer mod-tap (reply to [0xF3, 0, index]).
struct MisfireEntry: Equatable {
    var index: Int
    var row: Int
    var col: Int
    var keycode: Int
    /// Settled as hold, then corrected with Backspace ("meant a letter").
    var heldMisfires: Int
    /// Settled as tap while rolled over, then corrected ("meant a modifier"); inflated by typos.
    var tappedMisfires: Int
    var holds: Int
    var taps: Int

    var id: Int { row * 100 + col }

    /// Misfire rates, damped so that a key with a handful of presses cannot top the scale.
    var heldRate: Double { Double(heldMisfires) / (Double(holds) + MisfireEntry.damping) }
    var tappedRate: Double { Double(tappedMisfires) / (Double(taps) + MisfireEntry.damping) }
    static let damping = 20.0

    /// (count of tracked keys, the entry or nil when `index` was out of range).
    static func parse(_ b: [UInt8]) -> (count: Int, entry: MisfireEntry?)? {
        guard b.count >= 21, b[0] == 0xF3, b[1] == 0 else { return nil }
        let count = Int(b[3])
        guard b[2] == 0 else { return b[2] == 1 ? (count, nil) : nil }
        let e = MisfireEntry(index: Int(b[4]), row: Int(b[5]), col: Int(b[6]), keycode: LiveReport.u16(b, 7),
                             heldMisfires: LiveReport.u16(b, 9), tappedMisfires: LiveReport.u16(b, 11),
                             holds: Int(LiveReport.u32(b, 13)), taps: Int(LiveReport.u32(b, 17)))
        return (count, e)
    }
}

/// What a key cap shows for the misfire heatmap.
struct MisfireBadge: Equatable {
    /// 0...1, relative to the worst key of the table (not an absolute rate).
    var heat: Double
    var held: Int
    var tapped: Int

    /// Badges by `KeyPlacement.id`. Held and tapped rates are each scaled to the worst key of
    /// their own kind (tapped counts are inflated by ordinary typos, so the two are not
    /// comparable with each other); a key's heat is the larger of its two shares.
    static func badges(for entries: [MisfireEntry]) -> [Int: MisfireBadge] {
        let maxHeld = entries.map(\.heldRate).max() ?? 0
        let maxTapped = entries.map(\.tappedRate).max() ?? 0
        var out: [Int: MisfireBadge] = [:]
        for e in entries {
            let h = maxHeld > 0 ? e.heldRate / maxHeld : 0
            let t = maxTapped > 0 ? e.tappedRate / maxTapped : 0
            out[e.id] = MisfireBadge(heat: max(h, t), held: e.heldMisfires, tapped: e.tappedMisfires)
        }
        return out
    }
}

// MARK: - 0xF4 live state

struct LiveState: Equatable {
    var highestLayer: Int
    var layerState: UInt32
    var defaultLayerState: UInt32
    var lockedLayers: UInt32
    var flags: UInt8
    /// 0 off, 1 session running, 2 results screen, 3 on but nothing typeable.
    var trainerState: Int
    /// Sessions finished since power-up (u16, wraps).
    var sessionsFinished: Int
    var oneShotMods: UInt8
    var oneShotLockedMods: UInt8
    var oneShotLayer: Int?
    var mods: UInt8
    var weakMods: UInt8
    var layerCount: Int

    var trainerActive: Bool { flags & 1 != 0 }
    var capsWord: Bool { flags & 2 != 0 }
    var capsLock: Bool { flags & 4 != 0 }
    var oneShotLayerPending: Bool { flags & 8 != 0 }

    var activeMask: UInt32 { layerState | defaultLayerState }
    func isActive(_ layer: Int) -> Bool { layer >= 0 && layer < 32 && activeMask & (1 << UInt32(layer)) != 0 }
    func isLocked(_ layer: Int) -> Bool { layer >= 0 && layer < 32 && lockedLayers & (1 << UInt32(layer)) != 0 }
    /// Active because of a key or lock, not because it is the default layer.
    func isMomentary(_ layer: Int) -> Bool { layer >= 0 && layer < 32 && layerState & (1 << UInt32(layer)) != 0 }

    static func parse(_ b: [UInt8]) -> LiveState? {
        guard b.count >= 26, b[0] == 0xF4, b[2] == 0 else { return nil }
        return LiveState(highestLayer: Int(b[3]), layerState: LiveReport.u32(b, 4),
                         defaultLayerState: LiveReport.u32(b, 8), lockedLayers: LiveReport.u32(b, 12),
                         flags: b[16], trainerState: Int(b[17]), sessionsFinished: LiveReport.u16(b, 18),
                         oneShotMods: b[20], oneShotLockedMods: b[21],
                         oneShotLayer: b[22] == 0xFF ? nil : Int(b[22]),
                         mods: b[23], weakMods: b[24], layerCount: Int(b[25]))
    }
}

// MARK: - 0xF5 trainer statistics

/// Reply to [0xF5, 0]: the last finished session plus the all-time record.
struct TrainerSummary: Equatable {
    /// False when no session was finished since power-up (the session fields are then 0).
    var hasSession: Bool
    var trainerState: Int
    var sessionsFinished: Int
    var wpm: Int
    var accuracy: Int
    var items: Int
    var correct: Int
    var misses: Int
    var missWrongKey: Int
    var missHeld: Int
    var missTapped: Int
    var missWrongLayer: Int
    var activeMs: Int
    var bestWpm: Int
    var bestAccuracy: Int
    var sessionsEver: Int
    var charCount: Int
    var itemCount: Int

    static func parse(_ b: [UInt8]) -> TrainerSummary? {
        guard b.count >= 31, b[0] == 0xF5, b[1] == 0, b[2] <= 1 else { return nil }
        return TrainerSummary(hasSession: b[2] == 0, trainerState: Int(b[3]), sessionsFinished: LiveReport.u16(b, 4),
                              wpm: Int(b[6]), accuracy: Int(b[7]), items: Int(b[8]),
                              correct: LiveReport.u16(b, 9), misses: LiveReport.u16(b, 11),
                              missWrongKey: LiveReport.u16(b, 13), missHeld: LiveReport.u16(b, 15),
                              missTapped: LiveReport.u16(b, 17), missWrongLayer: LiveReport.u16(b, 19),
                              activeMs: Int(LiveReport.u32(b, 21)),
                              bestWpm: Int(b[25]), bestAccuracy: Int(b[26]), sessionsEver: LiveReport.u16(b, 27),
                              charCount: Int(b[29]), itemCount: Int(b[30]))
    }
}

/// Per-character counters, cumulative since power-up (or a difference of two such tables).
struct TrainerCharStat: Codable, Equatable {
    var correct: Int
    var misses: Int
    /// Sum of the latencies of the correct keystrokes.
    var latencyMs: Int

    var attempts: Int { correct + misses }
    var isZero: Bool { correct == 0 && misses == 0 && latencyMs == 0 }
}

/// Reply to [0xF5, 1, index]: up to three characters starting at ASCII 0x20 + index.
struct TrainerCharsPage: Equatable {
    var total: Int
    var index: Int
    var stats: [TrainerCharStat]

    static func parse(_ b: [UInt8]) -> TrainerCharsPage? {
        guard b.count >= 6, b[0] == 0xF5, b[1] == 1, b[2] <= 1 else { return nil }
        let n = b[2] == 0 ? min(Int(b[5]), 3) : 0
        guard b.count >= 6 + n * 8 else { return nil }
        let stats = (0..<n).map { i -> TrainerCharStat in
            let at = 6 + i * 8
            return TrainerCharStat(correct: LiveReport.u16(b, at), misses: LiveReport.u16(b, at + 2),
                                   latencyMs: Int(LiveReport.u32(b, at + 4)))
        }
        return TrainerCharsPage(total: Int(b[3]), index: Int(b[4]), stats: stats)
    }
}

// MARK: - 0xF6 Chordal Hold / Flow Tap

struct TapHoldInfo: Equatable {
    var layer: Int
    /// False when the keyboard has no such layer (the two keycode masks are then empty).
    var layerValid: Bool
    var chordalHoldOn: Bool
    var flowTapOn: Bool
    var flowTapTermMs: Int
    var rows: Int
    var cols: Int
    /// All four sets hold `KeyPlacement.id`s (row * 100 + col).
    var chordalExempt: Set<Int>
    var rightHand: Set<Int>
    var tapHoldKeys: Set<Int>
    var flowTapKeys: Set<Int>

    static func parse(_ b: [UInt8]) -> TapHoldInfo? {
        guard b.count >= 32, b[0] == 0xF6, b[2] <= 1 else { return nil }
        let cols = Int(b[7])
        guard cols > 0 else { return nil }
        return TapHoldInfo(layer: Int(b[1]), layerValid: b[2] == 0,
                           chordalHoldOn: b[3] & 1 != 0, flowTapOn: b[3] & 2 != 0,
                           flowTapTermMs: LiveReport.u16(b, 4), rows: Int(b[6]), cols: cols,
                           chordalExempt: LiveReport.matrixMask(b[8..<14], cols: cols),
                           rightHand: LiveReport.matrixMask(b[14..<20], cols: cols),
                           tapHoldKeys: LiveReport.matrixMask(b[20..<26], cols: cols),
                           flowTapKeys: LiveReport.matrixMask(b[26..<32], cols: cols))
    }

    /// The .vil tap-hold phrases with the Chordal Hold / Flow Tap entries replaced by what the
    /// keyboard applies right now (both are Vial QMK Settings and can differ from the export).
    func correcting(_ parts: [String]) -> [String] {
        let chordal = "Chordal Hold \(chordalHoldOn ? "on" : "off")"
        let flow = flowTapTermMs > 0 ? "Flow Tap \(flowTapTermMs) ms" : "Flow Tap off"
        var out = parts.filter { !$0.hasPrefix("Chordal Hold") && !$0.hasPrefix("Flow Tap") }
        out += [chordal, flow]
        return out
    }
}
