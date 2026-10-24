@testable import PrinterKit
import XCTest

final class FilamentControlTests: XCTestCase {
    func testFilamentMoveScriptIsSlowAndLimited() {
        XCTAssertEqual(FilamentMove.script(millimetres: 10), "M83\nG1 E10.0 F180")
        XCTAssertEqual(FilamentMove.script(millimetres: -10), "M83\nG1 E-10.0 F300")
        XCTAssertEqual(FilamentMove.script(millimetres: 5000), "M83\nG1 E100.0 F180", "never more than 100 mm in one go")
        XCTAssertEqual(FilamentMove.script(millimetres: -5000), "M83\nG1 E-100.0 F300")
    }

    func testSupportPerPrinterKind() {
        let moonraker = MoonrakerClient(connection: PrinterConnection(name: "U1", host: "127.0.0.1"))
        XCTAssertTrue(moonraker.filamentControl.extrude)
        XCTAssertFalse(moonraker.filamentControl.loadSlot)
        #if canImport(Network)
        let kobra = AnycubicLANClient(connection: PrinterConnection(name: "Kobra", host: "127.0.0.1", model: "kobraS1", kind: .anycubicLAN))
        XCTAssertTrue(kobra.filamentControl.loadSlot && kobra.filamentControl.unload && kobra.filamentControl.retract, "ACE feed commands")
        XCTAssertFalse(kobra.filamentControl.extrude, "no hot extrusion while idle in LAN mode")
        let bambu = BambuLANClient(connection: PrinterConnection(name: "P1S", host: "127.0.0.1", model: "bambuP1S", kind: .bambuLAN))
        XCTAssertTrue(bambu.filamentControl.loadSlot && bambu.filamentControl.unload && bambu.filamentControl.extrude)
        #endif
    }

    func testUnsupportedPrintersSayWhyInsteadOfDoingNothing() async {
        #if canImport(Network)
        let kobra = AnycubicLANClient(connection: PrinterConnection(name: "Kobra", host: "127.0.0.1", model: "kobraS1", kind: .anycubicLAN))
        do {
            try await kobra.extrude(millimetres: 10)
            XCTFail("must not pretend to work")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Vorschieben") || error.localizedDescription.contains("Leerlauf"), "\(error)")
        }
        #endif
    }
}
