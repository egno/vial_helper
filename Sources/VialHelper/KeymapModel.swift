import Foundation
import Combine

final class KeymapModel: ObservableObject {
    @Published private(set) var file: VilFile?
    @Published private(set) var error: String?
    /// nil = show every layer.
    @Published var selectedLayer: Int?
    /// Mirrors `AppSettings.holdAloneLayer`.
    @Published var holdAloneSetting = AppSettings.holdAloneOff

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

    /// Re-reads the file when the path or its modification date changed.
    func reloadIfNeeded(path: String, force: Bool = false) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attrs?[.modificationDate] as? Date
        if !force, path == loadedPath, modified == loadedModified, file != nil { return }
        loadedPath = path
        loadedModified = modified
        do {
            let f = try VilFile.load(path: path)
            geometry = KeyboardGeometry.make(for: f)
            file = f
            error = nil
            if let s = selectedLayer, !f.nonEmptyLayers.contains(s), s != holdAloneLayer { selectedLayer = nil }
        } catch {
            file = nil
            geometry = nil
            self.error = error.localizedDescription
        }
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
