import Foundation
@testable import MakerWorldKit
import XCTest

final class MakerWorldTests: XCTestCase {
    func testParseModelURLs() {
        let a = MakerWorld.parse(URL(string: "https://makerworld.com/en/models/2344501-printable-snap-lock-keyring")!)
        XCTAssertEqual(a?.designID, 2344501)
        XCTAssertNil(a?.profileID)
        let b = MakerWorld.parse(URL(string: "https://makerworld.com/de/models/2344501#profileId-2563198")!)
        XCTAssertEqual(b?.profileID, 2563198)
        XCTAssertEqual(MakerWorld.parse(URL(string: "https://makerworld.com.cn/zh/models/12345")!)?.designID, 12345)
        XCTAssertNil(MakerWorld.parse(URL(string: "https://example.com/models/1")!))
        XCTAssertNil(MakerWorld.parse(URL(string: "https://makerworld.com/en/collections/5")!))
    }

    func testParseDesign() throws {
        let json = """
        {"id": 2344501, "title": "Snap Keyring", "coverUrl": "https://img.example/c.jpg",
         "designCreator": {"name": "Maker"}, "likeCount": 12, "downloadCount": 340,
         "instances": [
           {"id": 1, "title": "0.2mm PLA", "isDefault": false, "prediction": 3600, "weight": 12.5,
            "instanceFilaments": [{"type": "PLA", "color": "#FFFFFF"}]},
           {"id": 2563198, "title": "Multi colour", "isDefault": true, "plateCnt": 2}
         ]}
        """
        let design = try XCTUnwrap(MakerWorldDesign(json: Data(json.utf8)))
        XCTAssertEqual(design.title, "Snap Keyring")
        XCTAssertEqual(design.creator, "Maker")
        XCTAssertEqual(design.profiles.count, 2)
        XCTAssertEqual(design.defaultProfile?.id, 2563198)
        XCTAssertEqual(design.profiles[0].materials, ["PLA #FFFFFF"])
        XCTAssertEqual(design.profiles[0].printTimeSeconds, 3600)
        XCTAssertEqual(design.profiles[1].plateCount, 2)
    }

    func testDesignFromNextData() {
        let next = #"{"props":{"pageProps":{"design":{"id":7,"title":"X","instances":[{"id":9,"isDefault":true}]}}}}"#
        XCTAssertEqual(MakerWorldDesign(nextData: next)?.defaultProfile?.id, 9)
    }

    func testDownloadResponse() {
        let r = MakerWorldDownload(json: Data(#"{"name":"model.3mf","url":"https://cdn.example/x.3mf?sig=1"}"#.utf8))
        XCTAssertEqual(r, .redirect(url: URL(string: "https://cdn.example/x.3mf?sig=1")!, fileName: "model.3mf"))
        XCTAssertEqual(MakerWorldDownload(json: Data("nope".utf8)), .unknown)
    }
}
