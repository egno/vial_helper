import AppKit
import SwiftUI

/// Menu entries of the live features ("Reset misfire counters", "Trainer History…").
final class LiveMenu: NSObject {
    static let shared = LiveMenu()

    func addItems(to menu: NSMenu) {
        let history = NSMenuItem(title: "Trainer History…", action: #selector(showTrainerHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        let reset = NSMenuItem(title: "Reset Misfire Counters", action: KeyboardLink.shared.isConnected ? #selector(resetMisfires) : nil, keyEquivalent: "")
        reset.target = self
        reset.isEnabled = KeyboardLink.shared.isConnected
        menu.addItem(reset)
    }

    @objc private func showTrainerHistory() { TrainerHistoryWindowController.shared.show() }
    @objc private func resetMisfires() { LiveKeyboard.shared.resetMisfires() }
}

/// Debug command-line helpers of the live features.
///
///     --hid-misfire                 print the misfire table of the connected keyboard (+ raw reports)
///     --hid-live                    ask 0xF4, 0xF5 and 0xF6 once and print what comes back
///     --live-probe SECONDS          run the real polling with the overlay "visible" and count requests
///     --live-selftest               parser and history tests on hand-built reports
///     --render-trainer out.png      render the Trainer History window (--fake-trainer | --trainer-history file.json)
///   with --render:
///     --inject-misfires "hex;hex"   0xF3 replies (as printed by --hid-misfire), one per key
///     --fake-misfires               a made-up misfire table for the home row
///     --inject-state "hex"          a 0xF4 reply
///     --inject-taphold "hex"        a 0xF6 reply (fills the Chordal Hold exemptions and the tap-hold line)
enum LiveDebug {
    private static func value(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func has(_ flag: String) -> Bool { CommandLine.arguments.contains(flag) }

    private static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

    /// Applies the `--inject-*` / `--fake-*` flags before an off-screen render.
    static func applyRenderInjection(model: KeymapModel) {
        let live = LiveKeyboard.shared
        if let text = value("--inject-misfires") {
            live.inject(misfires: text.split(separator: ";").compactMap { MisfireEntry.parse(LiveReport.parseHex(String($0)))?.entry })
        } else if has("--fake-misfires") {
            live.inject(misfires: fakeMisfires)
        }
        if has("--hide-misfires") { live.showMisfires = false } else if has("--inject-misfires") || has("--fake-misfires") { live.showMisfires = true }
        if let text = value("--inject-state") {
            live.inject(state: LiveState.parse(LiveReport.parseHex(text)))
        }
        if let text = value("--inject-taphold"), let info = TapHoldInfo.parse(LiveReport.parseHex(text)) {
            live.start(model: model, settings: .shared)
            live.apply(tapHold: info)
        }
    }

    static let fakeMisfires: [MisfireEntry] = [
        MisfireEntry(index: 0, row: 1, col: 1, keycode: 0x2804, heldMisfires: 1, tappedMisfires: 4, holds: 310, taps: 2900),
        MisfireEntry(index: 1, row: 1, col: 2, keycode: 0x2416, heldMisfires: 2, tappedMisfires: 31, holds: 150, taps: 2100),
        MisfireEntry(index: 2, row: 1, col: 3, keycode: 0x2107, heldMisfires: 0, tappedMisfires: 9, holds: 420, taps: 1300),
        MisfireEntry(index: 3, row: 1, col: 4, keycode: 0x2209, heldMisfires: 14, tappedMisfires: 12, holds: 610, taps: 800),
        MisfireEntry(index: 4, row: 5, col: 4, keycode: 0x220D, heldMisfires: 6, tappedMisfires: 3, holds: 580, taps: 700),
        MisfireEntry(index: 5, row: 5, col: 3, keycode: 0x210E, heldMisfires: 0, tappedMisfires: 0, holds: 390, taps: 1500),
        MisfireEntry(index: 6, row: 5, col: 2, keycode: 0x240F, heldMisfires: 1, tappedMisfires: 17, holds: 90, taps: 1700),
        MisfireEntry(index: 7, row: 5, col: 1, keycode: 0x2833, heldMisfires: 0, tappedMisfires: 2, holds: 40, taps: 600),
    ]

    /// Handles the flags that run instead of the app. Returns true when one was found.
    static func handleCommandLine() -> Bool {
        if has("--live-selftest") {
            let ok = LiveSelfTest.run { name, cond in print("\(cond ? "PASS" : "FAIL") \(name)") }
            exit(ok ? 0 : 1)
        }
        if let out = value("--render-trainer") {
            renderTrainer(to: out)
        }
        let wantsMisfire = has("--hid-misfire"), wantsLive = has("--hid-live")
        let probe = value("--live-probe").flatMap(Double.init)
        guard wantsMisfire || wantsLive || probe != nil else { return false }
        let link = KeyboardLink.shared
        link.start()
        link.whenConnected(timeout: 2) { connected in
            guard connected else { print("not connected"); exit(1) }
            print("connected: \(link.productName ?? "?")")
            if wantsMisfire { printMisfires(link) } else if wantsLive { printLive(link) } else if let probe { runProbe(seconds: probe) }
        }
        return true
    }

    private static func printMisfires(_ link: KeyboardLink) {
        var raw: [String] = []
        func step(_ index: Int) {
            link.transport.request([KeyboardLink.LiveCommand.misfire, 0, UInt8(index)], matchPrefix: 2) { reply in
                guard let b = reply.bytes, let r = MisfireEntry.parse(b) else { print("0xF3: \(reply.summary)"); exit(1) }
                if index == 0 {
                    print("\(r.count) tracked keys")
                    print("idx row col keycode  held-misfires tapped-misfires     holds      taps")
                }
                if let e = r.entry {
                    raw.append(hex(Array(b[..<21])))
                    print(String(format: "%3d %3d %3d  0x%04X  %13d %15d %9d %9d", e.index, e.row, e.col, e.keycode,
                                 e.heldMisfires, e.tappedMisfires, e.holds, e.taps))
                }
                if r.entry != nil, index + 1 < r.count { step(index + 1) } else {
                    print("--inject-misfires \"\(raw.joined(separator: ";"))\"")
                    exit(0)
                }
            }
        }
        step(0)
    }

    private static func printLive(_ link: KeyboardLink) {
        func describe<T>(_ name: String, _ r: LiveResult<T>) {
            switch r {
            case .ok(let v): print("\(name): \(v)")
            case .unsupported: print("\(name): unsupported by this firmware (unhandled)")
            case .failed: print("\(name): failed (timeout or unparsable)")
            }
        }
        link.fetchState { s in
            describe("0xF4 state", s)
            link.fetchTrainerSummary { t in
                describe("0xF5 trainer summary", t)
                link.fetchTapHold(layer: 0) { h in
                    describe("0xF6 tap-hold", h)
                    exit(0)
                }
            }
        }
    }

    /// Runs the real LiveKeyboard for a while as if the overlay were open and reports how many
    /// requests each command took: on firmware without 0xF4-0xF6 the counts must stay tiny.
    private static func runProbe(seconds: Double) {
        let model = KeymapModel()
        let live = LiveKeyboard.shared
        live.history = TrainerHistory(url: nil) // never touch the real history from a probe
        live.start(model: model, settings: .shared)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { live.setOverlayVisible(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let counts = live.requestCounts.sorted { $0.key < $1.key }
                .map { String(format: "0x%02X: %d", $0.key, $0.value) }.joined(separator: ", ")
            print("requests in \(seconds) s: \(counts)")
            print("state: \(live.state.map { "\($0)" } ?? "none")")
            print("tap-hold: \(live.tapHold.map { "\($0)" } ?? "none"), chordalExempt \(model.chordalExempt.sorted())")
            print("misfire keys: \(live.misfires.count), trainer sessions recorded: \(live.history.records.count)")
            exit(0)
        }
    }

    private static func renderTrainer(to out: String) -> Never {
        let history: TrainerHistory
        if has("--fake-trainer") {
            history = .fake()
        } else if let path = value("--trainer-history") {
            history = TrainerHistory(url: URL(fileURLWithPath: path))
        } else {
            history = .shared
        }
        let view = TrainerHistoryView(history: history)
        let rendered: NSImage? = MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            return renderer.nsImage
        }
        guard let image = rendered, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: out))) != nil else {
            fputs("render failed\n", stderr)
            exit(1)
        }
        print("wrote \(out) (\(Int(image.size.width))x\(Int(image.size.height)))")
        exit(0)
    }
}

