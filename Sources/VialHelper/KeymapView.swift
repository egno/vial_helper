import SwiftUI

// MARK: - Root

struct KeymapRootView: View {
    @ObservedObject var model: KeymapModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var layoutObserver = KeyboardLayoutObserver.shared
    /// Live keyboard data (misfire heatmap, active / locked layers, indicators).
    @ObservedObject var live = LiveKeyboard.shared
    /// Opaque background for off-screen rendering (materials do not render there).
    var plainBackground = false
    /// Below 1 when the keymap at its natural size is larger than the screen (see OverlayController).
    var scale: CGFloat = 1
    /// Layers side by side when all are shown; the overlay picks what suits the screen.
    var columns = 2

    private let compactUnit: CGFloat = 32
    private let largeUnit: CGFloat = 56

    private var labelContext: LabelContext {
        LabelContext.current(model: model, settings: settings, keyOverrides: layoutObserver.overrides)
    }

    var body: some View {
        // Drawn smaller, and taking only that much room.
        ScaledLayout(scale: scale) {
            natural.scaleEffect(scale, anchor: .topLeading)
        }
    }

    private var natural: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let file = model.file, let geometry = model.geometry {
                content(file: file, geometry: geometry)
                if !file.combos.isEmpty { combos(file) }
                if !file.keyOverrides.isEmpty { keyOverrides(file) }
                if let h = model.holdAloneLayer { holdAloneNotes(file, geometry: geometry, layer: h) }
                if showsChordalMarker(file, geometry: geometry) { chordalNote }
                if showsMisfires { misfireNote }
                if let line = tapHoldParts(file), !line.isEmpty { tapHoldLine(line) }
            } else {
                errorView
            }
            hints
        }
        .padding(18)
        .background(plainBackground ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .fixedSize()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.file?.fileName ?? "Keymap")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            if let s = live.state { LiveIndicators(state: s, context: labelContext) }
            Spacer(minLength: 24)
            if !model.visibleLayers.isEmpty {
                HStack(spacing: 4) {
                    layerChip(index: nil, title: "All")
                    ForEach(model.visibleLayers, id: \.self) { i in
                        layerChip(index: i, title: chipTitle(i))
                    }
                }
            }
        }
    }

    private func chipTitle(_ i: Int) -> String {
        if let n = settings.layerName(i) { return "\(i) \(n)" }
        return "\(i)"
    }

    private func liveMark(_ layer: Int) -> LayerLiveMark {
        guard let s = live.state else { return LayerLiveMark() }
        // The default layer is always on; it only counts as active when nothing is above it.
        let active = layer == s.highestLayer || s.isMomentary(layer)
        return LayerLiveMark(active: active, highest: layer == s.highestLayer, locked: s.isLocked(layer))
    }

    private func layerChip(index: Int?, title: String) -> some View {
        let selected = model.selectedLayer == index
        let mark = index.map { liveMark($0) } ?? LayerLiveMark()
        return Button { model.select(index) } label: {
            HStack(spacing: 4) {
                if mark.active {
                    Circle().fill(selected ? Color.white : Color.accentColor)
                        .opacity(mark.highest ? 1 : 0.55)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                if mark.locked { Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)) }
            }
                .fixedSize()
                .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .rounded))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.08))
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func content(file: VilFile, geometry: KeyboardGeometry) -> some View {
        if let s = model.selectedLayer, s < file.layers.count {
            LayerCard(file: file, geometry: geometry, layer: s, name: settings.layerName(s), unit: largeUnit, encoderMode: settings.encoderMode, context: labelContext,
                      liveMark: liveMark(s), misfires: misfireBadges(layer: s))
        } else {
            let visible = model.visibleLayers
            let columns = max(1, min(self.columns, visible.count))
            let rows = stride(from: 0, to: visible.count, by: columns).map { start in
                Array(visible[start..<min(start + columns, visible.count)])
            }
            VStack(alignment: .leading, spacing: 28) {
                ForEach(rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: 36) {
                        ForEach(row, id: \.self) { i in
                            LayerCard(file: file, geometry: geometry, layer: i, name: settings.layerName(i), unit: compactUnit, encoderMode: settings.encoderMode, context: labelContext,
                                      liveMark: liveMark(i), misfires: misfireBadges(layer: i))
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
                                .overlay(activeOutline(liveMark(i)))
                                .contentShape(Rectangle())
                                .onTapGesture { model.select(i) }
                        }
                    }
                }
            }
        }
    }

    private func combos(_ file: VilFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Combos").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(Array(file.combos.enumerated()), id: \.offset) { _, combo in
                    HStack(spacing: 4) {
                        Text(combo.keys.map { Keycode.short($0, context: labelContext) }.joined(separator: " + "))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                        Text("→").foregroundStyle(.secondary).font(.system(size: 10))
                        Text(Keycode.short(combo.result, context: labelContext))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }

    private func keyOverrides(_ file: VilFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Key overrides").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(Array(file.keyOverrides.enumerated()), id: \.offset) { _, ko in
                    HStack(spacing: 4) {
                        Text(overrideTrigger(ko))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                        Text("→").foregroundStyle(.secondary).font(.system(size: 10))
                        Text(Keycode.short(ko.replacement, context: labelContext))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                        if let note = overrideNote(ko, layerCount: file.layers.count) {
                            Text(note).font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(KeyCapView.layerColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }

    /// "⇧ + ⌫", or "⌃ / ⇧ + ⌫" when any one of the modifiers is enough, plus "(no ⌥)" for negative mods.
    private func overrideTrigger(_ ko: KeyOverride) -> String {
        let mods = Keycode.modBitsSymbols(ko.triggerMods).joined(separator: ko.anyOneMod ? " / " : " + ")
        var parts = mods.isEmpty ? [] : [mods]
        if !Keycode.isEmpty(ko.trigger) { parts.append(Keycode.short(ko.trigger, context: labelContext)) }
        var text = parts.joined(separator: " + ")
        let negative = Keycode.modBitsSymbols(ko.negativeMods)
        if !negative.isEmpty { text += " (no \(negative.joined(separator: " ")))" }
        return text
    }

    private func overrideNote(_ ko: KeyOverride, layerCount: Int) -> String? {
        guard let layers = ko.layerRestriction(layerCount: layerCount) else { return nil }
        return "on " + layers.map { labelContext.layerName($0) }.joined(separator: ", ")
    }

    /// The marker is drawn only on tap-hold keys, so the legend appears only if one is on screen.
    private func showsChordalMarker(_ file: VilFile, geometry: KeyboardGeometry) -> Bool {
        guard !model.chordalExempt.isEmpty else { return false }
        let shown = model.selectedLayer.map { [$0] } ?? model.visibleLayers
        return shown.contains { layer in
            geometry.keys.contains { k in
                model.chordalExempt.contains(k.id) && Keycode.isTapHold(file.keycode(layer: layer, row: k.row, col: k.col))
            }
        }
    }

    private var chordalNote: some View {
        HStack(spacing: 4) {
            Text(KeyCapView.chordalMark).foregroundStyle(KeyCapView.chordalColor)
            Text("exempt from Chordal Hold: holds with keys on the same hand too")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    /// Accent outline of a layer card that is active on the keyboard right now.
    @ViewBuilder
    private func activeOutline(_ mark: LayerLiveMark) -> some View {
        if mark.active {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(mark.highest ? 0.9 : 0.4), lineWidth: mark.highest ? 2 : 1.5)
        }
    }

    // MARK: Misfire heatmap (base layer only)

    private static let misfireLayer = 0

    private func misfireBadges(layer: Int) -> [Int: MisfireBadge] {
        guard layer == Self.misfireLayer, live.showMisfires else { return [:] }
        return live.misfireBadges
    }

    /// The legend (and the `m` hint) appear only when there is something to explain.
    private var misfiresAvailable: Bool {
        live.misfires.contains { $0.heldMisfires > 0 || $0.tappedMisfires > 0 }
            && (model.selectedLayer == nil ? model.visibleLayers.contains(Self.misfireLayer) : model.selectedLayer == Self.misfireLayer)
    }

    private var showsMisfires: Bool { live.showMisfires && misfiresAvailable }

    private var misfireNote: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(KeyCapView.misfireColor.opacity(0.45)).frame(width: 9, height: 9)
            Text(model.selectedLayer == nil
                 ? "mod-tap misfires on L\(Self.misfireLayer) since power-up, relative between keys (\(Self.misfireLayer) shows counts)"
                 : "mod-tap misfires since power-up: left held by mistake, right tapped by mistake (typos count too); compare keys, not numbers")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    /// Tap-hold phrases of the .vil, with Chordal Hold / Flow Tap as the keyboard applies them
    /// right now when it can tell (0xF6).
    private func tapHoldParts(_ file: VilFile) -> [String]? {
        let parts = file.settings?.tapHoldSummary
        guard let info = live.tapHold else { return parts }
        return info.correcting(parts ?? [])
    }

    private func tapHoldLine(_ parts: [String]) -> some View {
        Text(parts.joined(separator: " · "))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
    }

    /// Legend for the teal hold-alone legends, plus bindings the firmware will never send.
    private func holdAloneNotes(_ file: VilFile, geometry: KeyboardGeometry, layer h: Int) -> some View {
        let problems: [String] = geometry.keys.compactMap { k in
            guard let why = file.holdAloneProblem(layer: h, row: k.row, col: k.col) else { return nil }
            let action = Keycode.short(file.keycode(layer: h, row: k.row, col: k.col), context: labelContext)
            let base = Keycode.short(file.keycode(layer: 0, row: k.row, col: k.col), context: labelContext)
            return "\(action) on \(base): \(why)"
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("◔").foregroundStyle(KeyCapView.aloneColor)
                Text("hold alone: held past the tapping term and released without another key (under 1 s), from L\(h)")
            }
            ForEach(problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(KeyCapView.infoColor)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private var errorView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Could not load keymap", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(model.error ?? "Unknown error").foregroundStyle(.secondary)
            Text("Path: \(settings.expandedPath)").font(.caption).foregroundStyle(.secondary)
            Text("Set the .vil file in Settings (right-click the menu bar icon).").font(.caption)
        }
        .frame(minWidth: 360, alignment: .leading)
        .padding(.vertical, 12)
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint("esc", "close")
            hint("0–9", "layer")
            hint("a", "all")
            hint("←→", "switch")
            if misfiresAvailable { hint("m", live.showMisfires ? "hide misfires" : "misfires") }
            if let hk = settings.hotKey { hint(hk.display, "toggle") }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
            Text(what)
        }
    }
}

extension LabelContext {
    /// The context the overlay and the ghost label keys with.
    static func current(model: KeymapModel, settings: AppSettings, keyOverrides: [String: String]) -> LabelContext {
        // Names typed in Settings win; otherwise the ones the keyboard's own definition carries (live read).
        var names = settings.customKeycodeNameList
        if !names.contains(where: { !$0.isEmpty }), model.file?.isLive == true {
            names = model.live.snapshot?.customKeycodeNames ?? names
        }
        return LabelContext(tapDances: model.file?.tapDances ?? [], layerNames: settings.layerNameList, keyOverrides: keyOverrides,
                            holdAloneLayer: model.holdAloneLayer, customKeycodeNames: names,
                            chordalExempt: model.chordalExempt)
    }
}

/// Small status chips (trainer, Caps Word, one-shot…); nothing is drawn while everything is idle.
struct LiveIndicators: View {
    let state: LiveState
    let context: LabelContext
    /// Held modifiers and locked layers too: the ghost has no layer chips or cards to show them on.
    var detailed = false
    var fontSize: CGFloat = 10.5
    /// Dark plate under every chip, for drawing straight over other windows (ghost mode).
    var plateOpacity: Double? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.items(state, context: context, detailed: detailed), id: \.self) { item in
                Text(item)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .legendHalo(plateOpacity != nil, unit: fontSize * 3)
                    .padding(.horizontal, fontSize * 0.67)
                    .padding(.vertical, fontSize * 0.19)
                    .background(Capsule().fill(KeyCapView.infoColor.opacity(0.22)))
                    .background(Capsule().fill(Color.black.opacity(plateOpacity ?? 0)))
                    .fixedSize()
            }
        }
    }

    static func items(_ s: LiveState, context: LabelContext, detailed: Bool = false) -> [String] {
        var items: [String] = []
        if detailed {
            // Caps Word's own weak Shift comes and goes with every key; the chip below says it.
            let held = LiveReport.modSymbols(s.mods | (s.capsWord ? 0 : s.weakMods))
            if !held.isEmpty { items.append(held) }
            for l in LiveReport.layers(s.lockedLayers) { items.append("\(context.layerName(l)) locked") }
        }
        if s.trainerActive {
            items.append(s.trainerState == 2 ? "Trainer: results" : s.trainerState == 3 ? "Trainer: nothing typeable" : "Trainer")
        }
        if s.capsWord { items.append("Caps Word") }
        if s.capsLock { items.append("Caps Lock") }
        if s.oneShotLockedMods != 0 { items.append("one-shot \(LiveReport.modSymbols(s.oneShotLockedMods)) locked") }
        let pending = s.oneShotMods & ~s.oneShotLockedMods
        if pending != 0 { items.append("one-shot \(LiveReport.modSymbols(pending))") }
        if let l = s.oneShotLayer { items.append("one-shot \(context.layerName(l))") }
        return items
    }
}

