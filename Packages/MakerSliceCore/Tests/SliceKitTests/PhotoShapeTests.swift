@testable import SliceKit
import XCTest

final class PhotoShapeTests: XCTestCase {
    /// White background, dark filled circle (or the opposite with `invert`).
    private func circleImage(size: Int = 200, radius: Double = 70, invert: Bool = false, hole: Double = 0) -> GrayImage {
        var px = [Float](repeating: invert ? 0.05 : 0.95, count: size * size)
        let c = Double(size) / 2
        for y in 0..<size { for x in 0..<size {
            let d = ((Double(x) - c) * (Double(x) - c) + (Double(y) - c) * (Double(y) - c)).squareRoot()
            if d < radius && d >= hole { px[y * size + x] = invert ? 0.95 : 0.05 }
        } }
        return GrayImage(width: size, height: size, pixels: px)
    }

    private func edgeUse(_ mesh: TriangleMesh) -> [UInt64: Int] {
        var use: [UInt64: Int] = [:]
        for t in 0..<mesh.triangleCount { for e in 0..<3 {
            let a = mesh.indices[t * 3 + e], b = mesh.indices[t * 3 + (e + 1) % 3]
            use[UInt64(min(a, b)) << 32 | UInt64(max(a, b)), default: 0] += 1
        } }
        return use
    }

    func testDarkCircleBecomesAWatertightDiscOfTheRightSize() throws {
        var o = PhotoShape.Options()
        o.size = 50; o.thickness = 4
        let mesh = try PhotoShape.mesh(circleImage(), options: o)
        let size = mesh.boundingBox.size
        XCTAssertEqual(size.x, 50, accuracy: 1.5)
        XCTAssertEqual(size.y, 50, accuracy: 1.5)
        XCTAssertEqual(size.z, 4, accuracy: 1e-6)
        XCTAssertEqual(mesh.volume, Double.pi * 25 * 25 * 4, accuracy: Double.pi * 25 * 25 * 4 * 0.06)
        XCTAssertTrue(edgeUse(mesh).values.allSatisfy { $0 == 2 }, "every edge belongs to exactly two triangles")
        XCTAssertGreaterThan(MeshRepair.signedVolume(mesh), 0, "outward normals")
    }

    func testBrightObjectOnDarkBackgroundGivesTheSameShape() throws {
        var o = PhotoShape.Options()
        o.size = 50; o.thickness = 4
        let a = try PhotoShape.mesh(circleImage(), options: o), b = try PhotoShape.mesh(circleImage(invert: true), options: o)
        XCTAssertEqual(a.volume, b.volume, accuracy: a.volume * 0.03, "polarity is detected from the border")
    }

    func testKeyRingHoleAddsALoopAndRemovesMaterial() throws {
        var o = PhotoShape.Options()
        o.size = 50; o.thickness = 3
        let plain = try PhotoShape.mesh(circleImage(), options: o)
        o.keyRingHole = true; o.holeDiameter = 5
        let ring = try PhotoShape.mesh(circleImage(), options: o)
        let paths = MeshSlicer.slice(ring, at: [1.5])[0].paths
        XCTAssertGreaterThanOrEqual(paths.count, 2, "outer outline and the hole")
        XCTAssertTrue(edgeUse(ring).values.allSatisfy { $0 == 2 })
        XCTAssertLessThan(abs(ring.volume - plain.volume), plain.volume * 0.25)
        XCTAssertGreaterThan(ring.boundingBox.size.y, plain.boundingBox.size.y - 0.1, "the boss can extend the top")
    }

    func testRingWithRealHoleKeepsTheHoleButSmallDustIsFilled() throws {
        var o = PhotoShape.Options()
        o.size = 50; o.thickness = 3
        let ring = try PhotoShape.mesh(circleImage(hole: 30), options: o)
        XCTAssertGreaterThanOrEqual(MeshSlicer.slice(ring, at: [1.5])[0].paths.count, 2, "a big hole stays")
        var dusty = circleImage()
        for i in 0..<5 { dusty.pixels[(100 + i) * 200 + 100] = 0.95 }   // a few light pixels inside the dark disc
        let filled = try PhotoShape.mesh(dusty, options: o)
        XCTAssertEqual(MeshSlicer.slice(filled, at: [1.5])[0].paths.count, 1, "dust inside is filled")
    }

    func testReliefFollowsTheBrightness() throws {
        // Left dark → right bright.
        let w = 120, h = 80
        var px = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y * w + x] = Float(x) / Float(w - 1) } }
        var o = PhotoShape.Options()
        o.size = 60; o.thickness = 1; o.mode = .relief(depth: 3, darkIsHigh: false); o.smoothing = 0
        let mesh = try PhotoShape.mesh(GrayImage(width: w, height: h, pixels: px), options: o)
        let box = mesh.boundingBox
        XCTAssertEqual(box.size.z, 4, accuracy: 0.3, "base 1 + depth 3 at the brightest side")
        let highs = mesh.vertices.filter { $0.z > 3.5 }, lows = mesh.vertices.filter { $0.z < 1.5 && $0.z > 0.9 }
        XCTAssertGreaterThan(highs.map(\.x).min() ?? 0, box.center.x, "high side is the bright (right) side")
        XCTAssertLessThan(lows.map(\.x).max() ?? 100, box.center.x, "low side is the dark (left) side")
        XCTAssertTrue(edgeUse(mesh).values.allSatisfy { $0 == 2 })
    }

    func testPhotoWithoutAnObjectIsReportedNotCrashing() {
        let flat = GrayImage(width: 50, height: 50, pixels: [Float](repeating: 0.5, count: 2500))
        XCTAssertThrowsError(try PhotoShape.mesh(flat))
    }

    func testSubjectMaskFromTheSystemIsUsedWhenGiven() throws {
        var image = circleImage()
        var mask = [Float](repeating: 0, count: 200 * 200)
        for y in 40..<100 { for x in 40..<100 { mask[y * 200 + x] = 1 } }   // a square, not the circle
        image.subject = mask
        var o = PhotoShape.Options()
        o.size = 40; o.thickness = 2
        let mesh = try PhotoShape.mesh(image, options: o)
        XCTAssertEqual(mesh.boundingBox.size.x / mesh.boundingBox.size.y, 1, accuracy: 0.08)
        XCTAssertEqual(mesh.volume, 40 * 40 * 2, accuracy: 40 * 40 * 2 * 0.12, "a square outline")
    }
}
