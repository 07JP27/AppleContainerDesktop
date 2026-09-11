import XCTest
@testable import AppleContainerDesktop

final class ContainerLaunchConfigurationTests: XCTestCase {
    func testDefaultsRequireOnlyAnImageAndKeepRunDetached() throws {
        let blank = ContainerCreateRunRequest(operation: .run)
        XCTAssertEqual(blank.validationIssues.map(\.field), [.image])
        XCTAssertThrowsError(try blank.validatedArguments())
        XCTAssertEqual(try ContainerCreateRunRequest(operation: .run, image: "alpine").validatedArguments(), ["run", "--detach", "alpine"])
        XCTAssertEqual(try ContainerCreateRunRequest(operation: .run, image: "alpine", remove: true).validatedArguments(), ["run", "--detach", "--rm", "alpine"])
        XCTAssertEqual(try ContainerCreateRunRequest(operation: .create, image: "alpine", remove: true).validatedArguments(), ["create", "alpine"])
    }

    func testRowsAndDraftAreMutableWithStableIdentities() throws {
        var request = ContainerCreateRunRequest(operation: .create)
        var environment = ContainerEnvironmentInput()
        let id = environment.id
        environment.name = "FOO"
        environment.value = "value"
        request.image = "alpine"
        request.environment = [environment]
        request.operation = .run

        let snapshot = request
        XCTAssertEqual(environment.id, id)
        XCTAssertNotEqual(id, ContainerEnvironmentInput().id)
        XCTAssertEqual(request, snapshot)
        XCTAssertTrue(request.validationIssues.isEmpty)
        XCTAssertEqual(try request.validatedArguments(), ["run", "--detach", "--env", "FOO=value", "alpine"])
        XCTAssertEqual(request, snapshot)
    }

    func testEmptyRowsAndOptionalFieldsDoNotOverrideRuntimeDefaults() throws {
        let request = ContainerCreateRunRequest(
            operation: .run, image: " alpine ", name: " ", cpus: "\n", memory: "\t",
            environment: [ContainerEnvironmentInput()],
            volumes: [ContainerMountInput()],
            ports: [ContainerPortInput(), ContainerPortInput(transport: .udp)],
            networks: [ContainerNetworkInput(), ContainerNetworkInput(specification: " \n")],
            platform: " ", command: " \n\t"
        )
        XCTAssertTrue(request.validationIssues.isEmpty)
        XCTAssertEqual(try request.validatedArguments(), ["run", "--detach", "alpine"])
    }

    func testEnvironmentValuesAreLiteralAndInheritanceIsExplicit() throws {
        let request = ContainerCreateRunRequest(
            operation: .run, image: "alpine",
            environment: [
                .init(name: " SETTINGS ", value: " a,b=c=d \n next line "),
                .init(name: "EMPTY"),
                .init(name: "HOST", value: "not used", inheritFromHost: true),
                .init(name: "name.with-dashes and spaces", value: "  "),
                .init(name: "-OPTION", value: "--rm")
            ]
        )
        XCTAssertEqual(
            try request.validatedArguments(),
            [
                "run", "--detach",
                "--env", "SETTINGS= a,b=c=d \n next line ",
                "--env", "EMPTY=",
                "--env", "HOST",
                "--env", "name.with-dashes and spaces=  ",
                "--env=-OPTION=--rm",
                "alpine"
            ]
        )
    }

    func testPartialEnvironmentRowsAndNullCharactersAreRejected() {
        let invalid: [ContainerEnvironmentInput] = [
            .init(value: "value"),
            .init(value: " "),
            .init(inheritFromHost: true),
            .init(name: "A=B", value: "value"),
            .init(name: "A=\u{FE0F}", value: "value"),
            .init(name: "A\0B"),
            .init(name: "A", value: "\0"),
            .init(name: "A", value: "\0\u{FE0F}"),
            .init(name: "A", value: "\0", inheritFromHost: true)
        ]
        for row in invalid {
            assertInvalid(ContainerCreateRunRequest(operation: .run, image: "alpine", environment: [row]), field: .environment(row.id))
        }
    }

