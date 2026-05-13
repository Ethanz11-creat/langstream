import Foundation
import AppKit

/// File-based logger that writes to ~/Library/Logs/flowtype/diagnostic.log.
/// Use this instead of `print()` for persistent diagnostics — stdout is lost
/// inside .app bundles.
enum AppLogger {
    private static let logDir: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/flowtype")
    }()

    private static let logPath: String = {
        (logDir as NSString).appendingPathComponent("diagnostic.log")
    }()

    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f
    }()

    private nonisolated(unsafe) static let queue = DispatchQueue(label: "com.flowtype.logger", qos: .utility)
    private nonisolated(unsafe) static var fileHandle: FileHandle?

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { writeData(data) }
    }

    static func openLogInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    static var logFileURL: URL {
        URL(fileURLWithPath: logPath)
    }

    private static func writeData(_ data: Data) {
        if fileHandle == nil {
            openHandle()
        }
        guard let fh = fileHandle else { return }
        do {
            try fh.write(contentsOf: data)
        } catch {
            try? fh.close()
            fileHandle = nil
            openHandle()
            try? fileHandle?.write(contentsOf: data)
        }
    }

    private static func openHandle() {
        do {
            try FileManager.default.createDirectory(
                atPath: logDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
            }
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
            fh.seekToEndOfFile()
            fileHandle = fh
        } catch {
            // Silent fail — logging must never crash the app
        }
    }
}