/// Tests of the report parsers and the history bookkeeping, on hand-built reports.
enum LiveSelfTest {
    @discardableResult
    static func run(_ report: (String, Bool) -> Void) -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { report(name, cond); ok = ok && cond }
        func bytes(_ hex: String) -> [UInt8] { LiveReport.parseHex(hex) }

        // Matrix masks: the stock chordal_hold_layout ('*' at 1,0 and on the six thumb keys).
        let exempt = LiveReport.matrixMask(bytes("40 00 E0 00 00 E0")[..<6])
        check("mask 40 00 E0 00 00 E0 -> 1,0 + thumbs", exempt == [100, 303, 304, 305, 703, 704, 705])
        check("mask bit 0 -> 0,0; bit 47 -> 7,5", LiveReport.matrixMask([0x01, 0, 0, 0, 0, 0x80][...]) == [0, 705])
        check("hex parser pads to a report", bytes("f4").count == 32 && bytes("f400ff")[2] == 0xFF)

        // 0xF3: index 2 of 9, key 1,3, keycode 0x2209, held 3, tapped 300, holds 70000, taps 5.
        let mf = MisfireEntry.parse(bytes("F3 00 00 09 02 01 03 09 22 03 00 2C 01 70 11 01 00 05 00 00 00"))
        check("0xF3 entry", mf?.count == 9 && mf?.entry == MisfireEntry(index: 2, row: 1, col: 3, keycode: 0x2209,
              heldMisfires: 3, tappedMisfires: 300, holds: 70000, taps: 5))
        let mfEnd = MisfireEntry.parse(bytes("F3 00 01 09 09"))
        check("0xF3 index out of range keeps the count", mfEnd?.count == 9 && mfEnd?.entry == nil)
        check("0xF3 wrong command rejected", MisfireEntry.parse(bytes("F4 00 00 09")) == nil)
        let badges = MisfireBadge.badges(for: [
            MisfireEntry(index: 0, row: 1, col: 1, keycode: 0, heldMisfires: 0, tappedMisfires: 0, holds: 100, taps: 100),
            MisfireEntry(index: 1, row: 1, col: 2, keycode: 0, heldMisfires: 10, tappedMisfires: 0, holds: 100, taps: 100),
            MisfireEntry(index: 2, row: 1, col: 3, keycode: 0, heldMisfires: 5, tappedMisfires: 40, holds: 100, taps: 100),
        ])
        check("misfire heat is relative to the worst key", badges[101]?.heat == 0 && badges[102]?.heat == 1
              && badges[103]?.heat == 1 && badges[103]?.held == 5)
        check("misfire heat of an empty table", MisfireBadge.badges(for: []).isEmpty)