    func testMountsPreservePathsAndNamedVolumeCreationSemantics() throws {
        let request = ContainerCreateRunRequest(
            operation: .create, image: "alpine",
            volumes: [
                .init(source: "/Users/example/host folder,a=b ", destination: "/container path,a=b ", readOnly: true),
                .init(kind: .volume, source: " cache.v1 ", destination: "/cache"),
                .init(kind: .volume, source: "x", destination: "/single-letter-volume")
            ]
        )
        XCTAssertEqual(
            try request.validatedArguments(),
            [
                "create",
                "--volume", "/Users/example/host folder,a=b :/container path,a=b :ro",
                "--volume", "cache.v1:/cache",
                "--volume", "x:/single-letter-volume",
                "alpine"
            ]
        )
        XCTAssertEqual(
            try ContainerCreateRunRequest(
                operation: .create, image: "alpine",
                volumes: [.init(source: "/\u{301}folder", destination: "/\u{301}target")]
            ).validatedArguments(),
            ["create", "--volume", "/\u{301}folder:/\u{301}target", "alpine"]
        )
    }

    func testInvalidMountsAreRejectedWithoutNormalizingPaths() {
        let invalid: [ContainerMountInput] = [
            .init(source: "/host"),
            .init(destination: "/target"),
            .init(readOnly: true),
            .init(source: " ", destination: "/target"),
            .init(source: "relative/path", destination: "/target"),
            .init(source: "~/folder", destination: "/target"),
            .init(source: " /host", destination: "/target"),
            .init(source: "/host", destination: "relative"),
            .init(source: "/host:folder", destination: "/target"),
            .init(source: "/host:\u{FE0F}", destination: "/target"),
            .init(source: "/host", destination: "/target:ro"),
            .init(source: "/host\0", destination: "/target"),
            .init(source: "/host", destination: "/target\0\u{FE0F}"),
            .init(kind: .volume, source: "/not-a-volume", destination: "/target"),
            .init(kind: .volume, source: "not a volume", destination: "/target"),
            .init(kind: .volume, source: String(repeating: "v", count: 256), destination: "/target")
        ]
        for row in invalid {
            assertInvalid(ContainerCreateRunRequest(operation: .run, image: "alpine", volumes: [row]), field: .mount(row.id))
        }
    }

    func testImageReferencesPreserveRegistryPortsTagsAndDigests() throws {
        for image in [
            "alpine", "localhost:5000/team/image:release",
            "registry.example:5000/team/image:tag@sha256:" + String(repeating: "a", count: 64)
        ] {
            let request = ContainerCreateRunRequest(operation: .run, image: " \(image) ")
            XCTAssertTrue(request.validationIssues.isEmpty)
            XCTAssertEqual(try request.validatedArguments().last, image)
        }
        for image in ["", " \n", "-alpine", "-\u{FE0F}alpine", "al pine", "al \u{301}pine", "al\tpine", "al\npine", "al\u{7F}pine", "al\0pine"] {
            assertInvalid(ContainerCreateRunRequest(operation: .run, image: image), field: .image)
        }
    }

    func testNamesMatchAppleEntityNamingRatherThanDockerLengthLimits() {
        for name in ["ab", "A1._-name", String(repeating: "a", count: 300)] {
            XCTAssertTrue(ContainerCreateRunRequest(operation: .run, image: "alpine", name: name).validationIssues.isEmpty)
        }
        for name in ["a", "_name", "-name", ".name", "two names", "na/me", "\u{540D}\u{524D}", "a\0b"] {
            assertInvalid(ContainerCreateRunRequest(operation: .run, image: "alpine", name: name), field: .name)
        }
    }

    func testCPUUsesPositiveInt64Values() throws {
        for cpus in ["1", "+2", "0002", "64", String(Int64.max)] {
            let request = ContainerCreateRunRequest(operation: .run, image: "alpine", cpus: " \(cpus) ")
            XCTAssertTrue(request.validationIssues.isEmpty, cpus)
            XCTAssertEqual(try request.validatedArguments(), ["run", "--detach", "--cpus", cpus, "alpine"])
        }
        for cpus in ["0", "-1", "1.5", "1e2", "many", "9223372036854775808", "2\0"] {
            assertInvalid(ContainerCreateRunRequest(operation: .run, image: "alpine", cpus: cpus), field: .cpus)
        }
    }

    func testMemoryAcceptsAppleUnitsAndFractionalAmounts() throws {
        for memory in ["1024", "1K", "512M", "0.5G", ".5GiB", "1.5 GiB", "512 MB", "2t", "1P", "1b"] {
            let request = ContainerCreateRunRequest(operation: .run, image: "alpine", memory: memory)
            XCTAssertTrue(request.validationIssues.isEmpty, memory)
            XCTAssertEqual(try request.validatedArguments(), ["run", "--detach", "--memory", memory, "alpine"])
        }
        for memory in ["0", "0G", "-1G", "1.2.3M", "1e3", "NaN", "1G junk", "1Gi", "1E", "1\nG", "999999999999999P", "1M\0"] {
            assertInvalid(ContainerCreateRunRequest(operation: .run, image: "alpine", memory: memory), field: .memory)
        }
    }

