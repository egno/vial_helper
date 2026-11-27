import Foundation
import Combine

final class KeymapModel: ObservableObject {
    @Published private(set) var file: VilFile?
    @Published private(set) var error: String?
    /// nil = show every layer.
    @Published var selectedLayer: Int?
    /// Mirrors `AppSettings.holdAloneLayer`.
    @Published var holdAloneSetting = AppSettings.holdAloneOff
    /// Keys exempt from the Chordal Hold same-hand rule, as `KeyPlacement.id` (row * 100 + col).
    /// Empty until fetched from the keyboard.
    @Published var chordalExempt: Set<Int> = []

    private(set) var geometry: KeyboardGeometry?
    private var loadedPath: String?
    private var loadedModified: Date?

    var layerCount: Int { file?.layers.count ?? 0 }
    /// Layers shown in the UI (empty ones and the hold-alone config layer are hidden).
    var visibleLayers: [Int] { (file?.nonEmptyLayers ?? []).filter { $0 != holdAloneLayer } }

    /// Resolved hold-alone config layer, nil when off or out of range.
    var holdAloneLayer: Int? {
        guard let file else { return nil }
        let n = holdAloneSetting == AppSettings.holdAloneLast ? file.layers.count - 1 : holdAloneSetting
        return n >= 0 && n < file.layers.count ? n : nil
    }

    /// The keymap as read from the keyboard (VialKeymapSource.swift). While it has one, `file`
    /// is that keymap (`file.isLive`); otherwise `file` is the `.vil` on disk.
    let live = VialLiveKeymap()
    /// Reading from the keyboard, or why its keymap is not the one shown; nil when there is nothing to say.
    @Published private(set) var liveNote: String?
    private var fileKeymap: VilFile?
    private var fileError: String?

    init() {
        live.onChange = { [weak self] in self?.publish() }
    }

    /// Re-reads the file when the path or its modification date changed, and has the keyboard's
    /// keymap re-read in the background (the overlay calls this every time it opens).
    func reloadIfNeeded(path: String, force: Bool = false) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attrs?[.modificationDate] as? Date
        if force || path != loadedPath || modified != loadedModified || fileKeymap == nil {
            loadedPath = path
            loadedModified = modified
            do {
                fileKeymap = try VilFile.load(path: path)
                fileError = nil
            } catch {
                fileKeymap = nil
                fileError = error.localizedDescription
            }
            // Matrix shape for a live read that cannot get the keyboard definition.
            live.fallback = fileKeymap.map(VialReader.Fallback.init(file:)) ?? VialReader.Fallback()
        }
        publish()
        live.refresh(force: force)
    }

    /// Shows the live keymap if there is one, else the file. Publishes only what changed.
    private func publish() {
        let shown = live.keymap ?? fileKeymap
        let newError = shown == nil ? (fileError ?? "Not loaded") : nil
        if shown != file {
            geometry = shown.map { KeyboardGeometry.make(for: $0) }
            file = shown
            if let f = shown, let s = selectedLayer, !f.nonEmptyLayers.contains(s), s != holdAloneLayer { selectedLayer = nil }
        }
        if newError != error { error = newError }
        if live.note != liveNote { liveNote = live.note }
    }

    func select(_ index: Int?) {
        guard let index else { selectedLayer = nil; return }
        // The hold-alone layer is hidden from the chips but can still be opened by its digit.
        guard visibleLayers.contains(index) || index == holdAloneLayer else { return }
        selectedLayer = index
    }

    func cycle(_ delta: Int) {
        let visible = visibleLayers
        guard !visible.isEmpty else { return }
        // Positions: 0 = all, 1...n = visible layers.
        let positions = visible.count + 1
        let current = selectedLayer.flatMap { visible.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let next = (current + delta + positions) % positions
        selectedLayer = next == 0 ? nil : visible[next - 1]
    }
}
