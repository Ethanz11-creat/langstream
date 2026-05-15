import Foundation

enum PersistenceError: Error {
    case directoryCreationFailed(Error)
    case writeFailed(Error)
    case readFailed(Error)
    case decodeFailed(Error)
}

struct PersistentStore<T: Codable> {
    let fileURL: URL

    private static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("FlowType", isDirectory: true)
    }

    init(filename: String) {
        self.fileURL = Self.appSupportDir.appendingPathComponent(filename)
    }

    func load() -> T? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            AppLogger.log("[Persistence] Failed to load \(fileURL.lastPathComponent): \(error)")
            return nil
        }
    }

    func save(_ value: T) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)

            let tmpURL = dir.appendingPathComponent(".\(fileURL.lastPathComponent).tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            AppLogger.log("[Persistence] Failed to save \(fileURL.lastPathComponent): \(error)")
        }
    }
}