// MARK: - Layer card

struct LayerCard: View {
    let file: VilFile
    let geometry: KeyboardGeometry
    let layer: Int
    let name: String?
    let unit: CGFloat
    var encoderMode: EncoderMode = .both
    var context: LabelContext = LabelContext()
    var liveMark = LayerLiveMark()
    /// Misfire badges by `KeyPlacement.id`; empty on every layer but the base one.
    var misfires: [Int: MisfireBadge] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                LayerTitle(layer: layer, name: name, unit: unit)
                if layer == context.holdAloneLayer {
                    Text("hold-alone config").font(.system(size: max(10, unit * 0.24), weight: .semibold, design: .rounded))
                        .foregroundStyle(KeyCapView.aloneColor)
                }
                if liveMark.locked {
                    Label("locked", systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: max(9.5, unit * 0.22), weight: .semibold, design: .rounded))
                        .foregroundStyle(KeyCapView.layerColor)
                }
                if liveMark.active {
                    Text("active")
                        .font(.system(size: max(9.5, unit * 0.22), weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(liveMark.highest ? 0.85 : 0.5)))
                }
            }
            KeyboardCanvas(file: file, geometry: geometry, layer: layer, unit: unit, encoderMode: encoderMode, context: context, misfires: misfires)
        }
    }
}

