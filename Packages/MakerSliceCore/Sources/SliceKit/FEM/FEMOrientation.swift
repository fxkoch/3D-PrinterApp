import Foundation

/// One way to stand the part on the bed, with what it does to strength, supports and height.
public struct OrientationOption: Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    /// Rotation to apply to the part (nil = as it is now).
    public var rotation: Transform3D?
    public var result: FEMResult
    public var safetyRatio: Double
    /// Overhanging surface (steeper than 45° and not on the bed), mm² – needs support material.
    public var overhangArea: Double
    public var needsSupport: Bool
    /// Print height in this position, mm.
    public var height: Double
    public var isCurrent: Bool
    public var isRecommended = false
}

public enum FEMOrientation {
    /// Tries the six ways to stand the part on a face of its bounding box and rates them with the given load case.
    /// Recommended: the strongest position that does not need clearly more support than the current one.
    @_optimize(speed)
    public static func rank(mesh: TriangleMesh, material: FEMMaterial, setup: FEMPrintSetup, loadCase: FEMLoadCase, baseline: FEMResult? = nil,
                            options: FEMOptions = .fast, progress: (String, Double) -> Void = { _, _ in },
                            isCancelled: () -> Bool = { false }) throws -> [OrientationOption] {
        let quarter = Double.pi / 2
        let candidates: [(String, Transform3D?)] = [
            ("Wie jetzt", nil),
            ("Auf den Kopf gestellt", .rotationX(.pi)),
            ("Auf die Vorderseite gelegt", .rotationX(quarter)),
            ("Auf die Rückseite gelegt", .rotationX(-quarter)),
            ("Auf die rechte Seite gelegt", .rotationY(quarter)),
            ("Auf die linke Seite gelegt", .rotationY(-quarter)),
        ]
        var rows: [OrientationOption] = []
        var reference = baseline?.safetyFactor
        for (n, (name, rotation)) in candidates.enumerated() {
            progress(name, Double(n) / Double(candidates.count))
            if isCancelled() { throw FEMError.cancelled }
            let m = rotation.map { mesh.transformed($0) } ?? mesh
            let lc = rotation.map { loadCase.transformed($0) } ?? loadCase
            let r: FEMResult
            if rotation == nil, let baseline { r = baseline } else {
                guard let run = try? FEMAnalysis.run(mesh: m, material: material, setup: setup, loadCase: lc, options: options, isCancelled: isCancelled) else { continue }
                r = run
            }
            if rotation == nil { reference = r.safetyFactor }
            let (overhang, total) = overhangArea(m)
            rows.append(OrientationOption(name: name, rotation: rotation, result: r, safetyRatio: 1, overhangArea: overhang,
                                          needsSupport: overhang > 0.02 * max(total, 1), height: m.boundingBox.size.z, isCurrent: rotation == nil))
        }
        guard let base = reference, base > 0 else { return rows }
        for i in rows.indices { rows[i].safetyRatio = rows[i].result.safetyFactor / base }
        let current = rows.first { $0.isCurrent }
        let allowed = max((current?.overhangArea ?? 0) * 1.5, 0.05 * overhangArea(mesh).total)
        if let best = rows.filter({ $0.overhangArea <= allowed }).max(by: { $0.safetyRatio < $1.safetyRatio }), !best.isCurrent, best.safetyRatio >= 1.1,
           let i = rows.firstIndex(where: { $0.id == best.id }) {
            rows[i].isRecommended = true
        }
        return rows.sorted { $0.safetyRatio > $1.safetyRatio }
    }

    /// Area of faces that hang over (normal more than 45° below horizontal) and do not touch the bed, and the total area.
    static func overhangArea(_ mesh: TriangleMesh) -> (overhang: Double, total: Double) {
        let minZ = mesh.boundingBox.min.z
        var overhang = 0.0, total = 0.0
        for t in 0..<mesh.triangleCount {
            let a = mesh.vertices[Int(mesh.indices[t * 3])], b = mesh.vertices[Int(mesh.indices[t * 3 + 1])], c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
            let cross = (b - a).cross(c - a)
            let area = cross.length / 2
            total += area
            guard area > 0 else { continue }
            let nz = cross.z / (2 * area)
            let z = (a.z + b.z + c.z) / 3
            if nz < -0.7071, z > minZ + 0.3 { overhang += area }
        }
        return (overhang, total)
    }
}
