import Foundation

public enum CutAxis: String, CaseIterable, Codable, Sendable, Identifiable {
    case x, y, z
    public var id: String { rawValue }
    public var vector: Vec3 {
        switch self {
        case .x: return Vec3(1, 0, 0)
        case .y: return Vec3(0, 1, 0)
        case .z: return Vec3(0, 0, 1)
        }
    }
    public var displayName: String {
        switch self {
        case .x: return "Links / rechts (X)"
        case .y: return "Vorne / hinten (Y)"
        case .z: return "Oben / unten (Z)"
        }
    }
}

public enum ConnectorStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, pegs, dowels
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: return "Ohne Verbinder"
        case .pegs: return "Zapfen (angeformt)"
        case .dowels: return "Dübel (separat)"
        }
    }
    public var explanation: String {
        switch self {
        case .none: return "Glatte Schnittflächen, z. B. zum Kleben."
        case .pegs: return "Ein Teil bekommt Zapfen, das andere passende Löcher – einfach zusammenstecken."
        case .dowels: return "Beide Teile bekommen Löcher, dazu werden Dübel-Stifte mitgedruckt. Ideal bei seitlichen Schnitten."
        }
    }
}

public struct CutOptions: Sendable, Equatable {
    public var axis: CutAxis
    /// Cut position in plate coordinates (mm) along `axis`.
    public var position: Double
    public var connector: ConnectorStyle = .pegs
    /// 0 = choose automatically from the cut face size.
    public var connectorCount: Int = 0
    public var connectorDiameter: Double = 6
    /// Depth of each connector into one part, in mm.
    public var connectorDepth: Double = 6
    /// Gap between peg and hole, per side.
    public var clearance: Double = 0.2

    public init(axis: CutAxis, position: Double, connector: ConnectorStyle = .pegs) {
        self.axis = axis
        self.position = position
        self.connector = connector
    }
}

public enum CutError: Error, LocalizedError, Equatable {
    case outsideObject
    case emptyPart

    public var errorDescription: String? {
        switch self {
        case .outsideObject: return "Die Schnittebene liegt außerhalb des Objekts."
        case .emptyPart: return "Der Schnitt würde ein leeres Teil erzeugen."
        }
    }
}

/// Splits objects with a plane, closes the cut faces and adds connectors.
public enum MeshCutter {
    /// Cuts `object` in two. Returns [lower part, upper part] plus dowel pins,
    /// in plate coordinates (not yet arranged). Parts keep their orientation:
    /// after a horizontal cut the upper part already stands on its flat cut face.
    public static func cut(_ object: ModelObject, _ options: CutOptions) throws -> [ModelObject] {
        let pieces = try cutInPlace(object, options)
        return pieces.parts + pieces.extras
    }

    /// Cuts a too-large object into pieces that fit the printer.
    public static func autoSplit(_ object: ModelObject, bedSize: Double, maxHeight: Double,
                                 connector: ConnectorStyle = .dowels) throws -> [ModelObject] {
        let box = object.boundingBox
        var parts = [object]
        var extras: [ModelObject] = []
        let usable = (x: bedSize - 12, y: bedSize - 12, z: maxHeight - 2)
        for axis in CutAxis.allCases {
            let size: Double, limit: Double, start: Double
            switch axis {
            case .x: size = box.size.x; limit = usable.x; start = box.min.x
            case .y: size = box.size.y; limit = usable.y; start = box.min.y
            case .z: size = box.size.z; limit = usable.z; start = box.min.z
            }
            guard size > limit else { continue }
            let count = Int((size / limit).rounded(.up))
            for k in 1..<count {
                let position = start + size * Double(k) / Double(count)
                var next: [ModelObject] = []
                for part in parts {
                    let b = part.boundingBox
                    let lo: Double, hi: Double
                    switch axis {
                    case .x: lo = b.min.x; hi = b.max.x
                    case .y: lo = b.min.y; hi = b.max.y
                    case .z: lo = b.min.z; hi = b.max.z
                    }
                    guard position > lo + 1, position < hi - 1 else { next.append(part); continue }
                    var options = CutOptions(axis: axis, position: position, connector: connector)
                    options.connectorCount = 0
                    let result = try cutInPlace(part, options)
                    next += result.parts
                    extras += result.extras
                }
                parts = next
            }
        }
        for i in parts.indices { parts[i].name = "\(object.name) – Teil \(i + 1)" }
        return parts + extras
    }

    // MARK: - Implementation

    struct Pieces {
        var parts: [ModelObject]
        var extras: [ModelObject]
    }

