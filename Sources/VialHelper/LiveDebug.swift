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
///     --hid-live                    ask 0xF4, 0xF5, 0xF6 and 0xF7 (state, pressed keys) once and print what comes back
///     --live-probe SECONDS          run the real LiveKeyboard with the overlay "visible": says whether the
///                                   state is pushed (0xF7) or polled, counts requests and events
///     --live-selftest               parser and history tests on hand-built reports, then the event routing
///                                   and the push logic against a keyboard played by a closure
///     --render-trainer out.png      render the Trainer History window (--fake-trainer | --trainer-history file.json)
///   with --render:
///     --inject-misfires "hex;hex"   0xF3 replies (as printed by --hid-misfire), one per key
///     --fake-misfires               a made-up misfire table for the home row
///     --inject-state "hex"          a 0xF4 reply
///     --ghost-opacity 0.3           with --ghost: plate opacity for this render (the setting is left alone)
///     --inject-taphold "hex"        a 0xF6 reply (fills the Chordal Hold exemptions and the tap-hold line)
///     --inject-matrix "hex"         a 0xF7 matrix event: with --ghost those keys are drawn as pressed
///                                   (whatever the "Highlight pressed keys" setting says)
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
        if let text = value("--ghost-opacity"), let v = Double(text) { GhostView.plateOpacityOverride = v }
        if let text = value("--inject-matrix") {
            guard let event = MatrixEvent.parse(LiveReport.parseHex(text)) else { fputs("--inject-matrix: not a 0xF7 matrix event\n", stderr); exit(1) }
            live.inject(matrix: event)
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
            var ok = LiveSelfTest.run { name, cond in print("\(cond ? "PASS" : "FAIL") \(name)") }
            PushSelfTest.run({ name, cond in print("\(cond ? "PASS" : "FAIL") \(name)"); ok = ok && cond }) { exit(ok ? 0 : 1) }
            return true
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
                    // Sub 1 and 2 need no subscription and start none.
                    link.fetchEvent(kind: 1) { s in
                        describe("0xF7 state (what a subscriber is pushed)", s)
                        link.fetchEvent(kind: 2) { m in
                            describe("0xF7 pressed keys (row * 100 + col)", m)
                            exit(0)
                        }
                    }
                }
            }
        }
    }

    /// Runs the real LiveKeyboard for a while as if the overlay were open and reports how many
    /// requests each command took: on firmware without 0xF4-0xF7 the counts must stay tiny, and
    /// with 0xF7 in use 0xF4 is asked once per 5 s and 0xF7 once per renewal.
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
            print("push (0xF7): \(live.pushStatus)")
            print("events received: state \(live.eventCounts[1] ?? 0), matrix \(live.eventCounts[2] ?? 0) (matrix events are \(live.usesMatrix ? "used" : "ignored"))")
            print("state: \(live.state.map { "\($0)" } ?? "none")")
            print("tap-hold: \(live.tapHold.map { "\($0)" } ?? "none"), chordalExempt \(model.chordalExempt.sorted())")
            print("misfire keys: \(live.misfires.count), trainer sessions recorded: \(live.history.records.count)")
            live.shutdown() // ends the subscription, if there is one
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

        // 0xF7: the state event carries bytes 2-25 of the 0xF4 reply above.
        let stEvent = "F7 01 00 03 0C 00 00 00 01 00 00 00 04 00 00 00 03 01 02 01 02 01 05 08 02 06"
        check("0xF7 state event = the 0xF4 reply", st != nil && LiveEvent.parse(bytes(stEvent)) == st.map(LiveEvent.state))
        // Matrix event, 8x6: 0,0 (bit 0), 1,3 (bit 9), 7,4 (bit 46).
        let mx = MatrixEvent.parse(bytes("F7 02 00 08 06 01 02 00 00 00 40"))
        check("0xF7 matrix event", mx == MatrixEvent(rows: 8, cols: 6, pressed: [0, 103, 704]))
        check("0xF7 matrix event: nothing down", MatrixEvent.parse(bytes("F7 02 00 08 06"))?.pressed.isEmpty == true)
        check("0xF7 matrix event: bits past the matrix dropped", MatrixEvent.parse(bytes("F7 02 00 04 06 01 00 00 01 00 00"))?.pressed == [0])
        check("0xF7 malformed events rejected", MatrixEvent.parse(bytes("F7 02 01 08 06 01")) == nil && MatrixEvent.parse(bytes("F7 02 00 09 06")) == nil
              && LiveEvent.parse(bytes("F7 03 00")) == nil && LiveEvent.parse(bytes("F7 01 01 03")) == nil && LiveEvent.parse(bytes("FF 01 00")) == nil)
        check("0xF7 subscribe reply", LiveEvent.parseSubscribed(bytes("F7 00 00 05")) == 5 && LiveEvent.parseSubscribed(bytes("F7 00 00 00")) == 0
              && LiveEvent.parseSubscribed(bytes("FF 00 05")) == nil && LiveEvent.parseSubscribed(bytes(stEvent)) == nil)

        // Transport: events are taken out before reply matching, whatever is in flight.
        let stateEv = bytes(stEvent), matrixEv = bytes("F7 02 00 08 06 01 02 00 00 00 40")
        func route(_ report: [UInt8], sent: String?, prefix: Int = 1, accept: (([UInt8]) -> Bool)? = nil) -> HIDTransport.Disposition {
            HIDTransport.classify(report, sent: sent.map(bytes), matchPrefix: prefix, accept: accept)
        }
        check("event shape", HIDTransport.eventKind(stateEv) == 1 && HIDTransport.eventKind(matrixEv) == 2
              && HIDTransport.eventKind(bytes("F7 00 00 05")) == nil && HIDTransport.eventKind(bytes("F4 00 00 03")) == nil)
        check("event with nothing in flight", route(stateEv, sent: nil) == .event && route(matrixEv, sent: nil) == .event)
        check("event never answers a Vial request that accepts anything (definition page)",
              route(stateEv, sent: "FE 02 03 00", accept: { _ in true }) == .event && route(matrixEv, sent: "FE 02 03 00", accept: { _ in true }) == .event)
        check("event never answers a prefix-matched request",
              route(stateEv, sent: "F4 00", prefix: 2) == .event && route(matrixEv, sent: "12 00 00 1C", prefix: 4) == .event)
        check("event is not the reply to a subscribe request", route(stateEv, sent: "F7 00 05", prefix: 2) == .event
              && route(bytes("F7 00 00 05"), sent: "F7 00 05", prefix: 2) == .reply(.reply(bytes("F7 00 00 05"))))
        check("the report asked for with [0xF7, 1] / [0xF7, 2] is that reply", route(stateEv, sent: "F7 01", prefix: 2) == .reply(.reply(stateEv))
              && route(matrixEv, sent: "F7 02", prefix: 2) == .reply(.reply(matrixEv)) && route(matrixEv, sent: "F7 01", prefix: 2) == .event)
        // Replies without a prefix of their own that merely begin like an event stay replies:
        // a definition of 503 / 759 bytes, a page of compressed data.
        let size503 = bytes("F7 01 00 00"), size759 = bytes("F7 02 00 00")
        var page = [UInt8](repeating: 0xA5, count: 32)
        page[0] = 0xF7; page[1] = 0x01; page[2] = 0
        check("definition size f7 01 00 00 / f7 02 00 00 is a reply, not an event",
              route(size503, sent: "FE 01", accept: { _ in true }) == .reply(.reply(size503))
              && route(size759, sent: "FE 01", accept: { _ in true }) == .reply(.reply(size759)))
        check("compressed page starting f7 01 00 is a reply", route(page, sent: "FE 02 00 00", accept: { _ in true }) == .reply(.reply(page)))
        check("old firmware: subscribe comes back unhandled", route(bytes("FF 00 05"), sent: "F7 00 05", prefix: 2) == .reply(.unhandled(bytes("FF 00 05"))))
        check("someone else's reply is still ignored", route(bytes("F5 00 00"), sent: "F4 00", prefix: 2) == .ignore)

        // Pressed keys: a key shorter than `minLit` stays lit (the view fades it after).
        let keys = PressedKeys()
        keys.set([0, 704])
        keys.set([704])
        check("pressed keys: a quick tap stays lit", keys.down == [704] && keys.lit == [0, 704])
        keys.clear()
        check("pressed keys: cleared", keys.down.isEmpty && keys.lit.isEmpty)

        // Vial GUI detection.
        check("Vial GUI recognised", VialGUIWatcher.isVialGUI(bundleID: "today.vial", name: "Vial")
              && VialGUIWatcher.isVialGUI(bundleID: nil, name: "Vial") && VialGUIWatcher.isVialGUI(bundleID: "com.example.vial-gui", name: "x"))
        check("not the Vial GUI: this app, unrelated names", !VialGUIWatcher.isVialGUI(bundleID: "dev.av.vialhelper", name: "Vial Helper")
              && !VialGUIWatcher.isVialGUI(bundleID: nil, name: "VialHelper") && !VialGUIWatcher.isVialGUI(bundleID: "com.apple.Safari", name: "Safari")
              && !VialGUIWatcher.isVialGUI(bundleID: "com.example.trivial", name: "Trivial") && !VialGUIWatcher.isVialGUI(bundleID: nil, name: nil))

        // Ghost mode: state chips, shifted legends, the reduced label set.
        if let st {
            check("ghost chips: held mods and locked layers first, Caps Word's weak Shift left out",
                  LiveIndicators.items(st, context: LabelContext(layerNames: ["Base", "", "Num"]), detailed: true)
                    == ["⌘", "Num locked", "Trainer", "Caps Word", "one-shot ⌃ locked", "one-shot ⇧", "one-shot L5"])
            check("overlay chips unchanged", LiveIndicators.items(st, context: LabelContext())
                    == ["Trainer", "Caps Word", "one-shot ⌃ locked", "one-shot ⇧", "one-shot L5"])
            check("one-shot Shift shifts every key", ShiftLegends.current(st) == .all)
            var word = st
            word.oneShotMods = 0
            check("Caps Word alone: its weak Shift does not count", ShiftLegends.current(word) == .capsWord)
            word.flags = 0
            check("weak Shift without Caps Word counts", ShiftLegends.current(word) == .all)
            word.weakMods = 0
            check("no Shift, no shifted legends", ShiftLegends.current(word) == .off && ShiftLegends.current(nil) == .off)
        }
        var shiftCtx = LabelContext()
        shiftCtx.shift = .all
        check("shifted legends from the US table without a layout",
              Keycode.label("KC_1", context: shiftCtx).primary == "!" && Keycode.label("LSFT_T(KC_SLSH)", context: shiftCtx).primary == "?"
              && Keycode.label("KC_A", context: shiftCtx).primary == "A" && Keycode.label("KC_ENT", context: shiftCtx).primary == "⏎")
        check("modifier wrappers are not shifted twice",
              Keycode.label("LSFT(KC_1)", context: shiftCtx).primary == "!" && Keycode.label("LCTL(KC_1)", context: shiftCtx).primary == "⌃1")
        shiftCtx.keyOverrides = ["KC_1": "&", "KC_2": "É"]
        shiftCtx.shiftedKeyOverrides = ["KC_1": "1"]
        check("shifted legends follow the active layout, unknown ones stay",
              Keycode.label("KC_1", context: shiftCtx).primary == "1" && Keycode.label("KC_2", context: shiftCtx).primary == "É"
              && Keycode.label("KC_3", context: shiftCtx).primary == "3")
        var wordCtx = LabelContext()
        wordCtx.shift = .capsWord
        check("Caps Word shifts '-' but not digits",
              Keycode.label("KC_MINS", context: wordCtx).primary == "_" && Keycode.label("KC_1", context: wordCtx).primary == "1")
        var full = Keycode.label("LT2(KC_SPC)", context: LabelContext(layerNames: ["", "", "Num"]))
        full.alone = "⌫"
        full.chordalExempt = true
        check("simplified label keeps tap + hold of a tap-hold key",
              full.simplified == KeyLabel(primary: "␣", secondary: "Num", secondaryKind: .layer)
              && Keycode.label("LGUI_T(KC_A)").simplified.secondary == "⌘")
        check("simplified label drops the notes under other keys",
              Keycode.label("MO(2)").simplified.secondary == nil && Keycode.label("OSM(MOD_LSFT)").simplified.secondary == nil
              && Keycode.label("M3").simplified == KeyLabel(primary: "M3", style: .special))

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