/// "L2 Sym": the number and the name from Settings, as the layer cards and the ghost head a layer.
struct LayerTitle: View {
    let layer: Int
    let name: String?
    let unit: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            // Same blue as the layer legends on the keys (see KeyCapView.secondaryColor).
            Text("L\(layer)")
                .font(.system(size: max(11, unit * 0.32), weight: .bold, design: .rounded))
            if let name {
                Text(name).font(.system(size: max(11, unit * 0.3), weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(KeyCapView.layerColor)
    }
}

/// How a canvas is drawn where it differs from the overlay (ghost mode sets these).
struct CanvasStyle: Equatable {
    /// Opacity of the dark plate under every key and legend chip, for drawing straight over other
    /// windows; nil = no plates. The legends keep their own opacity and get a dark halo.
    var plateOpacity: Double? = nil
    /// Reduced label set in larger type (see `KeyLabel.simplified`).
    var simplified = false
    /// Leave out the keys an upper layer inherits from the layers below, so that only what the
    /// layer changes is drawn.
    var hideInherited = false
}

extension View {
    /// Dark halo that keeps a light legend readable when a bright window shows through its plate.
    @ViewBuilder
    func legendHalo(_ on: Bool, unit: CGFloat) -> some View {
        if on {
            shadow(color: .black.opacity(0.9), radius: max(0.8, unit * 0.03))
                .shadow(color: .black.opacity(0.6), radius: max(1.5, unit * 0.07))
        } else {
            self
        }
    }
}

/// How a layer relates to the keyboard's live state (all false without live data).
struct LayerLiveMark: Equatable {
    /// On right now: the highest active layer, or any layer switched on above the default one.
    var active = false
    var highest = false
    /// Held on by Layer Lock.
    var locked = false
}

struct KeyboardCanvas: View {
    let file: VilFile
    let geometry: KeyboardGeometry
    let layer: Int
    let unit: CGFloat
    var encoderMode: EncoderMode = .both
    var context: LabelContext = LabelContext()
    var misfires: [Int: MisfireBadge] = [:]
    /// Active layers below `layer`, highest first. A transparent key shows what the first of them
    /// that is not transparent there holds, dimmed (the way the firmware resolves it). Empty =
    /// transparent keys are drawn as such.
    var below: [Int] = []
    var style = CanvasStyle()
    /// Non-nil: the keys physically down are marked (ghost mode with "Highlight pressed keys").
    var pressed: PressedKeys? = nil

    var body: some View {
        let keys = file.layers[layer]
        let gap = unit * 0.1
        ZStack(alignment: .topLeading) {
            ForEach(geometry.keys) { k in
                let code = (k.row < keys.count && k.col < keys[k.row].count) ? keys[k.row][k.col] : "-1"
                if code != "-1", !isHidden(code) {
                    let label = resolvedLabel(code, row: k.row, col: k.col)
                    KeyCapView(label: style.simplified ? label.simplified : label, unit: unit, misfire: misfires[k.id], style: style)
                        .frame(width: k.width * unit - gap, height: k.height * unit - gap)
                        .rotationEffect(.degrees(k.rotation))
                        .position(x: k.center.x * unit, y: k.center.y * unit)
                }
            }
            if layer < file.encoders.count {
                ForEach(Array(file.encoders[layer].enumerated()), id: \.offset) { i, enc in
                    if i < geometry.encoderAnchors.count, enc.count >= 2, encoderMode.shows(index: i) {
                        EncoderLegend(ccw: Keycode.short(enc[0], context: context),
                                      cw: Keycode.short(enc[1], context: context),
                                      unit: unit, plateOpacity: style.plateOpacity)
                            .position(x: geometry.encoderAnchors[i].x * unit, y: geometry.encoderAnchors[i].y * unit)
                    }
                }
            }
            if let pressed { PressedKeysLayer(pressed: pressed, geometry: geometry, unit: unit) }
        }
        .frame(width: geometry.size.width * unit, height: geometry.size.height * unit)
    }

    /// The diff view: on a layer with active layers below it, what falls through is not drawn.
    private func isHidden(_ code: String) -> Bool {
        style.hideInherited && !below.isEmpty && Keycode.isTransparent(code)
    }

    private func resolvedLabel(_ code: String, row: Int, col: Int) -> KeyLabel {
        guard Keycode.isTransparent(code), !below.isEmpty else { return label(code, row: row, col: col) }
        for lower in below {
            let below = file.keycode(layer: lower, row: row, col: col)
            if Keycode.isTransparent(below) { continue }
            var l = label(below, row: row, col: col)
            l.inherited = true
            return l
        }
        return label(code, row: row, col: col)
    }

    private func label(_ code: String, row: Int, col: Int) -> KeyLabel {
        var l = Keycode.label(code, context: context)
        if context.chordalExempt.contains(row * 100 + col), Keycode.isTapHold(code) { l.chordalExempt = true }
        guard let h = context.holdAloneLayer else { return l }
        if layer == h {
            if let why = file.holdAloneProblem(layer: h, row: row, col: col) {
                l.secondary = "! " + why
                l.secondaryKind = .info
            }
        } else if Keycode.isTapHold(code) {
            let action = file.keycode(layer: h, row: row, col: col)
            if Keycode.isHoldAloneSendable(action) { l.alone = Keycode.short(action, context: context) }
        }
        return l
    }
}

/// The marks on the keys that are down, over the key caps. It alone observes `PressedKeys`, so a
/// key press redraws these few shapes and none of the caps; idle, nothing here is drawn or
/// animated. A press shows at once, a release fades out (the afterglow that makes a quick tap
/// visible).
struct PressedKeysLayer: View {
    static let afterglow: TimeInterval = 0.35
    static let color = Color(red: 1.0, green: 0.82, blue: 0.25)

    @ObservedObject var pressed: PressedKeys
    let geometry: KeyboardGeometry
    let unit: CGFloat

    var body: some View {
        let gap = unit * 0.1, radius = unit * 0.16
        ZStack(alignment: .topLeading) {
            ForEach(geometry.keys) { k in
                let on = pressed.lit.contains(k.id)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Self.color.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Self.color, lineWidth: max(1.5, unit * 0.06)))
                    .frame(width: k.width * unit - gap, height: k.height * unit - gap)
                    .rotationEffect(.degrees(k.rotation))
                    .position(x: k.center.x * unit, y: k.center.y * unit)
                    .opacity(on ? 1 : 0)
                    .animation(on ? nil : .easeOut(duration: Self.afterglow), value: on)
            }
        }
        .frame(width: geometry.size.width * unit, height: geometry.size.height * unit)
        .allowsHitTesting(false)
    }
}

