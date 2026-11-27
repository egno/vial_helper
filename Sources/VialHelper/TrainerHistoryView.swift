import AppKit
import SwiftUI

// "Trainer History…" window: speed and accuracy over the recorded sessions, what kinds of misses
// were made, and the characters that are slowest / most often missed. Charts are plain SwiftUI
// Canvas drawings (no Swift Charts dependency). Transient state lives in ObservableObjects, not
// @State (see the toolchain note in the README).

private extension Color {
    init(light: UInt32, dark: UInt32) {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

enum TrainerPalette {
    static let series = Color(light: 0x257DE0, dark: 0x338CED)
    /// Fixed order: wrong key, held, tapped, wrong layer.
    static let missKinds = [
        Color(light: 0x257DE0, dark: 0x338CED),
        Color(light: 0xF47230, dark: 0xE76624),
        Color(light: 0x00B894, dark: 0x00A888),
        Color(light: 0xF2A600, dark: 0xD28E05),
    ]
    static let grid = Color(light: 0xE7E7E7, dark: 0x303030)
    static let axis = Color(light: 0xC2C2C2, dark: 0x474747)
    static let surface = Color(light: 0xFFFFFF, dark: 0x191919)
}

/// Which point of a line chart the pointer is over.
final class ChartHover: ObservableObject {
    @Published var index: Int?
}

final class TrainerHistoryUI: ObservableObject {
    let wpmHover = ChartHover()
    let accuracyHover = ChartHover()
}

struct TrainerHistoryView: View {
    @ObservedObject var history: TrainerHistory
    var ui = TrainerHistoryUI()
    /// Trend charts show at most this many of the newest sessions.
    static let trendLimit = 100
    static let listLength = 8

    private var sessions: [TrainerSessionRecord] { Array(history.records.suffix(Self.trendLimit)) }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()
    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if history.records.isEmpty {
                empty
            } else {
                header
                tiles
                trend(title: "Speed, WPM", values: sessions.map { Double($0.wpm) }, unit: "WPM", hover: ui.wpmHover, floorAtZero: false)
                trend(title: "Accuracy, %", values: sessions.map { Double($0.accuracy) }, unit: "%", hover: ui.accuracyHover, ceiling: 100)
                missBreakdown
                HStack(alignment: .top, spacing: 28) {
                    slowest
                    leastAccurate
                }
            }
            if let err = history.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(22)
        .frame(width: 680, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No trainer sessions recorded yet").font(.headline)
            Text("Finish a session in the keyboard's typing trainer while Vial Helper is running and the keyboard is connected. Sessions are picked up within a few seconds, also with the overlay closed. Needs firmware that reports trainer results.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        let all = history.records
        let range = all.first.map { Self.dayFormat.string(from: $0.timestamp) } ?? ""
        let more = all.count > sessions.count ? " · charts show the last \(sessions.count)" : ""
        return HStack(alignment: .firstTextBaseline) {
            Text("Trainer history").font(.system(size: 17, weight: .semibold, design: .rounded))
            Spacer()
            Text("\(all.count) session\(all.count == 1 ? "" : "s") since \(range)\(more)")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    // MARK: Stat tiles

    private var tiles: some View {
        let last = history.records.last
        let prev = history.records.dropLast().last
        func delta(_ a: Int?, _ b: Int?) -> String? {
            guard let a, let b, a != b else { return nil }
            return (a > b ? "+" : "−") + "\(abs(a - b)) vs. previous"
        }
        return HStack(spacing: 10) {
            tile("Last speed", "\(last?.wpm ?? 0)", "WPM", delta(last?.wpm, prev?.wpm))
            tile("Last accuracy", "\(last?.accuracy ?? 0)", "%", delta(last?.accuracy, prev?.accuracy))
            tile("Best speed", "\(history.records.map(\.bestWpm).max() ?? 0)", "WPM", "all-time, from the keyboard")
            tile("Best accuracy", "\(history.records.map(\.bestAccuracy).max() ?? 0)", "%", "all-time, from the keyboard")
        }
    }

    private func tile(_ title: String, _ value: String, _ unit: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(note ?? " ").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(TrainerPalette.surface))
    }

    // MARK: Trend charts

    private func trend(title: String, values: [Double], unit: String, hover: ChartHover,
                       floorAtZero: Bool = false, ceiling: Double? = nil) -> some View {
        let s = sessions
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            TrendChart(values: values, unit: unit, ceiling: ceiling, hover: hover,
                       caption: { i in i < s.count ? "#\(history.records.count - s.count + i + 1) · " + Self.stampFormat.string(from: s[i].timestamp) : "" },
                       firstLabel: s.first.map { Self.dayFormat.string(from: $0.timestamp) } ?? "",
                       lastLabel: s.last.map { Self.dayFormat.string(from: $0.timestamp) } ?? "")
                .frame(height: 132)
        }
    }

    // MARK: Miss breakdown

    private var missBreakdown: some View {
        let names = ["wrong key", "held (wanted a tap)", "tapped (wanted a hold)", "wrong layer"]
        let all = history.records
        let totals = [all.map(\.missWrongKey).reduce(0, +), all.map(\.missHeld).reduce(0, +),
                      all.map(\.missTapped).reduce(0, +), all.map(\.missWrongLayer).reduce(0, +)]
        let recentN = min(5, all.count)
        let recent = all.suffix(recentN)
        let recentTotals = [recent.map(\.missWrongKey).reduce(0, +), recent.map(\.missHeld).reduce(0, +),
                            recent.map(\.missTapped).reduce(0, +), recent.map(\.missWrongLayer).reduce(0, +)]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Misses by kind").font(.system(size: 12, weight: .semibold))
            missRow("All sessions", totals)
            if all.count > recentN { missRow("Last \(recentN)", recentTotals) }
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { i in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(TrainerPalette.missKinds[i]).frame(width: 9, height: 9)
                        Text(names[i]).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func missRow(_ title: String, _ counts: [Int]) -> some View {
        let total = max(counts.reduce(0, +), 1)
        return HStack(spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            GeometryReader { geo in
                let gap: CGFloat = 2
                let shown = counts.enumerated().filter { $0.element > 0 }
                let usable = geo.size.width - gap * CGFloat(max(shown.count - 1, 0))
                HStack(spacing: gap) {
                    ForEach(shown, id: \.offset) { i, n in
                        let w = usable * CGFloat(n) / CGFloat(total)
                        let share = Int((Double(n) / Double(total) * 100).rounded())
                        ZStack {
                            RoundedRectangle(cornerRadius: 3).fill(TrainerPalette.missKinds[i])
                            if w > 34 {
                                Text("\(share)%").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(i == 3 ? Color.black : Color.white)
                            }
                        }
                        .frame(width: max(w, 1))
                        .help("\(n) of \(total) misses (\(share)%)")
                    }
                }
            }
            .frame(height: 18)
            Text("\(counts.reduce(0, +))").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: Character lists

    private struct CharRow: Identifiable {
        var char: String
        var value: Double
        var text: String
        var detail: String
        var id: String { char }
    }

    private var slowest: some View {
        let totals = history.charTotals
        // A mean of a few keystrokes is noise; fall back to everything while data is scarce.
        var pool = totals.filter { $0.stat.correct >= 10 }
        if pool.count < 3 { pool = totals.filter { $0.stat.correct >= 1 } }
        let rows = pool.map { t -> CharRow in
            let mean = Double(t.stat.latencyMs) / Double(t.stat.correct)
            return CharRow(char: t.char, value: mean, text: "\(Int(mean.rounded())) ms", detail: "\(t.stat.correct) typed")
        }.sorted { $0.value > $1.value }.prefix(Self.listLength)
        return charList(title: "Slowest characters", subtitle: "mean time to the correct keystroke", rows: Array(rows))
    }

    private var leastAccurate: some View {
        let totals = history.charTotals.filter { $0.stat.misses > 0 }
        var pool = totals.filter { $0.stat.attempts >= 10 }
        if pool.count < 3 { pool = totals }
        let rows = pool.map { t -> CharRow in
            let missRate = Double(t.stat.misses) / Double(t.stat.attempts)
            return CharRow(char: t.char, value: missRate, text: "\(Int((missRate * 100).rounded()))% missed",
                           detail: "\(t.stat.misses) of \(t.stat.attempts)")
        }.sorted { $0.value > $1.value }.prefix(Self.listLength)
        return charList(title: "Least accurate characters", subtitle: "wrong keystrokes while it was expected", rows: Array(rows))
    }

    private func charList(title: String, subtitle: String, rows: [CharRow]) -> some View {
        let maxValue = rows.map(\.value).max() ?? 1
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("Nothing yet").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.char == " " ? "␣" : row.char)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 22, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3).fill(TrainerPalette.series)
                            .frame(width: max(2, geo.size.width * CGFloat(row.value / max(maxValue, 0.0001))))
                    }
                    .frame(height: 10)
                    Text(row.text).font(.system(size: 11).monospacedDigit()).frame(width: 78, alignment: .trailing)
                    Text(row.detail).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Line chart

/// One series over session index: 2 pt line, hairline grid, the last value labelled, and a
/// crosshair with a value read-out under the pointer.
struct TrendChart: View {
    let values: [Double]
    let unit: String
    var ceiling: Double? = nil
    @ObservedObject var hover: ChartHover
    var caption: (Int) -> String = { _ in "" }
    var firstLabel = ""
    var lastLabel = ""

    private let left: CGFloat = 30
    private let right: CGFloat = 44
    private let top: CGFloat = 8
    private let bottom: CGFloat = 18

    /// Rounded bounds with a little headroom, and three or four grid steps.
    private var scale: (lo: Double, hi: Double, step: Double) {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let span = max(hi - lo, 4)
        let raw = span / 3
        let step = [1.0, 2, 5, 10, 20, 25, 50, 100].first { $0 >= raw } ?? 100
        var top = (hi / step).rounded(.up) * step
        if let ceiling { top = min(top, ceiling) }
        var bottom = (lo / step).rounded(.down) * step
        if bottom == top { bottom -= step }
        return (bottom, top, step)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let plot = CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)
            let s = scale
            let x: (Int) -> CGFloat = { i in
                values.count > 1 ? plot.minX + plot.width * CGFloat(i) / CGFloat(values.count - 1) : plot.midX
            }
            let y: (Double) -> CGFloat = { v in plot.maxY - plot.height * CGFloat((v - s.lo) / max(s.hi - s.lo, 0.0001)) }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    // Grid and y labels.
                    var tick = s.lo
                    while tick <= s.hi + 0.001 {
                        var line = Path()
                        line.move(to: CGPoint(x: plot.minX, y: y(tick)))
                        line.addLine(to: CGPoint(x: plot.maxX, y: y(tick)))
                        ctx.stroke(line, with: .color(tick == s.lo ? TrainerPalette.axis : TrainerPalette.grid), lineWidth: 1)
                        ctx.draw(Text("\(Int(tick))").font(.system(size: 10)).foregroundColor(.secondary),
                                 at: CGPoint(x: plot.minX - 6, y: y(tick)), anchor: .trailing)
                        tick += s.step
                    }
                    // Hover crosshair.
                    if let h = hover.index, h < values.count {
                        var cross = Path()
                        cross.move(to: CGPoint(x: x(h), y: plot.minY))
                        cross.addLine(to: CGPoint(x: x(h), y: plot.maxY))
                        ctx.stroke(cross, with: .color(TrainerPalette.axis), lineWidth: 1)
                    }
                    // Series.
                    var path = Path()
                    for (i, v) in values.enumerated() {
                        let p = CGPoint(x: x(i), y: y(v))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    ctx.stroke(path, with: .color(TrainerPalette.series), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    // Markers: every point while there are few, otherwise the last and the hovered one.
                    for (i, v) in values.enumerated() where values.count <= 30 || i == values.count - 1 || i == hover.index {
                        let big = i == values.count - 1 || i == hover.index
                        let r: CGFloat = big ? 4 : 2.5
                        let dot = CGRect(x: x(i) - r, y: y(v) - r, width: r * 2, height: r * 2)
                        if big { ctx.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(Color(nsColor: .windowBackgroundColor))) }
                        ctx.fill(Path(ellipseIn: dot), with: .color(TrainerPalette.series))
                    }
                    // Direct label of the newest value.
                    if let last = values.last {
                        ctx.draw(Text("\(Int(last)) \(unit)").font(.system(size: 11, weight: .semibold)).foregroundColor(.primary),
                                 at: CGPoint(x: plot.maxX + 8, y: y(last)), anchor: .leading)
                    }
                    // X axis: session dates at both ends.
                    ctx.draw(Text(firstLabel).font(.system(size: 10)).foregroundColor(.secondary),
                             at: CGPoint(x: plot.minX, y: plot.maxY + 10), anchor: .leading)
                    if values.count > 1 {
                        ctx.draw(Text(lastLabel).font(.system(size: 10)).foregroundColor(.secondary),
                                 at: CGPoint(x: plot.maxX, y: plot.maxY + 10), anchor: .trailing)
                    }
                }
                if let h = hover.index, h < values.count {
                    tooltip(h)
                        .fixedSize()
                        .position(x: min(max(x(h), plot.minX + 70), plot.maxX - 40), y: max(y(values[h]) - 26, 14))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    guard !values.isEmpty, plot.width > 0 else { return }
                    let f = (p.x - plot.minX) / plot.width
                    let i = Int((f * CGFloat(values.count - 1)).rounded())
                    let clamped = min(max(i, 0), values.count - 1)
                    if hover.index != clamped { hover.index = clamped }
                case .ended:
                    if hover.index != nil { hover.index = nil }
                }
            }
        }
    }

    private func tooltip(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(Int(values[i])) \(unit)").font(.system(size: 11, weight: .semibold))
            Text(caption(i)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1))
    }
}

// MARK: - Window

final class TrainerHistoryWindowController {
    static let shared = TrainerHistoryWindowController()
    private var window: NSWindow?

    func show(history: TrainerHistory = .shared) {
        if window == nil {
            let hosting = NSHostingView(rootView: TrainerHistoryView(history: history))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Trainer History"
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        history.load()
        if let hosting = window?.contentView as? NSHostingView<TrainerHistoryView> {
            window?.setContentSize(hosting.fittingSize)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
