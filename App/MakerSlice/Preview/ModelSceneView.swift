import SceneKit
import SliceKit
import SwiftUI

/// 3D view of the build plate with the arranged objects (orbit with one finger, zoom with two).
struct ModelSceneView: UIViewRepresentable {
    let objects: [ModelObject]
    let filaments: [Filament]
    let bedSize: Double
    /// Optional cut plane to visualise (axis, position in plate coordinates).
    var cutPlane: (CutAxis, Double)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.makeScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.pointOfView = context.coordinator.cameraNode
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(objects: objects, filaments: filaments, bedSize: bedSize, cutPlane: cutPlane)
    }

    final class Coordinator {
        let cameraNode = SCNNode()
        private let modelsNode = SCNNode()
        private let bedNode = SCNNode()
        private let planeNode = SCNNode()
        private var signature: [String] = []
        private var bedSignature = 0.0

        func makeScene() -> SCNScene {
            let scene = SCNScene()
            scene.rootNode.addChildNode(bedNode)
            scene.rootNode.addChildNode(modelsNode)
            scene.rootNode.addChildNode(planeNode)

            let camera = SCNCamera()
            camera.zFar = 3000
            camera.fieldOfView = 40
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 380
            scene.rootNode.addChildNode(ambient)
            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 850
            sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
            scene.rootNode.addChildNode(sun)
            return scene
        }

        private func buildBed(_ bedSize: Double) {
            guard bedSize != bedSignature else { return }
            bedSignature = bedSize
            bedNode.childNodes.forEach { $0.removeFromParentNode() }
            let half = Float(bedSize / 2)
            let bed = SCNBox(width: CGFloat(bedSize), height: 2, length: CGFloat(bedSize), chamferRadius: 2)
            bed.firstMaterial?.diffuse.contents = UIColor.systemGray4
            let plate = SCNNode(geometry: bed)
            plate.position = SCNVector3(0, -1.01, 0)
            bedNode.addChildNode(plate)
            for i in stride(from: -half, through: half, by: 25) {
                for horizontal in [true, false] {
                    let line = SCNBox(width: horizontal ? CGFloat(bedSize) : 0.35, height: 0.05,
                                      length: horizontal ? 0.35 : CGFloat(bedSize), chamferRadius: 0)
                    line.firstMaterial?.diffuse.contents = UIColor.systemGray2
                    let node = SCNNode(geometry: line)
                    node.position = horizontal ? SCNVector3(0, 0.01, i) : SCNVector3(i, 0.01, 0)
                    bedNode.addChildNode(node)
                }
            }
            cameraNode.position = SCNVector3(0, Float(bedSize) * 0.85, Float(bedSize) * 1.2)
            cameraNode.look(at: SCNVector3(0, 10, 0))
        }

        func update(objects: [ModelObject], filaments: [Filament], bedSize: Double, cutPlane: (CutAxis, Double)?) {
            buildBed(bedSize)
            updatePlane(cutPlane, objects: objects, bedSize: bedSize)
            let newSignature = objects.map { o in
                let b = o.boundingBox
                let color = filaments.isEmpty ? "" : filaments[min(o.tool, filaments.count - 1)].color
                return "\(o.id)-\(o.tool)-\(o.mesh.vertices.count)-\(o.volumes.count)-\(b.min.x)-\(b.min.y)-\(b.max.z)-\(color)"
            }
            guard newSignature != signature else { return }
            signature = newSignature
            modelsNode.childNodes.forEach { $0.removeFromParentNode() }
            for object in objects {
                let hex = filaments.isEmpty ? "#3D8BFF" : filaments[min(object.tool, filaments.count - 1)].color
                let color = UIColor(Color(hex: hex))
                modelsNode.addChildNode(Self.node(for: object.mesh, color: color, bedSize: bedSize))
                for volume in object.volumes where volume.kind == .add {
                    modelsNode.addChildNode(Self.node(for: volume.mesh, color: color, bedSize: bedSize))
                }
            }
        }

        private func updatePlane(_ cut: (CutAxis, Double)?, objects: [ModelObject], bedSize: Double) {
            planeNode.childNodes.forEach { $0.removeFromParentNode() }
            guard let cut else { return }
        let (axis, position) = cut
            var box = BoundingBox.empty
            objects.forEach { box.include($0.boundingBox) }
            guard !box.isEmpty else { return }
            let size = box.size
            let margin = 12.0
            let c = bedSize / 2
            let plane: SCNBox
            let pos: SCNVector3
            switch axis {
            case .z:
                plane = SCNBox(width: CGFloat(size.x + margin), height: 0.4, length: CGFloat(size.y + margin), chamferRadius: 0)
                pos = SCNVector3(Float(box.center.x - c), Float(position), Float(-(box.center.y - c)))
            case .x:
                plane = SCNBox(width: 0.4, height: CGFloat(size.z + margin), length: CGFloat(size.y + margin), chamferRadius: 0)
                pos = SCNVector3(Float(position - c), Float(box.center.z), Float(-(box.center.y - c)))
            case .y:
                plane = SCNBox(width: CGFloat(size.x + margin), height: CGFloat(size.z + margin), length: 0.4, chamferRadius: 0)
                pos = SCNVector3(Float(box.center.x - c), Float(box.center.z), Float(-(position - c)))
            }
            plane.firstMaterial?.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.35)
            plane.firstMaterial?.isDoubleSided = true
            let node = SCNNode(geometry: plane)
            node.position = pos
            planeNode.addChildNode(node)
        }

        /// Flat-shaded geometry; printer coordinates (Z up) mapped to SceneKit (Y up).
        static func node(for mesh: TriangleMesh, color: UIColor, bedSize: Double) -> SCNNode {
            let c = bedSize / 2
            var positions: [SCNVector3] = []
            var normals: [SCNVector3] = []
            positions.reserveCapacity(mesh.indices.count)
            normals.reserveCapacity(mesh.indices.count)
            for t in 0..<mesh.triangleCount {
                let n = mesh.faceNormal(t)
                let normal = SCNVector3(Float(n.x), Float(n.z), Float(-n.y))
                for k in 0..<3 {
                    let v = mesh.vertices[Int(mesh.indices[t * 3 + k])]
                    positions.append(SCNVector3(Float(v.x - c), Float(v.z), Float(-(v.y - c))))
                    normals.append(normal)
                }
            }
            let indices = (0..<Int32(positions.count)).map { $0 }
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
            )
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.lightingModel = .blinn
            material.isDoubleSided = true
            geometry.materials = [material]
            return SCNNode(geometry: geometry)
        }
    }
}
