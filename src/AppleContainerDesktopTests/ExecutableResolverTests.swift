import XCTest
@testable import AppleContainerDesktop

final class ExecutableResolverTests: XCTestCase {
    func testOverridePathWinsWhenExecutable() {
        let resolver = ContainerCLIResolver(
            fileSystem: FakeFileSystem(executablePaths: ["/custom/container"]),
            environment: CLIResolverEnvironment(path: "/usr/local/bin"),
            knownPaths: ["/usr/local/bin/container"]
        )

        let result = resolver.resolve(overridePath: "/custom/container")

        XCTAssertEqual(result.executableURL?.path, "/custom/container")
        XCTAssertEqual(result.source, .settingsOverride)
        XCTAssertNil(result.problem)
    }

    func testInvalidOverrideReturnsProblemInsteadOfFallingBack() {
        let resolver = ContainerCLIResolver(
            fileSystem: FakeFileSystem(executablePaths: ["/usr/local/bin/container"]),
            environment: CLIResolverEnvironment(path: "/usr/local/bin"),
            knownPaths: ["/usr/local/bin/container"]
        )

        let result = resolver.resolve(overridePath: "/missing/container")

        XCTAssertNil(result.executableURL)
        XCTAssertEqual(result.source, .settingsOverride)
        XCTAssertNotNil(result.problem)
    }

    func testPathLookupIsBestEffortBeforeKnownLocations() {
        let resolver = ContainerCLIResolver(
            fileSystem: FakeFileSystem(executablePaths: ["/path/bin/container", "/usr/local/bin/container"]),
            environment: CLIResolverEnvironment(path: "/path/bin:/other/bin"),
            knownPaths: ["/usr/local/bin/container"]
        )

        let result = resolver.resolve(overridePath: nil)

        XCTAssertEqual(result.executableURL?.path, "/path/bin/container")
        XCTAssertEqual(result.source, .path)
    }

    func testKnownLocationsWorkWhenPathIsMissing() {
        let resolver = ContainerCLIResolver(
            fileSystem: FakeFileSystem(executablePaths: ["/usr/local/bin/container"]),
            environment: CLIResolverEnvironment(path: nil),
            knownPaths: ["/usr/local/bin/container"]
        )

        let result = resolver.resolve(overridePath: nil)

        XCTAssertEqual(result.executableURL?.path, "/usr/local/bin/container")
        XCTAssertEqual(result.source, .knownLocation)
    }
}

private struct FakeFileSystem: FileSystemChecking {
    var executablePaths: Set<String>

    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}
