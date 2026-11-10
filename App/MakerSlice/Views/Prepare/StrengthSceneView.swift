import SceneKit
import simd
import SliceKit
import SwiftUI

/// The part alone in 3D: tap a surface to pick it, optionally coloured by the strength result.
struct StrengthSceneView: UIViewRepresentable {
    let mesh: TriangleMesh
    var fixed: [SurfaceRegion] = []
    var loads: [SurfaceRegion] = []
    /// A force arrow per load: the region it acts on and the force vector (N).
    var arrows: [(SurfaceRegion, Vec3)] = []
    var result: FEMResult?
    var onTap: (Int, Vec3) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.makeScene()
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.pointOfView = context.coordinator.cameraNode
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.update(mesh: mesh, fixed: fixed, loads: loads, arrows: arrows, result: result)
    }

    final class Coordinator: NSObject {
        let cameraNode = SCNNode()
        private let modelNode = SCNNode()
        weak var view: SCNView?
        var onTap: (Int, Vec3) -> Void = { _, _ in }
        private var center = Vec3.zero
        private var meshKey = 0
        private var colorKey = ""

        func makeScene() -> SCNScene {
            let scene = SCNScene()
            scene.rootNode.addChildNode(modelNode)
            let camera = SCNCamera()
            camera.zFar = 5000
            camera.fieldOfView = 40
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 500
            scene.rootNode.addChildNode(ambient)
            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 800
            sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
            scene.rootNode.addChildNode(sun)
            return scene
        }

        /// Printer coordinates (Z up) to SceneKit (Y up), centred.
        private static func point(_ v: Vec3, _ c: Vec3) -> SCNVector3 {
            SCNVector3(Float(v.x - c.x), Float(v.z - c.z), Float(-(v.y - c.y)))
        }

        func update(mesh: TriangleMesh, fixed: [SurfaceRegion], loads: [SurfaceRegion], arrows: [(SurfaceRegion, Vec3)], result: FEMResult?) {
            var box = BoundingBox.empty
            mesh.vertices.forEach { box.include($0) }
            let key = mesh.vertices.count &* 31 &+ mesh.indices.count &+ Int(box.size.x * 10) &* 7 &+ Int(box.size.z * 10)
            let colors = "\(fixed.map(\.triangles.count))/\(loads.map(\.triangles.count))/\(arrows.map { "\($0.1.x),\($0.1.y),\($0.1.z)" })/\(result.map { "\($0.safetyFactor)" } ?? "-")"
            guard key != meshKey || colors != colorKey else { return }
            let rebuild = key != meshKey
            meshKey = key
            colorKey = colors
            let center = box.center
            self.center = center
            if rebuild {
                let extent = max(box.size.x, box.size.y, box.size.z, 10)
                let distance = Float(extent * 2.4)
                cameraNode.position = SCNVector3(0, distance * 0.55, distance * 0.83)
                cameraNode.look(at: SCNVector3(0, 0, 0))
            }
            modelNode.childNodes.forEach { $0.removeFromParentNode() }

            let fixedKeys = Self.keys(fixed), loadKeys = Self.keys(loads)
            var positions: [SCNVector3] = [], normals: [SCNVector3] = [], colors4: [SIMD4<Float>] = []
            positions.reserveCapacity(mesh.indices.count)
            for t in 0..<mesh.triangleCount {
                let n = mesh.faceNormal(t)
                let tri = (0..<3).map { mesh.vertices[Int(mesh.indices[t * 3 + $0])] }
                let centroid = (tri[0] + tri[1] + tri[2]) * (1.0 / 3.0)
                var color = SIMD4<Float>(0.55, 0.62, 0.72, 1)
                if let result, let fi = result.surfaceFailureIndex(at: centroid, normal: n) { color = Self.heat(fi) }
                let k = Self.key(centroid)
                if fixedKeys.contains(k) { color = SIMD4<Float>(0.15, 0.4, 1, 1) }
                if loadKeys.contains(k) { color = SIMD4<Float>(1, 0.2, 0.2, 1) }
                let sn = SCNVector3(Float(n.x), Float(n.z), Float(-n.y))
                for c in 0..<3 {
                    positions.append(Self.point(tri[c], center))
                    normals.append(sn)
                    colors4.append(color)
                }
            }
            let colorData = Data(bytes: colors4, count: colors4.count * MemoryLayout<SIMD4<Float>>.stride)
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors4.count, usesFloatComponents: true,
                                                componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0,
                                                dataStride: MemoryLayout<SIMD4<Float>>.stride)
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals), colorSource],
                                       elements: [SCNGeometryElement(indices: (0..<Int32(positions.count)).map { $0 }, primitiveType: .triangles)])
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.isDoubleSided = true
            geometry.materials = [material]
            modelNode.addChildNode(SCNNode(geometry: geometry))
            let extent = max(box.size.x, box.size.y, box.size.z, 10)
            for (region, force) in arrows { modelNode.addChildNode(Self.arrow(region: region, force: force, center: center, length: extent * 0.3)) }
        }

        /// Red arrow showing a force: it ends on the surface when it pushes into the part, starts there when it pulls away.
        private static func arrow(region: SurfaceRegion, force: Vec3, center: Vec3, length: Double) -> SCNNode {
            var sum = Vec3.zero, count = 0.0
            for t in region.triangles { for p in t { sum = sum + p; count += 1 } }
            let centroid = count > 0 ? sum * (1 / count) : .zero
            let dir = force.normalized
            let start = dir.dot(region.normal) < -0.1 ? centroid - dir * length : centroid
            let sceneDir = SIMD3<Float>(Float(dir.x), Float(dir.z), Float(-dir.y))
            let node = SCNNode()
            node.position = point(start, center)
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(sceneDir))
            let color = UIColor.systemRed
            let shaft = SCNCylinder(radius: CGFloat(length * 0.035), height: CGFloat(length * 0.72))
            shaft.firstMaterial?.diffuse.contents = color
            shaft.firstMaterial?.lightingModel = .constant
            let shaftNode = SCNNode(geometry: shaft)
            shaftNode.position = SCNVector3(0, Float(length * 0.36), 0)
            let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(length * 0.1), height: CGFloat(length * 0.28))
            cone.firstMaterial?.diffuse.contents = color
            cone.firstMaterial?.lightingModel = .constant
            let coneNode = SCNNode(geometry: cone)
            coneNode.position = SCNVector3(0, Float(length * 0.86), 0)
            node.addChildNode(shaftNode)
            node.addChildNode(coneNode)
            return node
        }

        private static func key(_ v: Vec3) -> Int {
            Int((v.x * 100).rounded()) &* 73856093 ^ Int((v.y * 100).rounded()) &* 19349663 ^ Int((v.z * 100).rounded()) &* 83492791
        }

        private static func keys(_ regions: [SurfaceRegion]) -> Set<Int> {
            Set(regions.flatMap(\.triangles).filter { $0.count == 3 }.map { key(($0[0] + $0[1] + $0[2]) * (1.0 / 3.0)) })
        }

        /// 0 = green, 0.5 = yellow, 1 and more = red.
        private static func heat(_ fi: Double) -> SIMD4<Float> {
            let x = Float(min(max(fi, 0), 1))
            return x < 0.5 ? SIMD4<Float>(x * 2, 0.75, 0.2, 1) : SIMD4<Float>(1, 0.75 * (1 - (x - 0.5) * 2), 0.2, 1)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            if let hit = hits.first(where: { $0.node === modelNode.childNodes.first }) {
                let l = hit.localCoordinates
                onTap(hit.faceIndex, Vec3(Double(l.x) + center.x, Double(-l.z) + center.y, Double(l.y) + center.z))
            }
        }
    }
}