    static func cutInPlace(_ object: ModelObject, _ o: CutOptions) throws -> Pieces {
        let axis = o.axis.vector
        let toLocal = Transform3D.rotationAligning(axis, to: Vec3(0, 0, 1))
        let toWorld = toLocal.inverseRotation
        let local = object.mesh.transformed(toLocal)
        let c = o.position
        let box = local.boundingBox
        guard c > box.min.z + 0.2, c < box.max.z - 0.2 else { throw CutError.outsideObject }

        var lower: [(Vec3, Vec3, Vec3)] = []
        var upper: [(Vec3, Vec3, Vec3)] = []
        split(local, at: c, lower: &lower, upper: &upper)

        // Close both halves with the cross-section.
        let section = MeshSlicer.sliceLayer(local, triangles: (0..<Int32(local.triangleCount)).map { $0 }, z: c)
        for tri in section.triangulated() {
            var pts = tri.map { Vec3($0.mmX, $0.mmY, c) }
            let ccw = (pts[1] - pts[0]).cross(pts[2] - pts[0]).z > 0
            if !ccw { pts.swapAt(1, 2) }
            lower.append((pts[0], pts[1], pts[2]))   // faces +z
            upper.append((pts[0], pts[2], pts[1]))   // faces −z
        }
        guard !lower.isEmpty, !upper.isEmpty else { throw CutError.emptyPart }

        var lowerObj = ModelObject(name: "\(object.name) – Teil 1", mesh: TriangleMesh(soup: lower), tool: object.tool,
                                   plate: object.plate)
        var upperObj = ModelObject(name: "\(object.name) – Teil 2", mesh: TriangleMesh(soup: upper), tool: object.tool,
                                   plate: object.plate)
        var extras: [ModelObject] = []

        // Connectors.
        if o.connector != .none {
            let r = o.connectorDiameter / 2
            let points = connectorPositions(section, radius: r, count: o.connectorCount)
            let depth = min(o.connectorDepth, (c - box.min.z) - 1, (box.max.z - c) - 1)
            if depth >= 2 {
                for (i, p) in points.enumerated() {
                    switch o.connector {
                    case .pegs:
                        lowerObj.volumes.append(ObjectVolume(kind: .add,
                            mesh: cylinder(center: p, radius: r, z0: c - 0.01, z1: c + depth - 0.3)))
                        upperObj.volumes.append(ObjectVolume(kind: .subtract,
                            mesh: cylinder(center: p, radius: r + o.clearance, z0: c - 0.01, z1: c + depth)))
                    case .dowels:
                        lowerObj.volumes.append(ObjectVolume(kind: .subtract,
                            mesh: cylinder(center: p, radius: r + o.clearance, z0: c - depth, z1: c + 0.01)))
                        upperObj.volumes.append(ObjectVolume(kind: .subtract,
                            mesh: cylinder(center: p, radius: r + o.clearance, z0: c - 0.01, z1: c + depth)))
                        let pinLength = 2 * depth - 0.8
                        extras.append(ModelObject(name: "\(object.name) – Dübel \(i + 1)",
                                                  mesh: cylinder(center: (0, 0), radius: r, z0: 0, z1: pinLength),
                                                  tool: object.tool, plate: object.plate))
                    case .none:
                        break
                    }
                }
            }
        }

        // Existing volumes go with the part they belong to.
        for volume in object.volumes {
            let localVolume = volume.mesh.transformed(toLocal)
            let center = localVolume.boundingBox.center.z
            if center < c {
                lowerObj.volumes.append(ObjectVolume(kind: volume.kind, mesh: localVolume))
            } else {
                upperObj.volumes.append(ObjectVolume(kind: volume.kind, mesh: localVolume))
            }
        }
        return Pieces(parts: [lowerObj.transformed(toWorld), upperObj.transformed(toWorld)], extras: extras)
    }

