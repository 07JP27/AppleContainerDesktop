import Foundation

protocol OperationHistoryStoring: Sendable {
    func append(_ record: OperationRecord)
    func recent(limit: Int) -> [OperationRecord]
}

final class UserDefaultsOperationHistoryStore: OperationHistoryStoring, @unchecked Sendable {
    private enum Keys {
        static let records = "operationHistory.records"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(_ record: OperationRecord) {
        lock.lock()
        defer { lock.unlock() }

        var records = loadUnlocked()
        records.insert(record, at: 0)
        records = Array(records.prefix(50))
        if let data = try? encoder.encode(records) {
            defaults.set(data, forKey: Keys.records)
        }
    }

    func recent(limit: Int) -> [OperationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(loadUnlocked().prefix(limit))
    }

    private func loadUnlocked() -> [OperationRecord] {
        guard
            let data = defaults.data(forKey: Keys.records),
            let records = try? decoder.decode([OperationRecord].self, from: data)
        else {
            return []
        }
        return records
    }
}

