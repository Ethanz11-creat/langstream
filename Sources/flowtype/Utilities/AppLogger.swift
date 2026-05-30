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

    /// Security: maximum log file size (10 MB) before rotation
    private static let maxLogSize: UInt64 = 10 * 1024 * 1024
    /// Security: maximum number of rotated log files to keep
    private static let maxRotatedFiles = 3

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
            // Check if rotation is needed after writing
            try maybeRotateLog()
        } catch {
            try? fh.close()
            fileHandle = nil
            openHandle()
            try? fileHandle?.write(contentsOf: data)
        }
    }

    private static func maybeRotateLog() throws {
        guard let fh = fileHandle else { return }
        let currentOffset = fh.offsetInFile
        if currentOffset < maxLogSize { return }

        // Close current file and rotate
        try fh.close()
        fileHandle = nil

        let fm = FileManager.default
        let basePath = logPath

        // Delete oldest if at max
        let oldest = "\(basePath).\(maxRotatedFiles)"
        if fm.fileExists(atPath: oldest) {
            try? fm.removeItem(atPath: oldest)
        }

        // Shift existing rotated files
        for i in (1..<maxRotatedFiles).reversed() {
            let src = "\(basePath).\(i)"
            let dst = "\(basePath).\(i + 1)"
            if fm.fileExists(atPath: src) {
                try? fm.moveItem(atPath: src, toPath: dst)
            }
        }

        // Move current to .1
        if fm.fileExists(atPath: basePath) {
            try? fm.moveItem(atPath: basePath, toPath: "\(basePath).1")
        }

        // Create new file
        fm.createFile(atPath: basePath, contents: nil, attributes: nil)
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
