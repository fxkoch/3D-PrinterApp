import Foundation

/// A piece of an object's surface and the slot whose colour it shows in the 3D preview.
public struct ColorSurface: Sendable {
    public var tool: Int
    public var mesh: TriangleMesh
}

extension ModelObject {
    /// The object's surface split by colour: main body (with colour changes cut at their heights), coloured parts,
    /// connector pegs, and painted areas as thin overlays.
    public func displaySurfaces() -> [ColorSurface] {
        var result: [ColorSurface] = []

        // Main body, cut at the colour changes.
        if colorChanges.isEmpty {
            result.append(ColorSurface(tool: tool, mesh: mesh))
        } else {
            var remaining = TriangleMesh.soup(of: mesh)
            var current = tool
            for change in colorChanges.sorted(by: { $0.z < $1.z }) {
                var lower: [(Vec3, Vec3, Vec3)] = [], upper: [(Vec3, Vec3, Vec3)] = []
                MeshCutter.split(TriangleMesh(soup: remaining), at: change.z, lower: &lower, upper: &upper)
                if !lower.isEmpty { result.append(ColorSurface(tool: current, mesh: TriangleMesh(soup: lower))) }
                remaining = upper
                current = change.tool
            }
            if !remaining.isEmpty { result.append(ColorSurface(tool: current, mesh: TriangleMesh(soup: remaining))) }
        }
        for volume in volumes where volume.kind == .add { result.append(ColorSurface(tool: tool, mesh: volume.mesh)) }
        for part in parts { result.append(ColorSurface(tool: part.tool, mesh: part.mesh)) }

        // Painted triangles lie on the surface; lift them a hair so they cover the base colour.
        if !paint.isEmpty {
            var byTool: [Int: [(Vec3, Vec3, Vec3)]] = [:]
            for f in paint {
                let n = (f.b - f.a).cross(f.c - f.a)
                let length = n.length
                guard length > 1e-12 else { continue }
                let lift = Vec3(n.x / length * 0.03, n.y / length * 0.03, n.z / length * 0.03)
                byTool[f.tool, default: []].append((f.a + lift, f.b + lift, f.c + lift))
            }
            for tool in byTool.keys.sorted() { result.append(ColorSurface(tool: tool, mesh: TriangleMesh(soup: byTool[tool]!))) }
        }
        return result
    }
}

extension TriangleMesh {
    static func soup(of mesh: TriangleMesh) -> [(Vec3, Vec3, Vec3)] {
        (0..<mesh.triangleCount).map { t in
            (mesh.vertices[Int(mesh.indices[t * 3])], mesh.vertices[Int(mesh.indices[t * 3 + 1])], mesh.vertices[Int(mesh.indices[t * 3 + 2])])
        }
    }
}