    func testPlatformsAcceptSupportedVariantsWithoutCanonicalizingTheChoice() throws {
        for platform in [
            "linux/arm64", "linux/arm64/v8", "linux/arm64/8", "linux/aarch64",
            "linux/x86_64/v1", "linux/amd64", "linux/arm/v7", "linux/armel/v6",
            "linux/armhf/v7", "linux/riscv64", "linux/s390x", "windows/amd64", "darwin/arm64"
        ] {
            let request = ContainerCreateRunRequest(operation: .run, image: "alpine", platform: " \(platform) ")
            XCTAssertTrue(request.validationIssues.isEmpty, platform)
            XCTAssertEqual(try request.validatedArguments(), ["run", "--detach", "--platform", platform, "alpine"])
        }
        for platform in [
            "linux", "linux/", "/arm64", "linux//arm64", "linux/arm64/v9", "linux/amd64/v2",
            "linux/armhf/v6", "linux/riscv64/v1", "linux/arm64/v8/extra", "linux/ arm64", "other/amd64", "linux/arm64\0"
        ] {
            assertInvalid(ContainerCreateRunRequest(operation: .run, image: "alpine", platform: platform), field: .platform)
        }
    }

    func testPortSerializationSupportsIPv6ProtocolsAndEqualLengthRanges() throws {
        let cases: [(ContainerPortInput, String)] = [
            (.init(hostPort: "8080", containerPort: "80"), "8080:80/tcp"),
            (.init(hostAddress: "127.0.0.1", hostPort: "53", containerPort: "53", transport: .udp), "127.0.0.1:53:53/udp"),
            (.init(hostAddress: "::1", hostPort: "8080", containerPort: "80"), "[::1]:8080:80/tcp"),
            (.init(hostAddress: "fe80::1%en0", hostPort: "8080", containerPort: "80"), "[fe80::1%en0]:8080:80/tcp"),
            (.init(hostAddress: "[fe80::1%5]", hostPort: "8080", containerPort: "80"), "[fe80::1%5]:8080:80/tcp"),
            (.init(hostAddress: "::ffff:127.0.0.1", hostPort: "8080", containerPort: "80"), "[::ffff:127.0.0.1]:8080:80/tcp"),
            (.init(hostAddress: "[2001:db8::1]", hostPort: "9000-9002", containerPort: "8000-8002", transport: .udp), "[2001:db8::1]:9000-9002:8000-8002/udp"),
            (.init(hostPort: " 1 ", containerPort: " 65535 "), "1:65535/tcp"),
            (.init(hostPort: "1-65535", containerPort: "1-65535"), "1-65535:1-65535/tcp")
        ]
        for (row, expected) in cases {
            let request = ContainerCreateRunRequest(operation: .run, image: "alpine", ports: [row])
            XCTAssertEqual(try request.validatedArguments(), ["run", "--detach", "--publish", expected, "alpine"])
        }
    }

    func testPortsRequireExplicitValidPairsAndIPAddresses() {
        var invalid: [ContainerPortInput] = [
            .init(hostPort: "8080"),
            .init(containerPort: "80"),
            .init(hostAddress: "127.0.0.1"),
            .init(hostPort: "8000-8002", containerPort: "80-81")
        ]
        for port in ["0", "65536", "-1", "12-", "-12", "12--14", "14-12", "1.5", "1e3", "auto", "\u{FF18}\u{FF10}", "80\0"] {
            invalid.append(.init(hostPort: port, containerPort: "80"))
            invalid.append(.init(hostPort: "8080", containerPort: port))
        }
        for address in [
            "localhost", "999.1.1.1", "::zz", "[127.0.0.1]", "[::1", "::1]", "127.0.0.1\0",
            "fe80::1%", "fe80::1%en0%en1", "[fe80::1%en 0]", "fe80::1%en0\nx", "127.0.0.1%en0"
        ] {
            invalid.append(.init(hostAddress: address, hostPort: "8080", containerPort: "80"))
        }
        for row in invalid {
            assertInvalid(ContainerCreateRunRequest(operation: .run, image: "alpine", ports: [row]), field: .port(row.id))
        }
    }

