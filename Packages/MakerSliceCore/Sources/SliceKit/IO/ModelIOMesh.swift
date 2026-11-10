#if canImport(ModelIO)
import Foundation
import ModelIO
import simd

/// Reads the geometry of USDZ/OBJ/PLY files (e.g. from photogrammetry) into a `TriangleMesh` in millimetres, Z up.
public enum ModelIOMesh {
    public enum LoadError: LocalizedError {
        case noGeometry
        public var errorDescription: String? { "Die Datei enthält keine Dreiecksflächen." }
    }

    /// `unitsToMillimetres`: 1000 for metres (USDZ from Object Capture). `yUp` turns Y-up files into the printer's Z-up.
    public static func load(url: URL, unitsToMillimetres: Double = 1000, yUp: Bool = true) throws -> TriangleMesh {
        let asset = MDLAsset(url: url)
        var out = TriangleMesh()
        for object in asset.childObjects(of: MDLMesh.self) {
            guard let mesh = object as? MDLMesh else { continue }
            var world = matrix_identity_float4x4
            var node: MDLObject? = mesh
            while let n = node { world = (n.transform?.matrix ?? matrix_identity_float4x4) * world; node = n.parent }
            guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
            let base = UInt32(out.vertices.count)
            for i in 0..<mesh.vertexCount {
                let p = positions.dataStart.advanced(by: i * positions.stride).assumingMemoryBound(to: Float.self)
                let w = world * SIMD4<Float>(p[0], p[1], p[2], 1)
                let (x, y, z) = (Double(w.x), Double(w.y), Double(w.z))
                out.vertices.append(yUp ? Vec3(x, -z, y) * unitsToMillimetres : Vec3(x, y, z) * unitsToMillimetres)
            }
            let flips = yUp   // the Y-up → Z-up turn keeps the handedness, no flip needed; kept explicit for clarity
            _ = flips
            for case let sub as MDLSubmesh in mesh.submeshes ?? [] where sub.geometryType == .triangles {
                let buffer = sub.indexBuffer(asIndexType: .uInt32)
                let map = buffer.map()
                let pointer = map.bytes.assumingMemoryBound(to: UInt32.self)
                for i in 0..<sub.indexCount { out.indices.append(base + pointer[i]) }
            }
        }
        guard !out.indices.isEmpty else { throw LoadError.noGeometry }
        return out
    }
}
#endif
