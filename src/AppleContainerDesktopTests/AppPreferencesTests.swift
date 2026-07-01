import XCTest
@testable import AppleContainerDesktop

final class AppPreferencesTests: XCTestCase {
    func testCLIPathPersistsInIsolatedDefaultsSuite() {
        let suiteName = "AppleContainerDesktopTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = UserDefaultsAppPreferences(defaults: defaults)
        preferences.cliExecutablePath = "/usr/local/bin/container"

        XCTAssertEqual(preferences.cliExecutablePath, "/usr/local/bin/container")

        preferences.cliExecutablePath = nil
        XCTAssertNil(preferences.cliExecutablePath)
    }
}
