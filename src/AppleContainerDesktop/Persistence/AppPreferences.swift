import Foundation

protocol AppPreferences: Sendable {
    var cliExecutablePath: String? { get set }
}

final class UserDefaultsAppPreferences: AppPreferences, @unchecked Sendable {
    private enum Keys {
        static let cliExecutablePath = "cliExecutablePath"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var cliExecutablePath: String? {
        get {
            let value = defaults.string(forKey: Keys.cliExecutablePath)
            return value?.isEmpty == false ? value : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Keys.cliExecutablePath)
            } else {
                defaults.removeObject(forKey: Keys.cliExecutablePath)
            }
        }
    }
}
