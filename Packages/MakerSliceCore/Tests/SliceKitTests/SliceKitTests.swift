import Foundation
@testable import SliceKit
import XCTest

enum Fixtures {
    /// Axis-aligned box from (0,0,0) to size, outward-facing triangles.
    static func box(_ sx: Double, _ sy: Double, _ sz: Double, at origin: Vec3 = .zero) -> TriangleMesh {
        let v = [
            Vec3(0, 0, 0), Vec3(sx, 0, 0), Vec3(sx, sy, 0), Vec3(0, sy, 0),
            Vec3(0, 0, sz), Vec3(sx, 0, sz), Vec3(sx, sy, sz), Vec3(0, sy, sz),
        ].map { $0 + origin }
        let idx: [UInt32] = [
            0, 2, 1, 0, 3, 2, // bottom
            4, 5, 6, 4, 6, 7, // top
            0, 1, 5, 0, 5, 4, // front
            1, 2, 6, 1, 6, 5, // right
            2, 3, 7, 2, 7, 6, // back
            3, 0, 4, 3, 4, 7, // left
        ]
        return TriangleMesh(vertices: v, indices: idx)
    }

    /// "T" shape: a pillar with a wide slab on top (needs support).
    static func tShape() -> TriangleMesh {
        var mesh = box(10, 10, 20, at: Vec3(20, 20, 0))
        mesh.append(box(50, 10, 4, at: Vec3(0, 20, 20)))
        return mesh
    }

    static func soup(_ mesh: TriangleMesh) -> [(Vec3, Vec3, Vec3)] {
        (0..<mesh.triangleCount).map { t in
            (mesh.vertices[Int(mesh.indices[t * 3])], mesh.vertices[Int(mesh.indices[t * 3 + 1])], mesh.vertices[Int(mesh.indices[t * 3 + 2])])
        }
    }
}

final class GeometryTests: XCTestCase {
    func testOffsetShrinksSquare() {
        let square = Polygons.rectangle(minX: 0, minY: 0, maxX: 10, maxY: 10)
        XCTAssertEqual(square.areaMM2, 100, accuracy: 0.01)
        XCTAssertEqual(square.offset(-1).areaMM2, 64, accuracy: 0.01)
    }

