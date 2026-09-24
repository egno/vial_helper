import Foundation
import Combine

final class KeymapModel: ObservableObject {
    @Published private(set) var file: VilFile?
    @Published private(set) var error: String?
    /// nil = show every layer.
    @Published var selectedLayer: Int?

    private(set) var geometry: KeyboardGeometry?
    private var loadedPath: String?
    private var loadedModified: Date?

    var layerCount: Int { file?.layers.count ?? 0 }
    /// Layers shown in the UI (empty ones are hidden).
    var visibleLayers: [Int] { file?.nonEmptyLayers ?? [] }

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
            if let s = selectedLayer, !f.nonEmptyLayers.contains(s) { selectedLayer = nil }
        } catch {
            file = nil
            geometry = nil
            self.error = error.localizedDescription
        }
    }

    func select(_ index: Int?) {
        guard let index else { selectedLayer = nil; return }
        guard visibleLayers.contains(index) else { return }
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