/// Waiting in self-tests without betting on a fixed delay.
enum Poll {
    /// Calls `then` on the main thread as soon as `condition` holds (true), or once `deadline`
    /// seconds have passed without it (false).
    static func until(_ condition: @escaping () -> Bool, deadline: TimeInterval = 3, then: @escaping (Bool) -> Void) {
        let end = Date().addingTimeInterval(deadline)
        func step() {
            if condition() { return then(true) }
            if Date() >= end { return then(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { step() }
        }
        step()
    }

    static func wait(_ seconds: TimeInterval, then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { then() }
    }
}

/// Tests that need the run loop: the real `HIDTransport` (loopback) and the real `LiveKeyboard`
/// against `FakeKeyboard`, which plays the firmware's 0xF4 / 0xF7 and a few Vial-shaped commands.
/// Every wait is a condition with a deadline; counts are checked as bounds that a slow machine
/// cannot break.
enum PushSelfTest {
    /// Called on the transport's queue (requests) and on the main thread (the test), hence the lock.
    final class FakeKeyboard {
        private let lock = NSLock()
        private var _events = true, _mute = false, _ttl = 0
        private var _state = [UInt8](repeating: 0, count: 24), _matrix = [UInt8](repeating: 0, count: 6)
        private var _requests: [[UInt8]] = []

        init() { setLayer(0) }

        private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

        /// False: firmware without 0xF7.
        var events: Bool { get { locked { _events } } set { locked { _events = newValue } } }
        /// True: subscribe requests get no answer (and do not renew).
        var mute: Bool { get { locked { _mute } } set { locked { _mute = newValue } } }
        /// ttl of the last subscribe request; 0 = not subscribed.
        var subscribedTTL: Int { locked { _ttl } }
        func requests(_ command: UInt8) -> Int { locked { _requests.filter { $0[0] == command }.count } }

        /// Bytes 2-25 of the 0xF4 reply: `layer` on top of the base layer, 4 layers, no one-shot layer.
        func setLayer(_ layer: UInt8) {
            locked {
                _state = [UInt8](repeating: 0, count: 24)
                _state[1] = layer; _state[2] = layer == 0 ? 0 : 1 << layer; _state[6] = 1; _state[20] = 0xFF; _state[23] = 4
            }
        }

        func setPressed(_ positions: [Int]) {
            locked {
                _matrix = [UInt8](repeating: 0, count: 6)
                for p in positions { _matrix[p / 8] |= 1 << UInt8(p % 8) }
            }
        }

        private func report(_ head: [UInt8]) -> [UInt8] { head + [UInt8](repeating: 0, count: 32 - head.count) }
        var stateEvent: [UInt8] { locked { report([0xF7, 1] + _state) } }
        var matrixEvent: [UInt8] { locked { report([0xF7, 2, 0, 8, 6] + _matrix) } }
        /// What the keyboard would send unasked right now: nothing unless subscribed.
        var pushed: [[UInt8]] { subscribedTTL > 0 ? [stateEvent, matrixEvent] : [] }

        static let definitionPage = [UInt8](repeating: 0x5A, count: 32)

        func respond(_ r: [UInt8]) -> [[UInt8]] {
            locked { _requests.append(r) }
            let unhandled = [[0xFF] + r[1...]]
            switch (r[0], r[1]) {
            case (0xF4, _):
                return [locked { report([0xF4, r[1]] + _state) }]
            case (0xF7, 0):
                guard events else { return unhandled }
                if mute { return [] }
                locked { _ttl = Int(r[2]) }
                return [report([0xF7, 0, 0, r[2]])] + pushed
            case (0xF7, 1): return events ? [stateEvent] : unhandled
            case (0xF7, 2): return events ? [matrixEvent] : unhandled
            default:
                // The Vial side, enough for a whole `VialReader` read. Events of a running
                // subscription arrive in front of every reply.
                return vial(r).map { pushed + [$0] } ?? unhandled
            }
        }

        private func vial(_ r: [UInt8]) -> [UInt8]? {
            switch (r[0], r[1]) {
            case (0xFE, 0x05): return report([UInt8](repeating: 0, count: 30) + [0xFF, 0xFF])  // unlocked
            case (0xFE, 0x00): return report([6, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8])             // Vial protocol 6, uid
            case (0x01, _): return report([0x01, 0, 9])
            case (0x11, _): return report([0x11, 4])                                           // layers
            case (0x0C, _): return report([0x0C, 16])                                          // macros
            case (0x02, 0x02): return report([0x02, 0x02])
            // 503 bytes of definition: a size that starts like a state event (f7 01 00 00).
            // The pages are not xz, so the read carries on with its fallback shape.
            case (0xFE, 0x01): return report([0xF7, 0x01])
            case (0xFE, 0x02): return Self.definitionPage
            case (0x12, _): return Array(r[..<4]) + (0..<28).map { UInt8((Int(r[2]) + $0) & 0x3F) }
            case (0xFE, 0x0D): return r[2] == 0 ? report([]) : nil                             // no dynamic entries
            case (0xFE, 0x09): return [UInt8](repeating: 0xFF, count: 32)                      // no settings
            default: return nil
            }
        }
    }

    static func run(_ check: @escaping (String, Bool) -> Void, done: @escaping () -> Void) {
        transport(check) { push(check) { oldFirmware(check, done: done) } }
    }

    /// The real `VialReader` reads the keymap twice, without and through a running subscription
    /// that puts two events in front of every reply: the same snapshot both times, and every
    /// event at the handler.
    private static func transport(_ check: @escaping (String, Bool) -> Void, done: @escaping () -> Void) {
        let quiet = FakeKeyboard(), kb = FakeKeyboard()
        kb.setLayer(2)
        kb.setPressed([0, 46])
        let plain = HIDTransport(loopback: quiet.respond), hid = HIDTransport(loopback: kb.respond)
        var events: [[UInt8]] = []
        hid.onEvent = { events.append($0) }
        let reference = VialReader(transport: plain), reader = VialReader(transport: hid)
        reference.read { expected in
            check("loopback: Vial read without a subscription", (try? expected.get()) != nil && reference.requestCount > 20)
            hid.request([0xF7, 0, 5], matchPrefix: 2) { subscribed in
                reader.read { result in
                    check("loopback: Vial read through a running subscription gives the same keymap",
                          subscribed.bytes?.prefix(4) == [0xF7, 0, 0, 5] && (try? result.get()) != nil && (try? result.get()) == (try? expected.get())
                          && reader.requestCount == reference.requestCount)
                    // Two after the subscribe reply, two in front of each reply of the read.
                    check("loopback: every event is routed to the handler, in order (\(events.count) events)",
                          events.count == 2 + 2 * reader.requestCount
                          && events.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 0 ? kb.stateEvent : kb.matrixEvent) })
                    events = []
                    hid.request([0xF7, 2], matchPrefix: 2) { asked in
                        hid.injectReport(kb.matrixEvent)
                        Poll.until({ events.count == 1 }) { alone in
                            check("loopback: [0xF7, 2] is answered, an event with nothing in flight is routed",
                                  asked == .reply(kb.matrixEvent) && alone && events == [kb.matrixEvent])
                            done()
                        }
                    }
                }
            }
        }
    }

