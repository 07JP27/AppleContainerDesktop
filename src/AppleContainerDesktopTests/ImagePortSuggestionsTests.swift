import XCTest
@testable import AppleContainerDesktop

final class ImagePortSuggestionsTests: XCTestCase {
    static let imageJSON = """
    {
      "configuration": {"name": "registry.example:5000/web:dev"},
      "variants": [
        {"platform": {"os": "linux", "architecture": "arm64", "variant": "v8"},
         "config": {"config": {"ExposedPorts": {"80/tcp": {}, "53/udp": {}, "8080/tcp": {}}}}},
        {"platform": {"os": "linux", "architecture": "amd64"},
         "config": {"config": {"ExposedPorts": {"80/tcp": {}, "9090/tcp": {}}}}},
        {"platform": {"os": "unknown", "architecture": "unknown"},
         "config": {"config": {"ExposedPorts": {"9999/tcp": {}}}}}
      ]
    }
    """

    func testDeclaredPortsAreTypedDeduplicatedSortedAndLabeledByPlatform() throws {
        let image = try image(Self.imageJSON)
        let suggestions = ImagePortSuggestions(image: image)
        XCTAssertEqual(suggestions.ports.map(\.id), ["53/udp", "80/tcp", "8080/tcp", "9090/tcp"])
        XCTAssertEqual(suggestions.ports[1].platforms, ["linux/amd64", "linux/arm64/v8"])
        XCTAssertNil(suggestions.warning)
    }

    func testExplicitPlatformFiltersSuggestionsIncludingVariantSuffix() throws {
        let image = try image(Self.imageJSON)
        XCTAssertEqual(ImagePortSuggestions(image: image, platform: "linux/arm64").ports.map(\.id), ["53/udp", "80/tcp", "8080/tcp"])
        XCTAssertEqual(ImagePortSuggestions(image: image, platform: "linux/amd64").ports.map(\.id), ["80/tcp", "9090/tcp"])
        XCTAssertEqual(ImagePortSuggestions(image: image, platform: "linux/aarch64/8").ports.map(\.id), ["53/udp", "80/tcp", "8080/tcp"])
        XCTAssertEqual(ImagePortSuggestions(image: image, platform: "linux/x86_64/v1").ports.map(\.id), ["80/tcp", "9090/tcp"])
        let unavailable = ImagePortSuggestions(image: image, platform: "linux/s390x")
        XCTAssertTrue(unavailable.ports.isEmpty)
        XCTAssertNotNil(unavailable.warning)
    }

    func testAbsentDeclarationsAreDifferentFromUnavailableMetadata() throws {
        let absent = try image(#"{"name":"web:dev","variants":[{"platform":{"os":"linux","architecture":"arm64"},"config":{"config":{}}}]}"#)
        let suggestions = ImagePortSuggestions(image: absent)
        XCTAssertTrue(suggestions.ports.isEmpty)
        XCTAssertNil(suggestions.warning)
        XCTAssertTrue(suggestions.message.contains("does not declare"))

        let unavailable = try image(#"{"name":"web:dev","variants":[{"platform":{"os":"linux","architecture":"arm64"}}]}"#)
        XCTAssertNotNil(ImagePortSuggestions(image: unavailable).warning)
    }

    func testMalformedDeclarationsDoNotHideValidSuggestionsOrBreakImageLists() throws {
        let malformed = try image("""
        {"name":"web:dev","variants":[{"platform":{"os":"linux","architecture":"arm64"},
          "config":{"config":{"ExposedPorts":{"80/tcp":{},"0/tcp":{},"bad":{},"999999/tcp":{},"90/sctp":{},"443/tcp":true}}}}]}
        """)
        let suggestions = ImagePortSuggestions(image: malformed)
        XCTAssertEqual(suggestions.ports.map(\.id), ["80/tcp"])
        XCTAssertNotNil(suggestions.warning)

        for malformedValue in ["true", "[]", #""invalid""#] {
            let metadata = try image("""
            {"name":"web:dev","variants":[{"config":{"config":{"ExposedPorts":\(malformedValue)}}}]}
            """)
            XCTAssertNotNil(ImagePortSuggestions(image: metadata).warning)
        }
    }

    func testPortDeclarationDefaultsToTCPButRejectsInvalidBoundariesAndSyntax() {
        XCTAssertEqual(ImageExposedPort(declaration: "80")?.displayValue, "80/tcp")
        XCTAssertEqual(ImageExposedPort(declaration: "65535/udp")?.port, 65_535)
        for value in ["0/tcp", "65536/tcp", "-1/tcp", "80/", "80/tcp/extra", " 80/tcp", "80-81/tcp", "\u{FF18}\u{FF10}/tcp"] {
            XCTAssertNil(ImageExposedPort(declaration: value), value)
        }
    }

    func testLaunchImageLookupIsLocalInspectionOnly() async throws {
        let runner = ResourceFixtureRunner(images: "[\(Self.imageJSON)]")
        let result = await ResourceFixtures.service(runner: runner).inspectLaunchImage(reference: "registry.example:5000/web:dev")
        let metadata = try result.get()
        XCTAssertEqual(metadata.reference.fullValue, "registry.example:5000/web:dev")
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [["image", "inspect", "registry.example:5000/web:dev"]])
    }

    func testFailedLookupAndInvalidReferencesCannotPullOrRun() async {
        let runner = ResourceFixtureRunner(inspectExitCode: 1)
        let service = ResourceFixtures.service(runner: runner)
        let failed = await service.inspectLaunchImage(reference: "missing:dev")
        guard case .failure = failed else { return XCTFail("Expected a visible lookup error") }
        for reference in ["", "--help", "name with spaces", "web\u{0}"] {
            let result = await service.inspectLaunchImage(reference: reference)
            guard case .failure = result else { return XCTFail("Expected invalid-reference error") }
        }
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [["image", "inspect", "missing:dev"]])
    }

    private func image(_ json: String) throws -> ImageMetadata {
        try XCTUnwrap(ResourceFixtures.row(json, kind: .images).image)
    }
}