    /// Splits every triangle at z = c into the lower and upper soup.
    static func split(_ mesh: TriangleMesh, at c: Double, lower: inout [(Vec3, Vec3, Vec3)], upper: inout [(Vec3, Vec3, Vec3)]) {
        func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
            // Deterministic order so shared edges give identical points.
            let (u, v) = (a.z < b.z || (a.z == b.z && (a.x, a.y) < (b.x, b.y))) ? (a, b) : (b, a)
            let f = (c - u.z) / (v.z - u.z)
            return Vec3(u.x + (v.x - u.x) * f, u.y + (v.y - u.y) * f, c)
        }
        for t in 0..<mesh.triangleCount {
            let v = (0..<3).map { mesh.vertices[Int(mesh.indices[t * 3 + $0])] }
            let above = v.map { $0.z >= c }
            let count = above.filter { $0 }.count
            if count == 3 { upper.append((v[0], v[1], v[2])); continue }
            if count == 0 { lower.append((v[0], v[1], v[2])); continue }
            // Rotate so the lone vertex is first, keeping the winding.
            let lone = count == 1 ? above.firstIndex(of: true)! : above.firstIndex(of: false)!
            let a = v[lone], b = v[(lone + 1) % 3], d = v[(lone + 2) % 3]
            let ab = cross(a, b), ad = cross(a, d)
            let loneSide: (Vec3, Vec3, Vec3) = (a, ab, ad)
            let quad1: (Vec3, Vec3, Vec3) = (ab, b, d)
            let quad2: (Vec3, Vec3, Vec3) = (ab, d, ad)
            if count == 1 {
                upper.append(loneSide); lower.append(quad1); lower.append(quad2)
            } else {
                lower.append(loneSide); upper.append(quad1); upper.append(quad2)
            }
        }
        lower.removeAll { degenerate($0) }
        upper.removeAll { degenerate($0) }
    }

    private static func degenerate(_ t: (Vec3, Vec3, Vec3)) -> Bool {
        (t.1 - t.0).cross(t.2 - t.0).length < 1e-9
    }

    /// Spreads connectors over the cut face, keeping them clear of the edges.
    static func connectorPositions(_ section: Polygons, radius: Double, count requested: Int) -> [(Double, Double)] {
        let safe = section.offset(-(radius + 2.5))
        guard !safe.isEmpty, let box = safe.boundingBox else { return [] }
        let area = section.areaMM2
        let count = requested > 0 ? requested : (area < 700 ? 1 : area < 4000 ? 2 : area < 12000 ? 3 : 4)
        let spanX = box.max.mmX - box.min.mmX, spanY = box.max.mmY - box.min.mmY
        let cx = (box.min.mmX + box.max.mmX) / 2, cy = (box.min.mmY + box.max.mmY) / 2
        var candidates: [(Double, Double)] = []
        if count == 1 {
            candidates = [(cx, cy)]
        } else {
            for i in 0..<count {
                let f = (Double(i) + 0.5) / Double(count)
                candidates.append(spanX >= spanY ? (box.min.mmX + spanX * f, cy) : (cx, box.min.mmY + spanY * f))
            }
        }
        // Snap each candidate into the safe area.
        let vertices = safe.paths.flatMap { $0 }
        var result: [(Double, Double)] = []
        for (x, y) in candidates {
            let p = IntPoint(mmX: x, mmY: y)
            if safe.contains(p) {
                result.append((x, y))
            } else if let nearest = vertices.min(by: { $0.distanceSquared(to: p) < $1.distanceSquared(to: p) }) {
                result.append((nearest.mmX, nearest.mmY))
            }
        }
        // Drop overlapping connectors.
        var spaced: [(Double, Double)] = []
        for p in result where !spaced.contains(where: { hypot($0.0 - p.0, $0.1 - p.1) < radius * 3 }) {
            spaced.append(p)
        }
        return spaced
    }

    /// Closed cylinder along Z.
    public static func cylinder(center: (Double, Double), radius: Double, z0: Double, z1: Double, segments: Int = 32) -> TriangleMesh {
        var vertices: [Vec3] = [Vec3(center.0, center.1, z0), Vec3(center.0, center.1, z1)]
        var indices: [UInt32] = []
        for i in 0..<segments {
            let a = Double(i) / Double(segments) * 2 * .pi
            let x = center.0 + radius * cos(a), y = center.1 + radius * sin(a)
            vertices.append(Vec3(x, y, z0))
            vertices.append(Vec3(x, y, z1))
        }
        for i in 0..<segments {
            let b0 = UInt32(2 + i * 2), t0 = b0 + 1
            let b1 = UInt32(2 + ((i + 1) % segments) * 2), t1 = b1 + 1
            indices += [0, b1, b0]          // bottom (faces −z)
            indices += [1, t0, t1]          // top (faces +z)
            indices += [b0, b1, t1, b0, t1, t0] // side
        }
        return TriangleMesh(vertices: vertices, indices: indices)
    }
}

extension Transform3D {
    /// Inverse of a pure rotation (transpose of the linear part).
    var inverseRotation: Transform3D {
        Transform3D(m: [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8], 0, 0, 0])
    }
}
