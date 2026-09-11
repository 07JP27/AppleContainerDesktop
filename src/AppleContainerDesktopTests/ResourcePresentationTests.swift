import XCTest
@testable import AppleContainerDesktop

final class ResourcePresentationTests: XCTestCase {
    func testResourceSpecificColumns() {
        XCTAssertEqual(ResourceListColumn.columns(for: .containers).map(\.title), ["Name", "Status", "Image", "Port(s)", "Last started"])
        XCTAssertEqual(ResourceListColumn.columns(for: .images).map(\.title), ["Name", "Tag", "Digest", "Created", "Size", "In use"])
        for kind in [ResourceKind.networks, .volumes, .registry, .machines] {
            XCTAssertEqual(ResourceListColumn.columns(for: kind).map(\.title), ["Name", "Status", "Detail"])
        }
    }

    func testImageReferenceSeparatesTagsWithoutLosingRegistryPorts() {
        for (reference, name, tag) in [
            ("registry.example:5000/team/web:dev", "registry.example:5000/team/web", Optional("dev")),
            ("localhost:5000/web", "localhost:5000/web", nil),
            ("[::1]:5000/team/web:dev", "[::1]:5000/team/web", "dev"),
            ("alpine@sha256:abc", "alpine", nil),
            ("alpine:dev@sha256:abc", "alpine", "dev")
        ] {
            let parsed = ImageReference(reference)
            XCTAssertEqual(parsed.repository, name)
            XCTAssertEqual(parsed.tag, tag)
            XCTAssertEqual(parsed.fullValue, reference)
        }
        XCTAssertEqual(ImageReference("nginx").normalized, ImageReference("docker.io/library/nginx:latest").normalized)
        XCTAssertEqual(ImageReference("index.docker.io/library/nginx:latest").normalized, ImageReference("nginx:latest").normalized)
        let bareDigest = "sha256:" + String(repeating: "a", count: 64)
        let untagged = ImageReference(bareDigest)
        XCTAssertEqual(untagged.displayName, "<none>")
        XCTAssertNil(untagged.tag)
        XCTAssertEqual(untagged.digest, bareDigest)
        XCTAssertEqual(untagged.normalized, bareDigest)
    }

    func testDisplayAndActionIdentityRemainSeparate() throws {
        let row = try ResourceFixtures.row(ResourceFixtures.image, kind: .images)
        XCTAssertEqual(ResourceListColumn.name.cell(for: row).text, "registry.example:5000/team/web")
        XCTAssertEqual(ResourceListColumn.tag.cell(for: row).text, "dev")
        XCTAssertEqual(row.inspectIdentifier, "registry.example:5000/team/web:dev")
        XCTAssertEqual(row.title, row.inspectIdentifier)
        XCTAssertTrue(row.searchableText.contains(":dev"))
        XCTAssertEqual(ImageOperation.push.arguments(identifier: row.inspectIdentifier, input: nil), ["image", "push", "registry.example:5000/team/web:dev"])
    }

    func testImageUsageMatchesAliasesButNotReusedTags() throws {
        var image = try XCTUnwrap(ResourceFixtures.row(ResourceFixtures.image, kind: .images).image)
        var container = try XCTUnwrap(ResourceFixtures.row(ResourceFixtures.container, kind: .containers).container)
        image.reference = ImageReference("example/alias:stable")
        XCTAssertTrue(image.isUsed(by: container))
        container.imageDigest = "sha256:previous-index"
        container.imageReference = image.reference.fullValue
        XCTAssertFalse(image.isUsed(by: container))
        container.imageDigest = "sha256:arm"
        XCTAssertTrue(image.isUsed(by: container))
        container.imageDigest = nil
        XCTAssertTrue(image.isUsed(by: container))
    }