        // 0xF4: highest 3, layer_state 0b1100, default 1, locked 0b0100, trainer + caps word,
        // trainer state 1, 258 sessions, OSM shift pending, ctrl locked, OSL 5, mods gui, weak shift, 6 layers.
        let st = LiveState.parse(bytes("F4 00 00 03 0C 00 00 00 01 00 00 00 04 00 00 00 03 01 02 01 02 01 05 08 02 06"))
        check("0xF4 layers", st?.highestLayer == 3 && st?.layerState == 0b1100 && st?.defaultLayerState == 1
              && st?.lockedLayers == 0b0100 && st?.layerCount == 6)
        check("0xF4 active / locked", st?.isActive(0) == true && st?.isActive(1) == false && st?.isActive(3) == true
              && st?.isLocked(2) == true && st?.isLocked(3) == false && st?.isMomentary(0) == false)
        check("0xF4 flags", st?.trainerActive == true && st?.capsWord == true && st?.capsLock == false
              && st?.oneShotLayerPending == false && st?.trainerState == 1)
        check("0xF4 sessions u16", st?.sessionsFinished == 258)
        check("0xF4 one-shot", st?.oneShotMods == 2 && st?.oneShotLockedMods == 1 && st?.oneShotLayer == 5
              && st?.mods == 8 && st?.weakMods == 2)
        check("0xF4 no one-shot layer", LiveState.parse(bytes("F4 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 FF"))?.oneShotLayer == nil)
        check("0xF4 unhandled report rejected", LiveState.parse(bytes("FF 00")) == nil)
        check("mod symbols", LiveReport.modSymbols(0x02) == "⇧" && LiveReport.modSymbols(0x81) == "⌃⌘" && LiveReport.modSymbols(0x24) == "⌥⇧")

