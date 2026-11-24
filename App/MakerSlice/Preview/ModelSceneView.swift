import SceneKit
import SliceKit
import SwiftUI

/// 3D view of the build plate with the arranged objects (orbit with one finger, zoom with two).
/// With a `selection`, an object is picked by tapping it and moved by dragging it with one finger.
struct ModelSceneView: UIViewRepresentable {
    let objects: [ModelObject]
    let filaments: [Filament]
    let bedSize: Double
    /// Optional cut plane to visualise (axis, position in plate coordinates).
    var cutPlane: (CutAxis, Double)?
    /// The picked object; nil binding = the view only shows.
    var selection: Binding<ModelObject.ID?>?
    /// Objects drawn with a red footprint (they overlap another one).
    var overlapping: Set<ModelObject.ID> = []
    /// A dragged object was let go: move it by (dx, dy) mm on the bed.
    var onMove: ((ModelObject.ID, Double, Double) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let coordinator = context.coordinator
        coordinator.parent = self
        view.scene = coordinator.makeScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.pointOfView = coordinator.cameraNode
        if selection != nil {
            coordinator.view = view
            let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
            view.addGestureRecognizer(tap)
            let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = coordinator
            view.addGestureRecognizer(pan)
            coordinator.objectPan = pan
            // The camera's own drag waits until it is clear that the finger is not moving the picked object.
            DispatchQueue.main.async { coordinator.letObjectPanGoFirst() }
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(objects: objects, filaments: filaments, bedSize: bedSize, cutPlane: cutPlane)
        context.coordinator.highlight(selected: selection?.wrappedValue, overlapping: overlapping)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ModelSceneView?
        weak var view: SCNView?
        weak var objectPan: UIPanGestureRecognizer?
        let cameraNode = SCNNode()
        private let modelsNode = SCNNode()
        private let bedNode = SCNNode()
        private let planeNode = SCNNode()
        private var signature: [String] = []
        private var framedIDs: [UUID] = []
        private var bedSignature = 0.0
        private var objectNodes: [UUID: SCNNode] = [:]
        private var objects: [ModelObject] = []
        private var bedSize = 270.0
        private var highlighted: (UUID?, Set<UUID>)?

        // Dragging
        private var dragID: UUID?
        private var dragStart: SCNVector3?
        private var dragPlaneY: Float = 0
        private var dragOrigin = SCNVector3Zero
        private var dragRange: (x: ClosedRange<Double>, y: ClosedRange<Double>) = (0...0, 0...0)
        private var dragDelta: (dx: Double, dy: Double) = (0, 0)

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
            frameCamera(on: BoundingBox.empty, bedSize: bedSize)
            framedIDs = [] // re-frame the objects on the new bed
            signature = []
        }

        /// Points the camera at the objects (or the whole bed when empty), keeping the bed in view for context.
        private func frameCamera(on box: BoundingBox, bedSize: Double) {
            let c = bedSize / 2
            var target = SCNVector3(0, 10, 0)
            var distance = Float(bedSize) * 1.45
            if !box.isEmpty {
                let size = box.size
                let extent = max(size.x, size.y, size.z, 40)
                target = SCNVector3(Float(box.center.x - c), Float(size.z / 2), Float(-(box.center.y - c)))
                distance = Float(min(extent * 2.6 + 30, bedSize * 1.45))
            }
            cameraNode.position = SCNVector3(target.x, target.y + distance * 0.55, target.z + distance * 0.83)
            cameraNode.look(at: target)
        }

        func update(objects: [ModelObject], filaments: [Filament], bedSize: Double, cutPlane: (CutAxis, Double)?) {
            self.objects = objects
            self.bedSize = bedSize
            buildBed(bedSize)
            updatePlane(cutPlane, objects: objects, bedSize: bedSize)
            let newSignature = objects.map { o in
                let b = o.boundingBox
                let colors = filaments.isEmpty ? "" : o.allTools.sorted().map { filaments[min($0, filaments.count - 1)].color }.joined()
                let multi = "\(o.parts.count)/\(o.paint.count)/\(o.colorChanges.map { "\($0.z):\($0.tool)" })"
                return "\(o.id)-\(o.tool)-\(o.mesh.vertices.count)-\(o.volumes.count)-\(b.min.x)-\(b.min.y)-\(b.max.x)-\(b.max.y)-\(b.max.z)-\(colors)-\(multi)"
            }
            guard newSignature != signature else { return }
            signature = newSignature
            // Re-frame when the set of objects changes (new model, cut, duplicate), not on recolouring or moving.
            let ids = objects.map(\.id)
            if ids != framedIDs {
                framedIDs = ids
                var box = BoundingBox.empty
                objects.forEach { box.include($0.boundingBox) }
                frameCamera(on: box, bedSize: bedSize)
            }
            modelsNode.childNodes.forEach { $0.removeFromParentNode() }
            objectNodes = [:]
            highlighted = nil
            for object in objects {
                // One node per object (moved as a whole while dragging); every colour of it in its slot's colour.
                let container = SCNNode()
                container.name = object.id.uuidString
                for surface in object.displaySurfaces() {
                    let hex = filaments.isEmpty ? "#3D8BFF" : filaments[min(surface.tool, filaments.count - 1)].color
                    container.addChildNode(Self.node(for: surface.mesh, color: UIColor(Color(hex: hex)), bedSize: bedSize))
                }
                modelsNode.addChildNode(container)
                objectNodes[object.id] = container
            }
        }

        /// Marks the picked object (blue footprint, slightly lit) and overlapping ones (red footprint).
        func highlight(selected: UUID?, overlapping: Set<UUID>) {
            if let h = highlighted, h.0 == selected, h.1 == overlapping { return }
            highlighted = (selected, overlapping)
            for object in objects {
                guard let container = objectNodes[object.id] else { continue }
                container.childNode(withName: "footprint", recursively: false)?.removeFromParentNode()
                let isSelected = object.id == selected
                for child in container.childNodes {
                    child.geometry?.firstMaterial?.emission.contents = isSelected ? UIColor.systemBlue.withAlphaComponent(0.22) : UIColor.black
                }
                let overlaps = overlapping.contains(object.id)
                guard isSelected || overlaps else { continue }
                let b = object.boundingBox
                let c = bedSize / 2
                let box = SCNBox(width: CGFloat(b.size.x + 4), height: 0.3, length: CGFloat(b.size.y + 4), chamferRadius: 1.5)
                box.firstMaterial?.diffuse.contents = (overlaps ? UIColor.systemRed : UIColor.systemBlue).withAlphaComponent(0.4)
                box.firstMaterial?.lightingModel = .constant
                let footprint = SCNNode(geometry: box)
                footprint.name = "footprint"
                footprint.position = SCNVector3(Float(b.center.x - c), 0.2, Float(-(b.center.y - c)))
                container.addChildNode(footprint)
            }
        }

        // MARK: Picking and dragging

        func letObjectPanGoFirst() {
            guard let view, let objectPan else { return }
            for g in view.gestureRecognizers ?? [] where g !== objectPan && g is UIPanGestureRecognizer {
                g.require(toFail: objectPan)
            }
        }

        /// The object under a point of the view, with the touched point in the scene.
        private func object(at point: CGPoint) -> (id: UUID, world: SCNVector3)? {
            guard let view else { return nil }
            let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {
                    if let name = n.name, let id = UUID(uuidString: name), objectNodes[id] != nil { return (id, hit.worldCoordinates) }
                    node = n.parent
                }
            }
            return nil
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let selection = parent?.selection else { return }
            // An object picks it, the empty bed lets go.
            selection.wrappedValue = object(at: g.location(in: g.view)).map(\.id)
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === objectPan else { return true }
            guard let selected = parent?.selection?.wrappedValue, parent?.onMove != nil,
                  let hit = object(at: g.location(in: g.view)), hit.id == selected else { return false }
            return true
        }