    /// LiveKeyboard on firmware with 0xF7.
    private static func push(_ check: @escaping (String, Bool) -> Void, done: @escaping () -> Void) {
        let kb = FakeKeyboard()
        kb.setLayer(1)
        kb.setPressed([0])
        let hid = HIDTransport(loopback: kb.respond)
        let vial = VialGUIWatcher(observing: false)
        let live = LiveKeyboard(link: KeyboardLink(transport: hid), vialGUI: vial)
        let model = KeymapModel()
        let f4 = KeyboardLink.LiveCommand.state, f7 = KeyboardLink.LiveCommand.events
        live.history = TrainerHistory(url: nil)
        live.matrixOverride = true
        live.pushTTL = 1 // renewals every 0.33 s, a lapse within about 1.5 s
        live.start(model: model, settings: .shared)
        hid.start()
        live.setGhostVisible(true)
        /// Polls sent while `seconds` pass (12 Hz polling would send about 12 per second).
        func polls(during seconds: TimeInterval, then: @escaping (Int) -> Void) {
            let before = kb.requests(f4)
            Poll.wait(seconds) { then(kb.requests(f4) - before) }
        }
        Poll.until({ live.pushActive && live.state != nil && !live.pressed.down.isEmpty }) { ok in
            check("push: subscribes when the ghost needs the state", ok && kb.subscribedTTL == 1)
            check("push: the events that follow the subscribe fill state and pressed keys", live.state?.highestLayer == 1 && live.pressed.down == [0])
            kb.setLayer(3)
            kb.setPressed([9, 46])
            kb.pushed.forEach(hid.injectReport)
            Poll.until({ live.state?.highestLayer == 3 && live.pressed.down == [103, 704] }) { ok in
                check("push: state and matrix events are consumed", ok && live.state?.isActive(3) == true && live.pressed.lit.isSuperset(of: [103, 704]))
                let renewals = kb.requests(f7)
                polls(during: 0.8) { n in
                    check("push: the fast polling stops (\(n) polls in 0.8 s)", n <= 1)
                    check("push: the subscription is renewed", kb.requests(f7) > renewals && live.pushActive)
                    // The setting off: matrix events still arrive and are not looked at.
                    live.matrixOverride = false
                    let seen = live.eventCounts[2] ?? 0
                    kb.setPressed([5])
                    kb.pushed.forEach(hid.injectReport)
                    Poll.until({ (live.eventCounts[2] ?? 0) > seen }) { ok in
                        check("push: matrix events are ignored with the highlight off", ok && live.pressed.down.isEmpty && live.pressed.lit.isEmpty)
                        live.matrixOverride = true
                        vialGUI()
                    }
                }
            }
        }
        func vialGUI() {
            vial.set(true)
            Poll.until({ kb.subscribedTTL == 0 && !live.pushActive }) { ok in
                check("push: unsubscribes while the Vial GUI runs", ok && live.pressed.down.isEmpty)
                let before = kb.requests(f4), subscribes = kb.requests(f7)
                Poll.until({ kb.requests(f4) >= before + 4 }) { ok in
                    check("push: polls as before while the Vial GUI runs", ok && kb.requests(f7) == subscribes && kb.subscribedTTL == 0)
                    vial.set(false)
                    Poll.until({ live.pushActive && kb.subscribedTTL == 1 }) { ok in
                        check("push: resumes when the Vial GUI quits", ok)
                        hidden()
                    }
                }
            }
        }
        func hidden() {
            live.setGhostVisible(false)
            Poll.until({ kb.subscribedTTL == 0 }) { ok in
                check("push: unsubscribes when nothing needs the state fast", ok && !live.pushActive && live.pressed.down.isEmpty)
                live.setOverlayVisible(true)
                kb.setPressed([1])
                Poll.until({ live.pushActive }) { ok in
                    check("push: the overlay subscribes too", ok && kb.subscribedTTL == 1)
                    live.setGhostVisible(true)
                    live.setOverlayVisible(false)
                    kb.pushed.forEach(hid.injectReport)
                    Poll.until({ live.pressed.down == [1] }) { ok in
                        check("push: one subscription across overlay and ghost", ok && live.pushActive && kb.subscribedTTL == 1)
                        lapse()
                    }
                }
            }
        }
        func lapse() {
            kb.mute = true
            Poll.until({ !live.pushActive }, deadline: 5) { ok in
                check("push: renewals failing for a ttl end it, pressed keys cleared", ok && live.pressed.down.isEmpty && live.pressed.lit.isEmpty)
                let before = kb.requests(f4)
                Poll.until({ kb.requests(f4) >= before + 4 }) { ok in
                    check("push: back to fast polling after the lapse", ok)
                    kb.mute = false
                    Poll.until({ live.pushActive && kb.subscribedTTL == 1 }) { ok in
                        check("push: picked up again once a renewal gets through", ok)
                        live.shutdown()
                        check("push: unsubscribes on quit", kb.subscribedTTL == 0 && !live.pushActive)
                        live.setGhostVisible(false)
                        withExtendedLifetime(model) { done() }
                    }
                }
            }
        }
    }