struct EncoderLegend: View {
    let ccw: String
    let cw: String
    let unit: CGFloat
    /// See `CanvasStyle.plateOpacity`.
    var plateOpacity: Double? = nil

    var body: some View {
        HStack(spacing: unit * 0.12) {
            Text("↺ " + ccw)
            Text("·").foregroundStyle(.tertiary)
            Text(cw + " ↻")
        }
        .font(.system(size: max(9, unit * 0.24), weight: .medium, design: .rounded))
        .foregroundStyle(plateOpacity == nil ? .secondary : .primary)
        .legendHalo(plateOpacity != nil, unit: unit)
        .padding(.horizontal, unit * 0.2)
        .padding(.vertical, unit * 0.08)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .background(Capsule().fill(Color.black.opacity(plateOpacity ?? 0)))
        .fixedSize()
    }
}

// MARK: - Keycap

struct KeyCapView: View {
    static let layerColor = Color.blue
    static let modColor = Color.purple
    static let infoColor = Color.orange
    static let aloneColor = Color.teal
    static let chordalColor = Color.secondary
    static let chordalMark = "✱"
    static let misfireColor = Color.red

    let label: KeyLabel
    let unit: CGFloat
    /// Misfire heatmap entry of this key (base layer mod-taps), nil for everything else.
    var misfire: MisfireBadge? = nil
    var style = CanvasStyle()

