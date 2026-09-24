import SwiftUI

// MARK: - Root

struct KeymapRootView: View {
    @ObservedObject var model: KeymapModel
    @ObservedObject var settings: AppSettings
    /// Opaque background for off-screen rendering (materials do not render there).
    var plainBackground = false

    private let compactUnit: CGFloat = 32
    private let largeUnit: CGFloat = 56

    private var labelContext: LabelContext {
        LabelContext(tapDances: model.file?.tapDances ?? [], layerNames: settings.layerNameList)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let file = model.file, let geometry = model.geometry {
                content(file: file, geometry: geometry)
                if !file.combos.isEmpty { combos(file) }
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

    private func layerChip(index: Int?, title: String) -> some View {
        let selected = model.selectedLayer == index
        return Button { model.select(index) } label: {
            Text(title)
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
            LayerCard(file: file, geometry: geometry, layer: s, name: settings.layerName(s), unit: largeUnit, encoderMode: settings.encoderMode, context: labelContext)
        } else {
            let visible = model.visibleLayers
            let columns = visible.count > 1 ? 2 : 1
            let rows = stride(from: 0, to: visible.count, by: columns).map { start in
                Array(visible[start..<min(start + columns, visible.count)])
            }
            VStack(alignment: .leading, spacing: 28) {
                ForEach(rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: 36) {
                        ForEach(row, id: \.self) { i in
                            LayerCard(file: file, geometry: geometry, layer: i, name: settings.layerName(i), unit: compactUnit, encoderMode: settings.encoderMode, context: labelContext)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
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

// MARK: - Layer card

struct LayerCard: View {
    let file: VilFile
    let geometry: KeyboardGeometry
    let layer: Int
    let name: String?
    let unit: CGFloat
    var encoderMode: EncoderMode = .both
    var context: LabelContext = LabelContext()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Same blue as the layer legends on the keys (see KeyCapView.secondaryColor).
                Text("L\(layer)")
                    .font(.system(size: max(11, unit * 0.32), weight: .bold, design: .rounded))
                    .foregroundStyle(KeyCapView.layerColor)
                if let name {
                    Text(name).font(.system(size: max(11, unit * 0.3), weight: .semibold, design: .rounded))
                        .foregroundStyle(KeyCapView.layerColor)
                }
            }
            KeyboardCanvas(file: file, geometry: geometry, layer: layer, unit: unit, encoderMode: encoderMode, context: context)
        }
    }
}

struct KeyboardCanvas: View {
    let file: VilFile
    let geometry: KeyboardGeometry
    let layer: Int
    let unit: CGFloat
    var encoderMode: EncoderMode = .both
    var context: LabelContext = LabelContext()

    var body: some View {
        let keys = file.layers[layer]
        let gap = unit * 0.1
        ZStack(alignment: .topLeading) {
            ForEach(geometry.keys) { k in
                let code = (k.row < keys.count && k.col < keys[k.row].count) ? keys[k.row][k.col] : "-1"
                if code != "-1" {
                    KeyCapView(label: Keycode.label(code, context: context), unit: unit)
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
                                      unit: unit)
                            .position(x: geometry.encoderAnchors[i].x * unit, y: geometry.encoderAnchors[i].y * unit)
                    }
                }
            }
        }
        .frame(width: geometry.size.width * unit, height: geometry.size.height * unit)
    }
}

struct EncoderLegend: View {
    let ccw: String
    let cw: String
    let unit: CGFloat

    var body: some View {
        HStack(spacing: unit * 0.12) {
            Text("↺ " + ccw)
            Text("·").foregroundStyle(.tertiary)
            Text(cw + " ↻")
        }
        .font(.system(size: max(9, unit * 0.24), weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, unit * 0.2)
        .padding(.vertical, unit * 0.08)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .fixedSize()
    }
}

// MARK: - Keycap

struct KeyCapView: View {
    static let layerColor = Color.blue
    static let modColor = Color.purple
    static let infoColor = Color.orange

    let label: KeyLabel
    let unit: CGFloat

    var body: some View {
        let radius = unit * 0.16
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(stroke, style: StrokeStyle(lineWidth: 1, dash: label.style == .transparent ? [3, 3] : []))
            if label.style != .none {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(label.primary)
                        .font(.system(size: unit * 0.36, weight: .semibold, design: .rounded))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.35)
                    Spacer(minLength: 0)
                    if let s = label.secondary {
                        Text(s)
                            .font(.system(size: unit * 0.2, weight: .semibold, design: .rounded))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.bottom, unit * 0.07)
                    }
                }
                .padding(.horizontal, unit * 0.06)
                .padding(.top, label.secondary == nil ? 0 : unit * 0.1)
            }
        }
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