    func testOverlappingHostBindingsReportBothRows() {
        let pairs: [(ContainerPortInput, ContainerPortInput)] = [
            (.init(hostPort: "8080", containerPort: "80"), .init(hostAddress: "127.0.0.1", hostPort: "8080", containerPort: "81")),
            (.init(hostAddress: "0.0.0.0", hostPort: "8000-8002", containerPort: "80-82"), .init(hostAddress: "127.0.0.1", hostPort: "8002", containerPort: "90")),
            (.init(hostAddress: "127.0.0.1", hostPort: "8080", containerPort: "80"), .init(hostAddress: "127.0.0.1", hostPort: "8080", containerPort: "90")),
            (.init(hostAddress: "::1", hostPort: "8080", containerPort: "80"), .init(hostAddress: "0:0:0:0:0:0:0:1", hostPort: "8080", containerPort: "90")),
            (.init(hostAddress: "127.0.0.1", hostPort: "8080", containerPort: "80"), .init(hostAddress: "::ffff:127.0.0.1", hostPort: "8080", containerPort: "90")),
            (.init(hostAddress: "fe80::1%en0", hostPort: "8080", containerPort: "80"), .init(hostAddress: "fe80:0:0:0:0:0:0:1%en0", hostPort: "8080", containerPort: "90")),
            (.init(hostAddress: "fe80::1%05", hostPort: "8080", containerPort: "80"), .init(hostAddress: "fe80::1%5", hostPort: "8080", containerPort: "90")),
            (.init(hostAddress: "::", hostPort: "8080", containerPort: "80", transport: .udp), .init(hostAddress: "2001:db8::1", hostPort: "8080", containerPort: "90", transport: .udp))
        ]
        for (first, second) in pairs {
            let request = ContainerCreateRunRequest(operation: .run, image: "alpine", ports: [first, second])
            XCTAssertEqual(request.validationIssues.map(\.field), [.port(first.id), .port(second.id)])
            XCTAssertThrowsError(try request.validatedArguments())
        }
    }

    func testDistinctAddressesProtocolsAndAdjacentRangesDoNotConflict() throws {
        let pairs: [(ContainerPortInput, ContainerPortInput)] = [
            (.init(hostAddress: "127.0.0.1", hostPort: "8080", containerPort: "80"), .init(hostAddress: "127.0.0.2", hostPort: "8080", containerPort: "80")),
            (.init(hostPort: "8080", containerPort: "80"), .init(hostPort: "8080", containerPort: "80", transport: .udp)),
            (.init(hostPort: "8080", containerPort: "80"), .init(hostAddress: "::1", hostPort: "8080", containerPort: "80")),
            (.init(hostAddress: "::1", hostPort: "8080", containerPort: "80"), .init(hostAddress: "2001:db8::1", hostPort: "8080", containerPort: "80")),
            (.init(hostAddress: "fe80::1%en0", hostPort: "8080", containerPort: "80"), .init(hostAddress: "fe80::1%en1", hostPort: "8080", containerPort: "80")),
            (.init(hostPort: "8000-8002", containerPort: "80-82"), .init(hostPort: "8003-8005", containerPort: "80-82"))
        ]
        for (first, second) in pairs {
            let request = ContainerCreateRunRequest(operation: .run, image: "alpine", ports: [first, second])
            XCTAssertTrue(request.validationIssues.isEmpty)
            XCTAssertNoThrow(try request.validatedArguments())
        }
    }

    func testNetworkSpecificationsAreNotSplitIntoSeparateArguments() throws {
        let request = ContainerCreateRunRequest(
            operation: .run, image: "alpine",
            networks: [
                .init(specification: " frontend,mac=02:42:ac:11:00:02,mtu=1500 "),
                .init(specification: "backend,mtu=9000")
            ]
        )
        XCTAssertEqual(
            try request.validatedArguments(),
            [
                "run", "--detach",
                "--network", "frontend,mac=02:42:ac:11:00:02,mtu=1500",
                "--network", "backend,mtu=9000", "alpine"
            ]
        )
    }

    func testIncompleteOrInvalidNetworkPropertiesAreRejected() {
        for specification in [
            ",mac=02:42:ac:11:00:02", "network,", "network,mac=", "network,mac=not-a-mac",
            "network,mtu=1279", "network,mtu=65536", "network,mtu=1500=extra",
            "network,unknown=value", "network\0", "network,mac=02:42:ac:11:00:02\0"
        ] {
            let row = ContainerNetworkInput(specification: specification)
            assertInvalid(ContainerCreateRunRequest(operation: .run, image: "alpine", networks: [row]), field: .network(row.id))
        }
    }

