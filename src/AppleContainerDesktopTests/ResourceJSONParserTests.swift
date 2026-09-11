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

    func testParsesCurrentContainerMetadataWithoutFlatteningStatus() throws {
        let row = try ResourceFixtures.row(ResourceFixtures.container, kind: .containers)
        let container = try XCTUnwrap(row.container)
        XCTAssertEqual(row.id, "web")
        XCTAssertEqual(row.status, "running")
        XCTAssertTrue(container.isRunning)
        XCTAssertEqual(container.ports?.map(\.displayValue), [
            "127.0.0.1:8080 -> 80/tcp", "[::1]:9000-9001 -> 8000-8001/udp"
        ])
        XCTAssertEqual(container.mounts?.first?.source, "site-data")
        XCTAssertEqual(container.mounts?.first?.readOnly, true)
        XCTAssertEqual(container.mounts?.last?.kind, "Bind mount")
        XCTAssertEqual(container.allocatedCPUs, 2)
        XCTAssertEqual(container.memoryLimitBytes, 1_073_741_824)
        XCTAssertEqual(container.networks?.first?.ipv6Address, "fd00::2/64")
        XCTAssertEqual(container.command?.displayValue, "/bin/sh -c 'echo ready'")
        XCTAssertNotNil(container.createdAt)
        XCTAssertNotNil(container.startedAt)
        XCTAssertNotEqual(container.createdAt, container.startedAt)
        XCTAssertTrue(row.searchableText.contains("8080"))
    }

    func testCurrentImageUsesCanonicalReferenceAndVariantContentSize() throws {
        let row = try ResourceFixtures.row(ResourceFixtures.image, kind: .images)
        let image = try XCTUnwrap(row.image)
        XCTAssertEqual(row.inspectIdentifier, "registry.example:5000/team/web:dev")
        XCTAssertEqual(row.id, row.inspectIdentifier)
        XCTAssertEqual(image.reference.repository, "registry.example:5000/team/web")
        XCTAssertEqual(image.reference.tag, "dev")
        XCTAssertEqual(image.digest, "sha256:index")
        XCTAssertEqual(image.sizeBytes, 10_000_000)
        XCTAssertEqual(image.runtimeVariants?.count, 2)
        XCTAssertNotNil(image.createdAt)
        XCTAssertEqual(image.usage, .unavailable)
    }

    func testSingleImageObjectDoesNotBecomeItsVariantArray() throws {
        let rows = try ResourceJSONParser().parseList(ResourceFixtures.image, kind: .images)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.image?.reference.tag, "dev")
    }

    func testMissingOptionalMetadataIsNotInvented() throws {
        let container = try XCTUnwrap(ResourceFixtures.row(#"{"configuration":{"id":"new"},"status":{"state":"stopped"}}"#, kind: .containers).container)
        XCTAssertNil(container.startedAt)
        XCTAssertNil(container.createdAt)
        XCTAssertNil(container.ports)
        XCTAssertNil(container.mounts)
        XCTAssertEqual(container.state, "stopped")
        let image = try XCTUnwrap(ResourceFixtures.row(#"{"configuration":{"name":"alpine","creationDate":"1970-01-01T00:00:00Z","descriptor":{"size":512}},"variants":[]}"#, kind: .images).image)
        XCTAssertNil(image.createdAt)
        XCTAssertNil(image.sizeBytes)
        XCTAssertNil(image.reference.tag)
    }

    func testKnownEmptyConfigurationIsDistinctFromMissingMetadata() throws {
        let row = try ResourceFixtures.row(#"{"id":"new","publishedPorts":[],"mounts":[],"networks":[],"state":"stopped"}"#, kind: .containers)
        XCTAssertEqual(row.container?.ports, [])
        XCTAssertEqual(row.container?.mounts, [])
        XCTAssertEqual(row.container?.networks, [])
    }

    func testInvalidPayloadsFailRatherThanInventingResources() {
        for (input, kind) in [
            ("", ResourceKind.images), ("42", .containers), ("[null]", .images),
            (#"[{"configuration":{}}]"#, .containers),
            (#"[{"id":"digest-only-without-a-reference","variants":[]}]"#, .images)
        ] {
            XCTAssertThrowsError(try ResourceJSONParser().parseList(input, kind: kind))
        }
    }

    func testInvalidPortRangesAreUnavailable() throws {
        let input = ResourceFixtures.container.replacingOccurrences(of: "\"count\": 2", with: "\"count\": 65536")
        let row = try ResourceFixtures.row(input, kind: .containers)
        XCTAssertNil(row.container?.ports)
    }

    func testVariantSizesDeduplicateAndRejectIncompleteOrOverflowingTotals() throws {
        let base = try XCTUnwrap(ResourceFixtures.row(ResourceFixtures.image, kind: .images).image)
        var image = base
        let arm = try XCTUnwrap(image.variants?.first)
        image.variants?.append(arm)
        XCTAssertEqual(image.sizeBytes, 10_000_000)
        image.variants?[0].sizeBytes = nil
        XCTAssertNil(image.sizeBytes)
        image = base
        image.variants?[0].sizeBytes = Int64.max
        XCTAssertNil(image.sizeBytes)
    }
}
