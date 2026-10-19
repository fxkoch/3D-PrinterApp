import SceneKit
import SliceKit
import SwiftUI

/// 3D view of the build plate with the arranged objects (orbit with one finger, zoom with two).
struct ModelSceneView: UIViewRepresentable {
    let objects: [ModelObject]
    let filaments: [Filament]
    let bedSize: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.makeScene(bedSize: bedSize)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3(0, 20, 0)
        view.pointOfView = context.coordinator.cameraNode
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(objects: objects, filaments: filaments, bedSize: bedSize)
    }

    final class Coordinator {
        let cameraNode = SCNNode()
        private let modelsNode = SCNNode()
        private var signature: [String] = []

        func makeScene(bedSize: Double) -> SCNScene {
            let scene = SCNScene()
            let half = Float(bedSize / 2)

            let bed = SCNBox(width: CGFloat(bedSize), height: 2, length: CGFloat(bedSize), chamferRadius: 2)
            bed.firstMaterial?.diffuse.contents = UIColor(white: 0.22, alpha: 1)
            let bedNode = SCNNode(geometry: bed)
            bedNode.position = SCNVector3(0, -1.01, 0)
            scene.rootNode.addChildNode(bedNode)

            // Grid every 30 mm.
            let gridNode = SCNNode()
            for i in stride(from: -half, through: half, by: 30) {
                for horizontal in [true, false] {
                    let line = SCNBox(width: horizontal ? CGFloat(bedSize) : 0.4, height: 0.05,
                                      length: horizontal ? 0.4 : CGFloat(bedSize), chamferRadius: 0)
                    line.firstMaterial?.diffuse.contents = UIColor(white: 0.4, alpha: 1)
                    let node = SCNNode(geometry: line)
                    node.position = horizontal ? SCNVector3(0, 0.01, i) : SCNVector3(i, 0.01, 0)
                    gridNode.addChildNode(node)
                }
            }
            scene.rootNode.addChildNode(gridNode)
            scene.rootNode.addChildNode(modelsNode)

            let camera = SCNCamera()
            camera.zFar = 3000
            camera.fieldOfView = 40
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, Float(bedSize) * 0.9, Float(bedSize) * 1.25)
            cameraNode.look(at: SCNVector3(0, 10, 0))
            scene.rootNode.addChildNode(cameraNode)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 350
            scene.rootNode.addChildNode(ambient)
            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 900
            sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
            scene.rootNode.addChildNode(sun)
            return scene
        }

        func update(objects: [ModelObject], filaments: [Filament], bedSize: Double) {
            let newSignature = objects.map { o in
                let b = o.mesh.boundingBox
                return "\(o.id)-\(o.tool)-\(o.mesh.vertices.count)-\(b.min.x)-\(b.min.y)-\(b.max.z)-\(filaments[min(o.tool, filaments.count - 1)].color)"
            }
            guard newSignature != signature else { return }
            signature = newSignature
            modelsNode.childNodes.forEach { $0.removeFromParentNode() }
            for object in objects {
                let color = UIColor(Color(hex: filaments[min(object.tool, filaments.count - 1)].color))
                modelsNode.addChildNode(Self.node(for: object.mesh, color: color, bedSize: bedSize))
            }
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