        // 0xF5 summary: state 2, 7 sessions, 43 WPM, 96 %, 20 items, 300 correct, 12 misses
        // (5 wrong key, 4 held, 2 tapped, 1 wrong layer), 83 000 ms, best 51 / 99, 1234 ever, 95 chars, 40 items.
        let sm = TrainerSummary.parse(bytes("F5 00 00 02 07 00 2B 60 14 2C 01 0C 00 05 00 04 00 02 00 01 00 38 44 01 00 33 63 D2 04 5F 28"))
        check("0xF5 summary session", sm?.hasSession == true && sm?.trainerState == 2 && sm?.sessionsFinished == 7
              && sm?.wpm == 43 && sm?.accuracy == 96 && sm?.items == 20 && sm?.correct == 300 && sm?.misses == 12)
        check("0xF5 summary misses", sm?.missWrongKey == 5 && sm?.missHeld == 4 && sm?.missTapped == 2 && sm?.missWrongLayer == 1
              && sm?.activeMs == 83000)
        check("0xF5 summary all-time", sm?.bestWpm == 51 && sm?.bestAccuracy == 99 && sm?.sessionsEver == 1234
              && sm?.charCount == 95 && sm?.itemCount == 40)
        check("0xF5 summary without a session", TrainerSummary.parse(bytes("F5 00 01 00 00 00"))?.hasSession == false)
        // 0xF5 chars: total 95, index 3, 2 records: (10, 1, 2500 ms), (65535, 0, 70000 ms).
        let cp = TrainerCharsPage.parse(bytes("F5 01 00 5F 03 02 0A 00 01 00 C4 09 00 00 FF FF 00 00 70 11 01 00"))
        check("0xF5 chars page", cp?.total == 95 && cp?.index == 3 && cp?.stats == [
            TrainerCharStat(correct: 10, misses: 1, latencyMs: 2500), TrainerCharStat(correct: 65535, misses: 0, latencyMs: 70000)])
        check("0xF5 chars past the end", TrainerCharsPage.parse(bytes("F5 01 01 5F 5F 00"))?.stats.isEmpty == true)