    func testCommandTokenizationPreservesEmptyArgumentsAndDoesNotExpandShellSyntax() throws {
        let request = ContainerCreateRunRequest(
            operation: .run, image: "alpine",
            command: #"printf '%s\n' "" '' pre" mid "post a\ b '$HOME;$(whoami)' "say \"hi\"""#
        )
        XCTAssertEqual(
            try request.validatedArguments(),
            ["run", "--detach", "alpine", "printf", "%s\\n", "", "", "pre mid post", "a b", "$HOME;$(whoami)", "say \"hi\""]
        )
        XCTAssertEqual(try CommandLineSplitter.validatedSplit(#""""#), [""])
        XCTAssertEqual(try CommandLineSplitter.validatedSplit(#"echo "\\""#), ["echo", "\\"])
        XCTAssertEqual(try CommandLineSplitter.validatedSplit(#"echo "a\b" "\$HOME""#), ["echo", "a\\b", "$HOME"])
        XCTAssertEqual(try CommandLineSplitter.validatedSplit("echo one\\\ntwo \\\n"), ["echo", "onetwo"])
    }

    func testMalformedCommandsSurfaceLexerErrors() {
        for command in ["echo 'unfinished", "echo \"unfinished", "echo '\u{FE0F}", "echo trailing\\", "echo \0", "echo \0\u{FE0F}"] {
            assertInvalid(ContainerCreateRunRequest(operation: .run, image: "alpine", command: command), field: .command)
        }
        XCTAssertThrowsError(try CommandLineSplitter.validatedSplit("echo \"unfinished")) {
            XCTAssertEqual($0 as? CommandLineSplitter.TokenizationError, .unmatchedQuote)
        }
        XCTAssertThrowsError(try CommandLineSplitter.validatedSplit("echo trailing\\")) {
            XCTAssertEqual($0 as? CommandLineSplitter.TokenizationError, .trailingEscape)
        }
    }

    func testExecRetainsItsExistingDefaultAndPermissiveTokenization() {
        XCTAssertEqual(ContainerExecRequest(identifier: "web", command: "").arguments, ["exec", "-i", "-t", "web", "/bin/sh"])
        XCTAssertEqual(CommandLineSplitter.split(#"/bin/sh -lc 'echo hello' escaped\ space"#), ["/bin/sh", "-lc", "echo hello", "escaped space"])
        XCTAssertEqual(CommandLineSplitter.split("echo 'unfinished"), ["echo", "unfinished"])
        XCTAssertEqual(CommandLineSplitter.split("echo trailing\\"), ["echo", "trailing"])
        XCTAssertEqual(CommandLineSplitter.split(#"echo 'a\b' """#), ["echo", "ab"])
    }

    func testInvalidOperationsCannotBeSerialized() {
        for operation in ContainerOperation.allCases where operation != .run && operation != .create {
            assertInvalid(ContainerCreateRunRequest(operation: operation, image: "alpine"), field: .operation)
        }
    }

    func testValidationCollectsEveryFieldAndRecoversAfterEditing() throws {
        let row = ContainerEnvironmentInput(value: "value")
        var request = ContainerCreateRunRequest(operation: .run, image: "", cpus: "0", environment: [row], command: "echo '")
        let issues = request.validationIssues
        XCTAssertEqual(issues.map(\.field), [.image, .cpus, .environment(row.id), .command])
        XCTAssertThrowsError(try request.validatedArguments()) { error in
            let validation = error as? ContainerLaunchValidationError
            XCTAssertEqual(validation?.issues, issues)
            XCTAssertEqual(validation?.errorDescription, issues.map(\.message).joined(separator: "\n"))
        }

        request.image = "alpine"
        request.cpus = ""
        request.environment[0].name = "KEY"
        request.command = "echo ''"
        XCTAssertTrue(request.validationIssues.isEmpty)
        XCTAssertEqual(request.environment[0].id, row.id)
        XCTAssertEqual(try request.validatedArguments(), ["run", "--detach", "--env", "KEY=value", "alpine", "echo", ""])
    }

    private func assertInvalid(
        _ request: ContainerCreateRunRequest,
        field: ContainerLaunchField,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(request.validationIssues.map(\.field), [field], file: file, line: line)
        XCTAssertThrowsError(try request.validatedArguments(), file: file, line: line) { error in
            XCTAssertEqual((error as? ContainerLaunchValidationError)?.issues, request.validationIssues, file: file, line: line)
        }
    }
}
