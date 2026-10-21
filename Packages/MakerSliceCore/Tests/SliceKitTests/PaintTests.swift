@testable import SliceKit
import XCTest

final class PaintTests: XCTestCase {
    private let a = Vec3(0, 0, 0), b = Vec3(10, 0, 0), c = Vec3(0, 10, 0)

    func testUnsplitTriangleStates() throws {
        // 4 = extruder 1, 8 = extruder 2, "0C" (read backwards: C then 0) = extruder 3, "1C" = extruder 4, "0" = not painted.
        XCTAssertEqual(try XCTUnwrap(PaintDecoder.decode("4", a: a, b: b, c: c)).map(\.tool), [0])
        XCTAssertEqual(try XCTUnwrap(PaintDecoder.decode("8", a: a, b: b, c: c)).map(\.tool), [1])
        XCTAssertEqual(try XCTUnwrap(PaintDecoder.decode("0C", a: a, b: b, c: c)).map(\.tool), [2])
        XCTAssertEqual(try XCTUnwrap(PaintDecoder.decode("1C", a: a, b: b, c: c)).map(\.tool), [3])
        XCTAssertEqual(try XCTUnwrap(PaintDecoder.decode("0", a: a, b: b, c: c)).count, 0)
    }

    func testSplitTriangleKeepsItsPiecesAndColours() throws {
        // "4882": split on two sides (3 children); child 0 = extruder 1, children 1 and 2 = extruder 2.
        let facets = try XCTUnwrap(PaintDecoder.decode("4882", a: a, b: b, c: c))
        XCTAssertEqual(facets.map(\.tool).sorted(), [0, 1, 1])
        // Child 0 is the corner piece at the first vertex.
        let corner = try XCTUnwrap(facets.first { $0.tool == 0 })
        XCTAssertTrue([corner.a, corner.b, corner.c].contains(a))
        let area = facets.reduce(0.0) { $0 + abs($1.b.sub(by: $1.a).cross($1.c.sub(by: $1.a)).length) / 2 }
        XCTAssertEqual(area, 50, accuracy: 1e-9, "the pieces cover the whole triangle")
        // Four-way split: "4448" + "3" → children 0…3, reading order last to first.
        XCTAssertEqual(try XCTUnwrap(PaintDecoder.decode("44843", a: a, b: b, c: c)).count, 4)
    }

    func testMalformedTextIsRejected() {
        XCTAssertNil(PaintDecoder.decode("zz", a: a, b: b, c: c))
        XCTAssertNil(PaintDecoder.decode("2", a: a, b: b, c: c), "a split node without its children")
        XCTAssertNil(PaintDecoder.decode("44", a: a, b: b, c: c), "leftover digits")
    }

    /// A 3MF whose top face (and one side) are painted with extruder 2, as MakerWorld files are.
    private func paintedCube(topPaint: String?, sidePaint: String?) -> Data {
        let mesh = Fixtures.box(20, 20, 20, at: Vec3(100, 100, 0))
        var xml = "<?xml version=\"1.0\"?><model unit=\"millimeter\"><resources><object id=\"1\" type=\"model\"><mesh><vertices>"
        for v in mesh.vertices { xml += "<vertex x=\"\(v.x)\" y=\"\(v.y)\" z=\"\(v.z)\"/>" }
        xml += "</vertices><triangles>"
        for t in 0..<mesh.triangleCount {
            let i = (0..<3).map { Int(mesh.indices[t * 3 + $0]) }
            let v = i.map { mesh.vertices[$0] }
            var attr = ""
            if let topPaint, v.allSatisfy({ abs($0.z - 20) < 1e-9 }) { attr = " paint_color=\"\(topPaint)\"" }
            if let sidePaint, v.allSatisfy({ abs($0.x - 120) < 1e-9 }) { attr = " paint_color=\"\(sidePaint)\"" }
            xml += "<triangle v1=\"\(i[0])\" v2=\"\(i[1])\" v3=\"\(i[2])\"\(attr)/>"
        }
        xml += "</triangles></mesh></object></resources><build><item objectid=\"1\"/></build></model>"
        let config = ##"{"filament_colour":["#FFFFFF","#FF0000"],"filament_type":["PLA","PLA"]}"##
        return ZipArchive.write([("3D/3dmodel.model", Data(xml.utf8)), ("Metadata/project_settings.config", Data(config.utf8))])
    }

    func testPaintedTopSurfaceBecomesASecondColour() throws {
        let model = try ModelImporter.load(data: paintedCube(topPaint: "8", sidePaint: nil), fileName: "p.3mf")
        XCTAssertFalse(model.hasPaintedColors, "painting is understood, so there is no warning")
        XCTAssertTrue(model.isMultiColor)
        XCTAssertEqual(model.modelColors.map(\.tool), [0, 1])
        XCTAssertEqual(model.modelColors[1].colorHex, "#FF0000")
        XCTAssertEqual(model.objects[0].paint.count, 2)

        let s = PrintSettings(printer: .snapmakerU1)
        let layers = try Slicer(settings: s).slice(model.objects)
        for layer in layers {
            let tools = Set(layer.islands.map(\.tool))
            if layer.z < 18.5 { XCTAssertEqual(tools, [0], "below the painted top surface z=\(layer.z)") }
            if layer.z > 19.0 { XCTAssertEqual(tools, [1], "top shell is painted z=\(layer.z)") }
        }
    }

    func testPaintedSideWallReachesIntoTheObject() throws {
        let model = try ModelImporter.load(data: paintedCube(topPaint: nil, sidePaint: "8"), fileName: "p.3mf")
        let layers = try Slicer(settings: PrintSettings(printer: .snapmakerU1)).slice(model.objects)
        let middle = layers[layers.count / 2]
        XCTAssertEqual(Set(middle.islands.map(\.tool)), [0, 1], "both colours print on a painted side")
        // The coloured strip is narrow (about the wall thickness) and sits on the painted side (x = 120).
        let painted = middle.islands.first { $0.tool == 1 }!
        let xs = painted.extrusions.flatMap { $0.points.map(\.mmX) }
        XCTAssertGreaterThan(xs.min()!, 117.5)
        XCTAssertLessThan(xs.max()!, 120.5)
    }

    func testColourMapMovesPaintToAnotherSlot() throws {
        let model = try ModelImporter.load(data: paintedCube(topPaint: "8", sidePaint: nil), fileName: "p.3mf")
        let mapped = model.objects[0].applyingColorMap([1: 3])
        XCTAssertEqual(Set(mapped.paint.map(\.tool)), [3])
        XCTAssertEqual(mapped.allTools, [0, 3])
        XCTAssertThrowsError(try MeshCutter.cut(mapped, CutOptions(axis: .z, position: 10, connector: .none)))
    }
}

private extension Vec3 {
    func sub(by o: Vec3) -> Vec3 { self - o }
}