        @objc func panned(_ g: UIPanGestureRecognizer) {
            let point = g.location(in: g.view)
            switch g.state {
            case .began:
                guard let hit = object(at: point), let node = objectNodes[hit.id],
                      let object = objects.first(where: { $0.id == hit.id }) else { return }
                dragID = hit.id
                dragPlaneY = hit.world.y
                dragStart = planePoint(point, y: dragPlaneY)
                dragOrigin = node.position
                dragDelta = (0, 0)
                // The object stays on the bed.
                let b = object.boundingBox
                dragRange = (min(0, -b.min.x)...max(0, bedSize - b.max.x), min(0, -b.min.y)...max(0, bedSize - b.max.y))
            case .changed:
                guard let id = dragID, let node = objectNodes[id], let start = dragStart,
                      let p = planePoint(point, y: dragPlaneY) else { return }
                let dx = min(max(Double(p.x - start.x), dragRange.x.lowerBound), dragRange.x.upperBound)
                let dy = min(max(Double(-(p.z - start.z)), dragRange.y.lowerBound), dragRange.y.upperBound)
                dragDelta = (dx, dy)
                node.position = SCNVector3(dragOrigin.x + Float(dx), dragOrigin.y, dragOrigin.z - Float(dy))
            case .ended:
                guard let id = dragID, let node = objectNodes[id] else { return }
                let (dx, dy) = dragDelta
                dragID = nil
                if abs(dx) < 0.2, abs(dy) < 0.2 {
                    node.position = dragOrigin
                    return
                }
                // The object is rebuilt at its new place; should nothing change, it jumps back.
                signature = []
                parent?.onMove?(id, dx, dy)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak node, origin = dragOrigin] in
                    if let node, node.parent != nil { node.position = origin }
                }
            default:
                if let id = dragID { objectNodes[id]?.position = dragOrigin }
                dragID = nil
            }
        }

        /// Where the ray under a screen point meets the horizontal plane at height `y`.
        private func planePoint(_ point: CGPoint, y: Float) -> SCNVector3? {
            guard let view else { return nil }
            let near = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
            let far = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
            let dir = SCNVector3(far.x - near.x, far.y - near.y, far.z - near.z)
            guard abs(dir.y) > 1e-5 else { return nil }
            let t = (y - near.y) / dir.y
            guard t > 0 else { return nil }
            return SCNVector3(near.x + dir.x * t, y, near.z + dir.z * t)
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
