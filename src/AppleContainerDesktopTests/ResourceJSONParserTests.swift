import XCTest
@testable import AppleContainerDesktop

final class ResourceJSONParserTests: XCTestCase {
    func testParsesContainerListArrayIntoRows() throws {
        let output = """
        [
          {"configuration":{"id":"web","image":{"reference":"nginx:latest"}},"status":"running"},
          {"configuration":{"id":"worker","image":{"reference":"swift:latest"}},"state":"stopped"}
        ]
        """

        let rows = try ResourceJSONParser().parseList(output, kind: .containers)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].title, "web")
        XCTAssertEqual(rows[0].status, "running")
        XCTAssertEqual(rows[0].detail, "nginx:latest")
        XCTAssertEqual(rows[0].inspectIdentifier, "web")
        XCTAssertTrue(rows[0].searchableText.contains("nginx"))
    }

    func testParsesWrappedListArray() throws {
        let output = """
        {
          "images": [
            {"displayReference":"ghcr.io/example/app:latest","digest":"sha256:abc","size":"12MB"}
          ]
        }
        """

        let rows = try ResourceJSONParser().parseList(output, kind: .images)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "ghcr.io/example/app:latest")
        XCTAssertEqual(rows[0].detail, "sha256:abc")
    }

    func testPrettyJSONSortsKeys() {
        let pretty = ResourceJSONParser().prettyJSON("{\"b\":2,\"a\":1}")

        XCTAssertTrue(pretty.contains("\"a\" : 1"))
        XCTAssertTrue(pretty.contains("\"b\" : 2"))
    }
}