    var body: some View {
        ZStack {
            plate
            legends.legendHalo(style.plateOpacity != nil, unit: unit)
        }
        .opacity(label.inherited ? 0.45 : 1)
    }

    /// Everything behind the legends. With a plate (ghost mode) its opacity is the user's
    /// setting and takes the tint and the outline along; the legends on top are left alone.
    private var plate: some View {
        let radius = unit * 0.16
        return ZStack {
            if style.plateOpacity != nil {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black)
            }
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
            if let m = misfire, m.heat > 0 {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(KeyCapView.misfireColor.opacity(0.06 + 0.3 * m.heat))
            }
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(stroke, style: StrokeStyle(lineWidth: 1, dash: label.style == .transparent ? [3, 3] : []))
        }
        .opacity(style.plateOpacity ?? 1)
    }

    private var legends: some View {
        // The reduced set leaves room for larger type.
        let primarySize = unit * (style.simplified ? 0.4 : 0.36)
        let secondarySize = unit * (style.simplified ? 0.25 : 0.2)
        return ZStack {
            if label.style != .none {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(label.primary)
                        .font(.system(size: primarySize, weight: .semibold, design: .rounded))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.35)
                    Spacer(minLength: 0)
                    if let s = label.secondary {
                        Text(s)
                            .font(.system(size: secondarySize, weight: .semibold, design: .rounded))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.bottom, unit * (style.simplified ? 0.05 : 0.07))
                    }
                }
                .padding(.horizontal, unit * 0.06)
                .padding(.top, label.alone != nil ? unit * 0.2 : label.secondary == nil ? 0 : unit * (style.simplified ? 0.04 : 0.1))
            }
            if let alone = label.alone {
                Text(unit >= 40 ? "◔ " + alone : alone)
                    .font(.system(size: max(7, unit * 0.2), weight: .bold, design: .rounded))
                    .foregroundStyle(KeyCapView.aloneColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.top, unit * 0.05)
                    .padding(.horizontal, unit * 0.08)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            // Counts only fit the zoomed key caps; the all-layers view keeps to the tint.
            if let m = misfire, unit >= 40 {
                if m.held > 0 { misfireCount(m.held, alignment: .bottomLeading) }
                if m.tapped > 0 { misfireCount(m.tapped, alignment: .bottomTrailing) }
            }
            if label.chordalExempt {
                Text(KeyCapView.chordalMark)
                    .font(.system(size: max(6, unit * 0.16), weight: .bold))
                    .foregroundStyle(KeyCapView.chordalColor)
                    .padding(.top, unit * 0.06)
                    .padding(.leading, unit * 0.09)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Held misfires sit bottom left, tapped ones bottom right, beside the hold legend.
    private func misfireCount(_ n: Int, alignment: Alignment) -> some View {
        Text(n > 999 ? "999+" : "\(n)")
            .font(.system(size: max(6.5, unit * 0.17), weight: .semibold, design: .rounded))
            .foregroundStyle(KeyCapView.misfireColor.opacity(0.85))
            .lineLimit(1)
            .padding(.bottom, unit * 0.05)
            .padding(.horizontal, unit * 0.09)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private var fill: Color {
        switch label.style {
        case .normal: return Color.primary.opacity(0.08)
        case .transparent: return Color.clear
        case .none: return Color.primary.opacity(0.025)
        case .layer: return Color.blue.opacity(0.18)
        case .modifier: return Color.purple.opacity(0.18)
        case .special: return Color.orange.opacity(0.18)
        }
    }

    private var stroke: Color {
        switch label.style {
        case .transparent: return Color.primary.opacity(0.25)
        case .none: return Color.primary.opacity(0.06)
        default: return Color.primary.opacity(0.1)
        }
    }

    private var primaryColor: Color {
        switch label.style {
        case .transparent: return Color.primary.opacity(0.35)
        default: return Color.primary
        }
    }

    private var secondaryColor: Color {
        switch label.secondaryKind {
        case .mod: return KeyCapView.modColor
        case .layer: return KeyCapView.layerColor
        case .info: return KeyCapView.infoColor
        }
    }
}

// MARK: - Flow layout (wrapping HStack)

/// Gives its only subview its natural size and reports that size times `scale`; the subview is
/// expected to draw itself scaled by the same factor from its top left corner.
struct ScaledLayout: Layout {
    var scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 900
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
