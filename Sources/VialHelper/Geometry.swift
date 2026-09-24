import Foundation

/// Where a matrix position sits physically, in key units.
struct KeyPlacement: Identifiable {
    var row: Int
    var col: Int
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat = 1
    var height: CGFloat = 1
    var rotation: Double = 0

    var id: Int { row * 100 + col }
    var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
}

struct KeyboardGeometry {
    var keys: [KeyPlacement]
    var size: CGSize
    /// Anchor points (unit coordinates) for encoder legends, one per encoder.
    var encoderAnchors: [CGPoint]
    var isSplit: Bool

    /// Picks a geometry for a matrix. Recognises the splitkb Aurora Corne / crkbd (3x6+3 per half,
    /// stored as 8 rows x 6 columns) and falls back to a plain (optionally mirrored) grid.
    static func make(for file: VilFile) -> KeyboardGeometry {
        let rows = file.rows, cols = file.cols
        if rows == 8, cols == 6, looksLikeCorne(file.layers[0]) {
            return corne()
        }
        if rows >= 2, rows % 2 == 0, cols <= 8 {
            return genericSplit(rows: rows, cols: cols, layer: file.layers[0])
        }
        return grid(rows: rows, cols: cols, layer: file.layers[0])
    }

    private static func looksLikeCorne(_ layer: [[String]]) -> Bool {
        func thumbRow(_ r: Int) -> Bool {
            let row = layer[r]
            return row[0] == "-1" && row[1] == "-1" && row[2] == "-1"
        }
        return thumbRow(3) && thumbRow(7)
    }

    // MARK: Corne (3x6+3, mirrored halves, matrix columns counted from the outer edge)

    static func corne() -> KeyboardGeometry {
        let stagger: [CGFloat] = [0.3, 0.3, 0.1, 0.0, 0.1, 0.2]
        var left: [KeyPlacement] = []
        for r in 0..<3 {
            for c in 0..<6 {
                left.append(KeyPlacement(row: r, col: c, x: CGFloat(c), y: CGFloat(r) + stagger[c]))
            }
        }
        left.append(KeyPlacement(row: 3, col: 3, x: 3.5, y: 3.45, rotation: 0))
        left.append(KeyPlacement(row: 3, col: 4, x: 4.55, y: 3.55, rotation: 12))
        left.append(KeyPlacement(row: 3, col: 5, x: 5.65, y: 3.8, rotation: 25))

        // Distance between the inner main columns. The rotated inner thumb keys overhang the
        // main block by ~0.8u each, so this is about as tight as the halves can get.
        let gap: CGFloat = 1.8
        let total = 6 * 2 + gap

        let right = left.map { k -> KeyPlacement in
            var m = k
            m.row = k.row + 4
            m.x = total - k.x - k.width
            m.rotation = -k.rotation
            return m
        }
        return KeyboardGeometry(
            keys: left + right,
            size: CGSize(width: total, height: 5.0),
            encoderAnchors: [CGPoint(x: 1.5, y: 4.0), CGPoint(x: total - 1.5, y: 4.0)],
            isSplit: true
        )
    }

    // MARK: Generic

    static func genericSplit(rows: Int, cols: Int, layer: [[String]]) -> KeyboardGeometry {
        let half = rows / 2
        let gap: CGFloat = 1.0
        let total = CGFloat(cols) * 2 + gap
        var keys: [KeyPlacement] = []
        for r in 0..<rows {
            for c in 0..<cols where layer[r][c] != "-1" {
                if r < half {
                    keys.append(KeyPlacement(row: r, col: c, x: CGFloat(c), y: CGFloat(r)))
                } else {
                    keys.append(KeyPlacement(row: r, col: c, x: total - CGFloat(c) - 1, y: CGFloat(r - half)))
                }
            }
        }
        return KeyboardGeometry(
            keys: keys,
            size: CGSize(width: total, height: CGFloat(half) + 0.6),
            encoderAnchors: [CGPoint(x: 1.5, y: CGFloat(half) + 0.3), CGPoint(x: total - 1.5, y: CGFloat(half) + 0.3)],
            isSplit: true
        )
    }

    static func grid(rows: Int, cols: Int, layer: [[String]]) -> KeyboardGeometry {
        var keys: [KeyPlacement] = []
        for r in 0..<rows {
            for c in 0..<cols where layer[r][c] != "-1" {
                keys.append(KeyPlacement(row: r, col: c, x: CGFloat(c), y: CGFloat(r)))
            }
        }
        return KeyboardGeometry(
            keys: keys,
            size: CGSize(width: CGFloat(cols), height: CGFloat(rows) + 0.6),
            encoderAnchors: [CGPoint(x: CGFloat(cols) / 2, y: CGFloat(rows) + 0.3)],
            isSplit: false
        )
    }
}