    /// LiveKeyboard on firmware that answers 0xF7 as unhandled.
    private static func oldFirmware(_ check: @escaping (String, Bool) -> Void, done: @escaping () -> Void) {
        let kb = FakeKeyboard()
        kb.events = false
        let hid = HIDTransport(loopback: kb.respond)
        let live = LiveKeyboard(link: KeyboardLink(transport: hid), vialGUI: VialGUIWatcher(observing: false))
        let model = KeymapModel()
        let f4 = KeyboardLink.LiveCommand.state, f7 = KeyboardLink.LiveCommand.events
        live.history = TrainerHistory(url: nil)
        live.matrixOverride = true
        live.pushTTL = 1
        live.start(model: model, settings: .shared)
        hid.start()
        live.setOverlayVisible(true)
        // Two subscribe attempts (unhandled is believed the second time), then never again.
        Poll.until({ kb.requests(f7) >= 2 && kb.requests(f4) >= 6 }) { ok in
            Poll.wait(0.8) {
                check("old firmware: polls, and gives 0xF7 up after two unhandled replies (\(kb.requests(f7)) sent)",
                      ok && kb.requests(f7) == 2 && !live.pushActive && live.state != nil && live.pushStatus.contains("not supported"))
                let before = kb.requests(f4)
                live.setOverlayVisible(false)
                live.setOverlayVisible(true)
                Poll.until({ kb.requests(f4) >= before + 4 }) { ok in
                    check("old firmware: no unsubscribe, no new attempt on reopening", ok && kb.requests(f7) == 2)
                    live.setOverlayVisible(false)
                    withExtendedLifetime(model) { done() }
                }
            }
        }
    }
}
