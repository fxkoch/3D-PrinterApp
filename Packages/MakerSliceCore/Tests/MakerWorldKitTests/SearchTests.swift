import Foundation
@testable import MakerWorldKit
import XCTest

final class SearchTests: XCTestCase {
    func testPrintablesParsingSkipsPaid() throws {
        let json = #"{"data":{"searchPrints2":{"items":[{"id":"1","name":"Free","slug":"free","price":null,"premium":false,"likesCount":5,"downloadCount":9,"image":{"filePath":"media/a.png"},"user":{"publicUsername":"me"}},{"id":"2","name":"Paid","slug":"paid","price":3.5,"premium":false},{"id":"3","name":"Club","slug":"club","price":null,"premium":true}]}}}"#
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let results = PrintablesClient.parseSearch(obj)
        XCTAssertEqual(results.map(\.title), ["Free"])
        XCTAssertEqual(results[0].imageURL?.absoluteString, "https://media.printables.com/media/a.png")
        XCTAssertEqual(results[0].pageURL?.absoluteString, "https://www.printables.com/model/1-free")
    }

    func testMakerWorldSearchParsing() {
        let json = #"{"total":2,"hits":[{"id":11,"title":"Vase","cover":"https://x/c.jpg","likeCount":3,"designCreator":{"name":"Ann"}},{"id":12,"title":"Clip"}]}"#
        let r = MakerWorld.parseSearch(Data(json.utf8))
        XCTAssertEqual(r.map(\.modelID), ["11", "12"])
        XCTAssertEqual(r[0].author, "Ann")
        XCTAssertEqual(MakerWorld.parseSearch(Data(#"{"data":{"list":[{"design":{"id":5,"title":"Nested"}}]}}"#.utf8)).first?.title, "Nested")
        XCTAssertTrue(MakerWorld.searchPath("").contains("navKey=Trending"))
        XCTAssertTrue(MakerWorld.searchPath("cable clip").contains("keyword=cable%20clip"))
    }

    /// Talks to the real Printables API; only runs when LIVE_NETWORK=1.
    func testPrintablesLive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_NETWORK"] == "1")
        let client = PrintablesClient()
        let results = try await client.search("benchy", order: .popular, limit: 5)
        XCTAssertFalse(results.isEmpty)
        let files = try await client.files(modelID: "3161")
        let stl = try XCTUnwrap(files.first)
        let data = try await client.download(stl, modelID: "3161")
        XCTAssertGreaterThan(data.count, 1_000_000)
    }
}