        // 0xF6: layer 0, chordal + flow, 150 ms, 8x6, the stock exempt mask, right hand = rows 4-7,
        // tap-hold = 1,1-1,4 and 5,1-5,4 and thumbs 3,4 / 7,4, flow tap = 1,1-1,4.
        let th = TapHoldInfo.parse(bytes("F6 00 00 03 96 00 08 06  40 00 E0 00 00 E0  00 00 00 FF FF FF  80 07 40 80 07 40  80 07 00 00 00 00"))
        check("0xF6 flags and term", th?.chordalHoldOn == true && th?.flowTapOn == true && th?.flowTapTermMs == 150
              && th?.rows == 8 && th?.cols == 6 && th?.layerValid == true)
        check("0xF6 exempt mask", th?.chordalExempt == [100, 303, 304, 305, 703, 704, 705])
        check("0xF6 right-hand mask", th?.rightHand.count == 24 && th?.rightHand.contains(400) == true && th?.rightHand.contains(305) == false)
        check("0xF6 tap-hold mask", th?.tapHoldKeys == [101, 102, 103, 104, 304, 501, 502, 503, 504, 704])
        check("0xF6 flow tap mask", th?.flowTapKeys == [101, 102, 103, 104])
        check("0xF6 corrects the tap-hold line", th?.correcting(["Tapping 200 ms", "Chordal Hold off", "Flow Tap off"])
              == ["Tapping 200 ms", "Chordal Hold on", "Flow Tap 150 ms"])
        check("0xF6 no such layer keeps the layer-independent masks",
              TapHoldInfo.parse(bytes("F6 09 01 00 00 00 08 06 40 00 E0 00 00 E0"))?.chordalExempt.count == 7)

        // History: per-character differences within one power cycle, and de-duplication.
        let h = TrainerHistory(url: nil)
        var s1 = sm!
        s1.sessionsFinished = 1; s1.sessionsEver = 50
        var table = [TrainerCharStat](repeating: TrainerCharStat(correct: 0, misses: 0, latencyMs: 0), count: 95)
        table[0x41 - 0x20 + 0x20] = TrainerCharStat(correct: 10, misses: 2, latencyMs: 3000) // "a"
        let r1 = h.add(summary: s1, cumulativeChars: table, foundOnConnect: true, firmware: nil)
        check("history: first record takes the whole table", r1?.chars == ["a": TrainerCharStat(correct: 10, misses: 2, latencyMs: 3000)])
        check("history: same session again is skipped", h.add(summary: s1, cumulativeChars: table, foundOnConnect: true, firmware: nil) == nil && h.records.count == 1)
        var s2 = s1
        s2.sessionsFinished = 3; s2.sessionsEver = 52; s2.wpm = 44
        table[0x41] = TrainerCharStat(correct: 25, misses: 3, latencyMs: 7000)
        table[0x42] = TrainerCharStat(correct: 4, misses: 0, latencyMs: 900) // "b"
        let r2 = h.add(summary: s2, cumulativeChars: table, foundOnConnect: false, firmware: nil)
        check("history: later record stores the difference", r2?.chars == [
            "a": TrainerCharStat(correct: 15, misses: 1, latencyMs: 4000), "b": TrainerCharStat(correct: 4, misses: 0, latencyMs: 900)]
            && r2?.charSessions == 2)
        var s3 = s1
        s3.sessionsFinished = 1; s3.sessionsEver = 53
        table = [TrainerCharStat](repeating: TrainerCharStat(correct: 0, misses: 0, latencyMs: 0), count: 95)
        table[0x41] = TrainerCharStat(correct: 3, misses: 0, latencyMs: 500)
        let r3 = h.add(summary: s3, cumulativeChars: table, foundOnConnect: false, firmware: nil)
        check("history: new power cycle starts over", r3?.chars == ["a": TrainerCharStat(correct: 3, misses: 0, latencyMs: 500)] && r3?.charSessions == 1)
        check("history: totals", h.charTotals.first { $0.char == "a" }?.stat == TrainerCharStat(correct: 28, misses: 3, latencyMs: 7500))
        if let data = try? JSONEncoder().encode(h.records), let back = try? JSONDecoder().decode([TrainerSessionRecord].self, from: data) {
            check("history: JSON round trip", back == h.records)
        } else {
            check("history: JSON round trip", false)
        }
        return ok
    }
}
