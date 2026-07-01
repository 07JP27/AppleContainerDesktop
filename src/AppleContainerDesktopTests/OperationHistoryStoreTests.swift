import XCTest
@testable import AppleContainerDesktop

final class OperationHistoryStoreTests: XCTestCase {
    func testOperationHistoryPersistsRecentRecords() {
        let suiteName = "AppleContainerDesktopHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = UserDefaultsOperationHistoryStore(defaults: defaults)
        store.append(
            OperationRecord(
                title: "Stop",
                command: "/fake/container stop web",
                exitCode: 0,
                succeeded: true
            )
        )

        let reloaded = UserDefaultsOperationHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.recent(limit: 1).first?.title, "Stop")
        XCTAssertEqual(reloaded.recent(limit: 1).first?.succeeded, true)
    }
}

