import XCTest
@testable import AppleContainerDesktop

final class ProcessRunnerTests: XCTestCase {
    func testRunnerDrainsOutputWhileProcessRuns() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            ProcessCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "yes x | head -c 200000"],
                timeout: 5
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 200000)
    }

    func testRunnerStreamsStdoutAndStderrChunks() async throws {
        let runner = ProcessRunner()
        let buffer = StreamingOutputBuffer()
        let result = try await runner.run(
            ProcessCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf out; printf err >&2"],
                timeout: 5
            ),
            outputHandler: { event in
                _ = buffer.append(event)
            }
        )

        let streamed = buffer.append(ProcessOutputEvent(source: .stdout, text: ""))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertTrue(streamed.contains("out"))
        XCTAssertTrue(streamed.contains("err"))
    }
}