    func testDifferenceAndIntersection() {
        let a = Polygons.rectangle(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let b = Polygons.rectangle(minX: 5, minY: 0, maxX: 15, maxY: 10)
        XCTAssertEqual(a.difference(b).areaMM2, 50, accuracy: 0.01)
        XCTAssertEqual(a.intersection(b).areaMM2, 50, accuracy: 0.01)
        XCTAssertEqual(a.union(b).areaMM2, 150, accuracy: 0.01)
    }

    func testClipLines() {
        let a = Polygons.rectangle(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let lines = a.clip(lines: [[IntPoint(mmX: -5, mmY: 5), IntPoint(mmX: 15, mmY: 5)]])
        XCTAssertEqual(lines.count, 1)
        let length = lines[0][0].distance(to: lines[0][1]) / Units.perMM
        XCTAssertEqual(length, 10, accuracy: 0.01)
    }

    func testTransformCompose() {
        let t = Transform3D.translation(Vec3(1, 2, 3)).then(.scale(Vec3(2, 2, 2)))
        XCTAssertEqual(t.apply(Vec3(1, 1, 1)), Vec3(4, 6, 8))
        let r = Transform3D.rotationZ(.pi / 2).apply(Vec3(1, 0, 0))
        XCTAssertEqual(r.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.y, 1, accuracy: 1e-9)
    }

    func testLayFlatPutsLargestFaceDown() {
        // A tall thin plate standing up should end up lying down.
        let plate = Fixtures.box(40, 2, 30)
        let flat = plate.laidFlat()
        XCTAssertEqual(flat.boundingBox.size.z, 2, accuracy: 1e-6)
    }

    func testFormatDecimal() {
        XCTAssertEqual(formatDecimal(1.5, digits: 3), "1.5")
        XCTAssertEqual(formatDecimal(-0.00049, digits: 3), "0")
        XCTAssertEqual(formatDecimal(-2.0405, digits: 3), "-2.041")
        XCTAssertEqual(formatDecimal(0.012, digits: 5), "0.012")
        XCTAssertEqual(formatDecimal(120, digits: 3), "120")
    }
}

final class ImportTests: XCTestCase {
    func testBinarySTLRoundTrip() throws {
        let box = Fixtures.box(20, 10, 5)
        let data = STLReader.binaryData(for: box)
        let mesh = try STLReader.read(data)
        XCTAssertEqual(mesh.triangleCount, 12)
        XCTAssertEqual(mesh.vertices.count, 8)
        XCTAssertEqual(mesh.volume, 1000, accuracy: 0.01)
    }

    func testASCIISTL() throws {
        let stl = """
        solid test
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 1 0 0
              vertex 0 1 0
            endloop
          endfacet
        endsolid test
        """
        let mesh = try STLReader.read(Data(stl.utf8))
        XCTAssertEqual(mesh.triangleCount, 1)
    }

    func testZipRoundTrip() throws {
        let payload = Data(String(repeating: "MakerSlice ", count: 500).utf8)
        let zip = ZipArchive.write([("a.txt", payload), ("dir/b.bin", Data([1, 2, 3]))])
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(try archive.contents(of: "a.txt"), payload)
        XCTAssertEqual(try archive.contents(of: "/dir/b.bin"), Data([1, 2, 3]))
    }

    /// Mimics a Bambu Studio project: root model with components pointing into a
    /// sub-model, model_settings with extruder/plate, project settings JSON.
    func testBambuStyle3MF() throws {
        let box = Fixtures.box(10, 10, 10)
        let vertices = box.vertices.map { "<vertex x=\"\($0.x)\" y=\"\($0.y)\" z=\"\($0.z)\"/>" }.joined()
        let triangles = stride(from: 0, to: box.indices.count, by: 3).map {
            "<triangle v1=\"\(box.indices[$0])\" v2=\"\(box.indices[$0 + 1])\" v3=\"\(box.indices[$0 + 2])\"/>"
        }.joined()
        let sub = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>
          <object id="1" type="model"><mesh><vertices>\(vertices)</vertices><triangles>\(triangles)</triangles></mesh></object>
          <object id="2" type="model"><mesh><vertices>\(vertices)</vertices><triangles>\(triangles)</triangles></mesh></object>
         </resources>
        </model>
        """
        let root = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
         <!-- comment with <tags> inside -->
         <resources>
          <object id="5" type="model">
           <components>
            <component p:path="/3D/Objects/object_1.model" objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
            <component p:path="/3D/Objects/object_1.model" objectid="2" transform="1 0 0 0 1 0 0 0 1 0 0 5"/>
           </components>
          </object>
         </resources>
         <build>
          <item objectid="5" transform="1 0 0 0 1 0 0 0 1 100 100 0" printable="1"/>
         </build>
        </model>
        """
        let settings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config>
          <object id="5">
            <metadata key="name" value="Würfel &amp; Co"/>
            <metadata key="extruder" value="3"/>
            <part id="1" subtype="normal_part"><metadata key="name" value="body"/></part>
            <part id="2" subtype="modifier_part"><metadata key="name" value="mod"/></part>
          </object>
          <plate>
            <metadata key="plater_id" value="2"/>
            <model_instance>
              <metadata key="object_id" value="5"/>
              <metadata key="instance_id" value="0"/>
            </model_instance>
          </plate>
        </config>
        """
        let project = ##"{"layer_height":"0.16","wall_loops":"3","sparse_infill_density":"25%","filament_type":["PETG","PLA"],"filament_colour":["#FF0000","#00FF00"]}"##
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        </Relationships>
        """
        let zip = ZipArchive.write([
            ("_rels/.rels", Data(rels.utf8)),
            ("3D/3dmodel.model", Data(root.utf8)),
            ("3D/Objects/object_1.model", Data(sub.utf8)),
            ("Metadata/model_settings.config", Data(settings.utf8)),
            ("Metadata/project_settings.config", Data(project.utf8)),
        ])
        let model = try ModelImporter.load(data: zip, fileName: "cube.3mf")
        XCTAssertEqual(model.objects.count, 1)
        let object = model.objects[0]
        XCTAssertEqual(object.name, "Würfel & Co")
        XCTAssertEqual(object.tool, 2)
        XCTAssertEqual(object.plate, 2)
        // Modifier part must be skipped: only one 10 mm cube, moved to (100,100).
        XCTAssertEqual(object.mesh.triangleCount, 12)
        XCTAssertEqual(object.mesh.boundingBox.min, Vec3(100, 100, 0))
        XCTAssertEqual(model.projectSettings?.layerHeight, 0.16)
        XCTAssertEqual(model.projectSettings?.wallLoops, 3)
        XCTAssertEqual(model.projectSettings?.infillDensity ?? 0, 0.25, accuracy: 1e-9)

        var s = PrintSettings()
        s.apply(model.projectSettings!)
        XCTAssertEqual(s.layerHeight, 0.16)
        XCTAssertEqual(s.filaments[0].type, "PETG")
        XCTAssertEqual(s.filaments[1].color, "#00FF00")
    }
}

final class SlicerTests: XCTestCase {
    func testSliceBoxOutline() {
        let mesh = Fixtures.box(20, 10, 5)
        let slices = MeshSlicer.slice(mesh, at: [0.1, 2.5, 4.9, 6])
        XCTAssertEqual(slices[0].areaMM2, 200, accuracy: 0.01)
        XCTAssertEqual(slices[1].areaMM2, 200, accuracy: 0.01)
        XCTAssertEqual(slices[2].areaMM2, 200, accuracy: 0.01)
        XCTAssertTrue(slices[3].isEmpty)
    }

    func testSliceNonWeldedMeshAndHole() {
        // A frame: outer box minus inner box, built from a raw triangle soup.
        let outer = Fixtures.box(30, 30, 5)
        var inner = Fixtures.box(10, 10, 5, at: Vec3(10, 10, 0))
        // Flip inner box so it faces inward (it is a hole).
        for i in stride(from: 0, to: inner.indices.count, by: 3) { inner.indices.swapAt(i + 1, i + 2) }
        var mesh = TriangleMesh(vertices: [], indices: [])
        // Duplicate vertices per triangle (no welding) to emulate sloppy exporters.
        for (a, b, c) in Fixtures.soup(outer) + Fixtures.soup(inner) {
            let base = UInt32(mesh.vertices.count)
            mesh.vertices += [a, b, c]
            mesh.indices += [base, base + 1, base + 2]
        }
        let slice = MeshSlicer.slice(mesh, at: [2.5])[0]
        XCTAssertEqual(slice.areaMM2, 900 - 100, accuracy: 0.01)
    }

    func testFullSliceProducesValidGCode() throws {
        var settings = PrintSettings()
        settings.skirtLoops = 1
        let cube = ModelObject(name: "Cube", mesh: Fixtures.box(20, 20, 10))
        let arranged = try XCTUnwrap(PlateArranger.arrange([cube], bedSize: settings.bedSize))
        let box = arranged[0].mesh.boundingBox
        XCTAssertEqual(box.center.x, 135, accuracy: 0.01)
        XCTAssertEqual(box.min.z, 0, accuracy: 1e-9)

        let output = try SliceJob(name: "cube", objects: arranged, settings: settings).run()
        // 0.25 + n * 0.2 ≥ 10 → 50 layers
        XCTAssertEqual(output.layers.count, 50)
        XCTAssertEqual(output.layers.last!.z, 10.05, accuracy: 1e-6)

        let roles = Set(output.layers.flatMap { $0.islands.flatMap { $0.extrusions.map(\.role) } })
        XCTAssertTrue(roles.isSuperset(of: [.outerWall, .innerWall, .topSurface, .bottomSurface, .sparseInfill, .skirt]))

        let gcode = output.gcode
        XCTAssertTrue(gcode.contains("PRINT_START"))
        XCTAssertTrue(gcode.contains("PRINT_END"))
        XCTAssertTrue(gcode.contains("BED_MESH_CALIBRATE mesh_min="))
        XCTAssertTrue(gcode.contains("SET_PRINT_STATS_INFO TOTAL_LAYER=50 CURRENT_LAYER=50"))
        for bad in ["nan", "Xinf", "Yinf", "Einf", "X-inf", "Y-inf"] { XCTAssertFalse(gcode.contains(bad), bad) }

        // All extrusion moves stay on the bed and in the model's footprint (+skirt).
        var maxX = -Double.infinity, minX = Double.infinity, totalE = 0.0
        var inBody = false
        for line in gcode.split(separator: "\n") {
            if line == ";LAYER_CHANGE" { inBody = true }
            guard inBody, line.hasPrefix("G1 "), line.contains(" E") else { continue }
            for token in line.split(separator: " ") {
                if token.hasPrefix("X"), let x = Double(token.dropFirst()) { maxX = max(maxX, x); minX = min(minX, x) }
                if token.hasPrefix("E"), let e = Double(token.dropFirst()) { totalE += e }
            }
        }
        XCTAssertGreaterThan(minX, 125 - settings.skirtDistance - 1)
        XCTAssertLessThan(maxX, 145 + settings.skirtDistance + 1)

        // Extruded volume should be in the ballpark of the shell volume.
        let filamentVolume = totalE * Double.pi * 0.875 * 0.875
        XCTAssertGreaterThan(filamentVolume, 1200)
        XCTAssertLessThan(filamentVolume, 4000)
        XCTAssertGreaterThan(output.estimate.seconds, 300)
        XCTAssertEqual(output.estimate.toolChanges, 0)
    }

    func testMultiToolPrintChangesTools() throws {
        let a = ModelObject(name: "A", mesh: Fixtures.box(15, 15, 3), tool: 0)
        let b = ModelObject(name: "B", mesh: Fixtures.box(15, 15, 3), tool: 2)
        let arranged = try XCTUnwrap(PlateArranger.arrange([a, b], bedSize: 270))
        let output = try SliceJob(name: "two", objects: arranged, settings: PrintSettings()).run()
        XCTAssertTrue(output.gcode.contains("\nT2\n"))
        XCTAssertTrue(output.gcode.contains("SM_PRINT_PREEXTRUDE_FILAMENT INDEX=2"))
        // Each layer should need just one change thanks to tool ordering.
        XCTAssertEqual(output.estimate.toolChanges, output.layers.count)
        XCTAssertNotNil(output.estimate.filamentMM[2])
    }

    func testSupportUnderOverhang() throws {
        var settings = PrintSettings()
        settings.support = .buildPlateOnly
        settings.skirtLoops = 0
        let t = ModelObject(name: "T", mesh: Fixtures.tShape())
        let arranged = try XCTUnwrap(PlateArranger.arrange([t], bedSize: 270))
        let output = try SliceJob(name: "t", objects: arranged, settings: settings).run()
        let supportLayers = output.layers.filter { layer in
            layer.islands.contains { $0.extrusions.contains { $0.role == .support || $0.role == .supportInterface } }
        }
        XCTAssertGreaterThan(supportLayers.count, 80)
        // No support above the slab bottom.
        XCTAssertTrue(supportLayers.allSatisfy { $0.z <= 20.01 })

        settings.support = .off
        let none = try SliceJob(name: "t", objects: arranged, settings: settings).run()
        XCTAssertFalse(none.layers.contains { $0.islands.contains { $0.extrusions.contains { $0.role == .support } } })
    }

    func testOutsideBedIsRejected() {
        let obj = ModelObject(name: "Big", mesh: Fixtures.box(20, 20, 5, at: Vec3(260, 0, 0)))
        XCTAssertThrowsError(try Slicer(settings: PrintSettings()).slice([obj])) { error in
            XCTAssertEqual(error as? SliceError, .outsideBed("Big"))
        }
        XCTAssertNil(PlateArranger.arrange([ModelObject(name: "Huge", mesh: Fixtures.box(300, 20, 5))], bedSize: 270))
    }
}
