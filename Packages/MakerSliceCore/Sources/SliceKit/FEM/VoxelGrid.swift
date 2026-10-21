import Foundation

/// The model as a grid of small cubes (voxels): the basis of the strength estimate.
struct VoxelGrid {
    let nx: Int, ny: Int, nz: Int
    /// Edge length of a voxel in mm.
    let h: Double
    /// Position (mm) of the grid's corner with the smallest coordinates.
    let origin: Vec3
    /// Index = (k · ny + j) · nx + i.
    var solid: [Bool]

    @inline(__always) func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
    var cellCount: Int { nx * ny * nz }
    var solidCount: Int { solid.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// Voxel containing a point (nil outside the grid).
    func voxel(containing p: Vec3) -> (Int, Int, Int)? {
        let i = Int(((p.x - origin.x) / h).rounded(.down)), j = Int(((p.y - origin.y) / h).rounded(.down)), k = Int(((p.z - origin.z) / h).rounded(.down))
        guard (0..<nx).contains(i), (0..<ny).contains(j), (0..<nz).contains(k) else { return nil }
        return (i, j, k)
    }

    func isSolid(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        (0..<nx).contains(i) && (0..<ny).contains(j) && (0..<nz).contains(k) && solid[index(i, j, k)]
    }

    /// Fills the cubes whose centre lies inside the mesh. About `targetElements` solid cubes are used.
    @_optimize(speed)
    static func make(mesh: TriangleMesh, targetElements: Int, isCancelled: () -> Bool = { false }) throws -> VoxelGrid {
        let box = mesh.boundingBox
        guard !box.isEmpty, mesh.triangleCount > 0 else { throw FEMError.emptyModel }
        let size = box.size
        let volume = max(mesh.volume, 1e-6)
        var h = max(0.4, cbrt(volume / Double(max(targetElements, 1000))))
        // Never create more than about 4 million cells (sparse parts in a large box).
        while (size.x / h + 1) * (size.y / h + 1) * (size.z / h + 1) > 4_000_000 { h *= 1.15 }
        let nx = max(1, Int((size.x / h).rounded(.up))), ny = max(1, Int((size.y / h).rounded(.up))), nz = max(1, Int((size.z / h).rounded(.up)))
        let origin = box.min
        var solid = [Bool](repeating: false, count: nx * ny * nz)

        let mids = (0..<nz).map { origin.z + (Double($0) + 0.5) * h }
        let layers = MeshSlicer.slice(mesh, at: mids)
        for k in 0..<nz {
            if isCancelled() { throw FEMError.cancelled }
            let polygons = layers[k]
            guard !polygons.isEmpty else { continue }
            // Edges of all outlines, in mm.
            var edges: [(Double, Double, Double, Double)] = []
            for path in polygons.paths where path.count > 2 {
                for n in 0..<path.count {
                    let a = path[n], b = path[(n + 1) % path.count]
                    edges.append((a.mmX, a.mmY, b.mmX, b.mmY))
                }
            }
            for j in 0..<ny {
                let y = origin.y + (Double(j) + 0.5) * h
                var xs: [Double] = []
                for (x1, y1, x2, y2) in edges where (y1 <= y) != (y2 <= y) {
                    xs.append(x1 + (y - y1) / (y2 - y1) * (x2 - x1))
                }
                xs.sort()
                var n = 0
                while n + 1 < xs.count {
                    let from = Int(((xs[n] - origin.x) / h - 0.5).rounded(.up)), to = Int(((xs[n + 1] - origin.x) / h - 0.5).rounded(.down))
                    if from <= to { for i in max(from, 0)...min(to, nx - 1) { solid[(k * ny + j) * nx + i] = true } }
                    n += 2
                }
            }
        }
        guard solid.contains(true) else { throw FEMError.emptyModel }
        return VoxelGrid(nx: nx, ny: ny, nz: nz, h: h, origin: origin, solid: solid)
    }
}

public enum FEMError: Error, LocalizedError, Equatable {
    case emptyModel
    case noFixedSupport
    case noLoad
    case regionNotFound(String)
    case notConnected
    case cancelled
    case notConverged

    public var errorDescription: String? {
        switch self {
        case .emptyModel: return "Das Modell ist zu klein oder leer für die Berechnung."
        case .noFixedSupport: return "Es ist keine feste Befestigung gewählt."
        case .noLoad: return "Es ist keine Last gewählt."
        case .regionNotFound(let what): return "Die gewählte Fläche („\(what)“) liegt nicht auf dem Modell."
        case .notConnected: return "Last und Befestigung sind nicht durch Material verbunden."
        case .cancelled: return "Berechnung abgebrochen."
        case .notConverged: return "Die Berechnung ist nicht zu einem stabilen Ergebnis gekommen."
        }
    }
}