    func testTypedSizeAndDateSortingKeepsUnavailableValuesLast() throws {
        let row = try ResourceFixtures.row(ResourceFixtures.image, kind: .images)
        var small = row
        small.id = "small"
        var smallImage = try XCTUnwrap(small.image)
        smallImage.variants = nil
        smallImage.reportedSizeBytes = 2_000_000
        smallImage.createdAt = Date(timeIntervalSince1970: 1_000)
        small.metadata = .image(smallImage)
        var missing = row
        missing.id = "missing"
        var missingImage = smallImage
        missingImage.reportedSizeBytes = nil
        missingImage.createdAt = nil
        missing.metadata = .image(missingImage)
        let rows = [missing, row, small]
        XCTAssertEqual(ResourceListPresentation.sorted(rows, by: .size, ascending: true).map(\.id), ["small", row.id, "missing"])
        XCTAssertEqual(ResourceListPresentation.sorted(rows, by: .size, ascending: false).map(\.id), [row.id, "small", "missing"])
        XCTAssertEqual(ResourceListPresentation.sorted(rows, by: .created, ascending: true).map(\.id), ["small", row.id, "missing"])
    }

    func testDigestTooltipRetainsTheFullDigest() throws {
        var row = try ResourceFixtures.row(ResourceFixtures.image, kind: .images)
        var image = try XCTUnwrap(row.image)
        image.digest = "sha256:" + String(repeating: "a", count: 64)
        row.metadata = .image(image)
        let cell = ResourceListColumn.digest.cell(for: row)
        XCTAssertLessThan(cell.text.count, 30)
        XCTAssertTrue(cell.tooltip.contains(try XCTUnwrap(image.digest)))
        XCTAssertTrue(cell.tooltip.contains("not Docker Image ID"))
    }

    func testPublishedTCPPortsBuildSafeBrowserLinks() {
        let wildcard = PublishedPort(
            hostAddress: "0.0.0.0", hostPort: 8081, containerPort: 8080,
            portCount: 1, transport: "tcp"
        )
        XCTAssertEqual(wildcard.browserAccessLink?.title, "localhost:8081")
        XCTAssertEqual(wildcard.browserAccessLink?.url.absoluteString, "http://localhost:8081/")

        let ipv6 = PublishedPort(
            hostAddress: "::1", hostPort: 8443, containerPort: 443,
            portCount: 1, transport: "TCP"
        )
        XCTAssertEqual(ipv6.browserAccessLink?.title, "[::1]:8443")
        XCTAssertEqual(ipv6.browserAccessLink?.url.absoluteString, "http://[::1]:8443/")

        let scopedIPv6 = PublishedPort(
            hostAddress: "fe80::1%en0", hostPort: 8080, containerPort: 80,
            portCount: 2, transport: "tcp"
        )
        XCTAssertEqual(scopedIPv6.browserAccessLink?.title, "[fe80::1%en0]:8080 (first in range)")
        XCTAssertEqual(scopedIPv6.browserAccessLink?.url.absoluteString, "http://[fe80::1%25en0]:8080/")

        XCTAssertNil(PublishedPort(
            hostAddress: "0.0.0.0", hostPort: 53, containerPort: 53,
            portCount: 1, transport: "udp"
        ).browserAccessLink)
        XCTAssertNil(PublishedPort(
            hostAddress: "not an address", hostPort: 8080, containerPort: 80,
            portCount: 1, transport: "tcp"
        ).browserAccessLink)
    }

    func testPortColumnOnlyOffersBrowserLinksForRunningContainers() throws {
        var running = try ResourceFixtures.row(ResourceFixtures.container, kind: .containers)
        var metadata = try XCTUnwrap(running.container)
        metadata.ports = [
            PublishedPort(hostAddress: "0.0.0.0", hostPort: 8081, containerPort: 8080, portCount: 1, transport: "tcp"),
            PublishedPort(hostAddress: "0.0.0.0", hostPort: 5353, containerPort: 53, portCount: 1, transport: "udp")
        ]
        running.metadata = .container(metadata)
        XCTAssertEqual(ResourceListColumn.ports.cell(for: running).links.map(\.title), ["localhost:8081"])

        metadata.state = "stopped"
        running.metadata = .container(metadata)
        XCTAssertTrue(ResourceListColumn.ports.cell(for: running).links.isEmpty)
    }
}
