import Foundation
import AppKit

// MARK: - Install Step (for progress callbacks)

enum InstallStep {
    case creatingVenv
    case installingDeps
    case downloadingModel
}

// MARK: - Thread-Safe Output Buffer

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func append(_ str: String) {
        lock.lock()
        _value += str
        lock.unlock()
    }
}

// MARK: - Setup Status

enum WhisperSetupStatus: Equatable, CustomStringConvertible {
    case ready
    case uvMissing
    case venvMissing
    case depsMissing
    case modelMissing
    case unknown(String)

    var description: String {
        switch self {
        case .ready: return "本地模型已就绪"
        case .uvMissing: return "uv 未安装"
        case .venvMissing: return "Python 虚拟环境未创建"
        case .depsMissing: return "Python 依赖未安装"
        case .modelMissing: return "模型未下载"
        case .unknown(let msg): return "未知错误: \(msg)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct WhisperSetupChecker {

    // MARK: - Directory Paths

    static func appSupportDirectory() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Flowtype/whisper_server", isDirectory: true)
    }

    static func bundleResourceDirectory() -> URL? {
        guard let resourcesURL = Bundle.main.resourceURL else { return nil }
        let spmBundleURL = resourcesURL.appendingPathComponent("FlowType_FlowType.bundle", isDirectory: true)
        let whisperServerURL = spmBundleURL.appendingPathComponent("whisper_server", isDirectory: true)
        return whisperServerURL
    }

    @discardableResult
    static func ensureResourcesInApplicationSupport() -> URL? {
        guard let appSupportDir = appSupportDirectory() else { return nil }
        guard let bundleDir = bundleResourceDirectory() else { return nil }

        let fm = FileManager.default

        let mainPyInAppSupport = appSupportDir.appendingPathComponent("main.py")
        if fm.fileExists(atPath: mainPyInAppSupport.path) {
            return appSupportDir
        }

        let mainPyInBundle = bundleDir.appendingPathComponent("main.py")
        guard fm.fileExists(atPath: mainPyInBundle.path) else {
            return nil
        }

        do {
            try fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

            let filesToCopy = ["main.py", "pyproject.toml", "requirements.txt"]
            for filename in filesToCopy {
                let src = bundleDir.appendingPathComponent(filename)
                let dst = appSupportDir.appendingPathComponent(filename)
                if fm.fileExists(atPath: src.path) {
                    if fm.fileExists(atPath: dst.path) {
                        try fm.removeItem(at: dst)
                    }
                    try fm.copyItem(at: src, to: dst)
                }
            }
            AppLogger.log("[WhisperSetupChecker] Copied skeleton files to \(appSupportDir.path)")
            return appSupportDir
        } catch {
            AppLogger.log("[WhisperSetupChecker] Failed to copy skeleton files: \(error)")
            return nil
        }
    }

    // MARK: - Server Directory Discovery

    static func serverDirectory() -> URL? {
        let fm = FileManager.default
        let execPath = CommandLine.arguments[0]
        let execDir = URL(fileURLWithPath: execPath).deletingLastPathComponent()

        let devCandidates: [URL] = [
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("services/whisper_server"),
            execDir.deletingLastPathComponent().appendingPathComponent("services/whisper_server"),
            execDir.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("services/whisper_server"),
        ]

        for path in devCandidates {
            let venvPath = path.appendingPathComponent(".venv")
            if fm.fileExists(atPath: path.path) && fm.fileExists(atPath: venvPath.path) {
                return path
            }
        }

        if let appSupportDir = appSupportDirectory() {
            let mainPy = appSupportDir.appendingPathComponent("main.py")
            if fm.fileExists(atPath: mainPy.path) {
                return appSupportDir
            }
        }

        for path in devCandidates {
            if fm.fileExists(atPath: path.path) {
                return path
            }
        }

        if let bundleDir = bundleResourceDirectory(), fm.fileExists(atPath: bundleDir.path) {
            return bundleDir
        }

        return nil
    }

    // MARK: - UV Resolution

    static func resolveUVPath() -> String? {
        if let resourcesURL = Bundle.main.resourceURL {
            let bundledUV = resourcesURL.appendingPathComponent("bin/uv")
            if FileManager.default.fileExists(atPath: bundledUV.path) {
                AppLogger.log("[WhisperSetupChecker] Found bundled uv at \(bundledUV.path)")
                return bundledUV.path
            }
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "command -v uv"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    AppLogger.log("[WhisperSetupChecker] Found system uv at \(path)")
                    return path
                }
            }
        } catch {}

        AppLogger.log("[WhisperSetupChecker] uv not found (bundled or system)")
        return nil
    }

    // MARK: - Environment Checks

    static func check() async -> WhisperSetupStatus {
        ensureResourcesInApplicationSupport()

        guard let serverDir = serverDirectory() else {
            return .unknown("找不到 services/whisper_server 目录")
        }

        if !checkUV() {
            return .uvMissing
        }

        let venvPath = serverDir.appendingPathComponent(".venv")
        if !FileManager.default.fileExists(atPath: venvPath.path) {
            return .venvMissing
        }

        let pythonPath = venvPath.appendingPathComponent("bin/python")
        if !FileManager.default.fileExists(atPath: pythonPath.path) {
            return .venvMissing
        }

        let depsOK = await checkDeps(pythonPath: pythonPath)
        if !depsOK {
            return .depsMissing
        }

        if !checkModelCache() {
            return .modelMissing
        }

        return .ready
    }

    static func checkUV() -> Bool {
        return resolveUVPath() != nil
    }

    static func checkDeps(pythonPath: URL) async -> Bool {
        let task = Process()
        task.executableURL = pythonPath
        task.arguments = [
            "-c",
            "import mlx_whisper, fastapi, uvicorn, multipart; print('ok')"
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return task.terminationStatus == 0 && output.contains("ok")
        } catch {
            return false
        }
    }

    static func checkModelCache() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let cachePath = home
            .appendingPathComponent(".cache")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
            .appendingPathComponent("models--mlx-community--whisper-large-v3-turbo")

        return fm.fileExists(atPath: cachePath.path)
    }

    // MARK: - Installation

    /// Run the installation process: create venv, install deps, pre-download model.
    /// Reports progress via `onStep` and `onDetail` callbacks.
    /// Returns nil on success, friendly error message on failure.
    static func runInstallation(
        serverDir: URL,
        onStep: @escaping (InstallStep) -> Void,
        onDetail: @escaping @Sendable (String) -> Void
    ) async -> String? {
        let fm = FileManager.default
        let venvPath = serverDir.appendingPathComponent(".venv")

        guard let uvPath = resolveUVPath() else {
            return "找不到 uv 包管理器。请确认应用完整或手动安装 uv。"
        }

        // 1. Create venv
        if !fm.fileExists(atPath: venvPath.path) {
            onStep(.creatingVenv)
            AppLogger.log("[WhisperSetupChecker] Creating virtual environment with \(uvPath)...")
            let msg = await runCommand(uvPath, args: ["venv"], cwd: serverDir)
            if let msg = msg {
                return friendlyError(raw: msg, step: .creatingVenv)
            }
        }

        let pythonPath = venvPath.appendingPathComponent("bin/python")
        guard fm.fileExists(atPath: pythonPath.path) else {
            return "虚拟环境创建后找不到 Python 可执行文件"
        }

        // 2. Install dependencies (with streaming output)
        onStep(.installingDeps)
        AppLogger.log("[WhisperSetupChecker] Installing Python dependencies with \(uvPath)...")
        let pipMsg = await runCommandStreaming(uvPath, args: ["pip", "install", "-r", "requirements.txt"], cwd: serverDir, onLine: onDetail)
        if let msg = pipMsg {
            return friendlyError(raw: msg, step: .installingDeps)
        }

        // 3. Pre-download model
        let hasModel = checkModelCache()
        onStep(.downloadingModel)
        if hasModel {
            onDetail("模型已缓存，正在验证...")
        }
        AppLogger.log("[WhisperSetupChecker] Pre-downloading model (cached=\(hasModel))...")
        let model = Configuration.shared.whisperModel
        let pythonScript = """
        import mlx_whisper
        import numpy as np
        dummy = np.zeros(16000, dtype=np.float32)
        mlx_whisper.transcribe(dummy, path_or_hf_repo='\(model)', verbose=False)
        print('ok')
        """

        let modelMsg = await runCommandStreaming(pythonPath.path, args: ["-c", pythonScript], cwd: serverDir, onLine: onDetail)
        if let msg = modelMsg {
            return friendlyError(raw: msg, step: .downloadingModel)
        }

        AppLogger.log("[WhisperSetupChecker] Installation complete")
        return nil
    }

    /// Returns nil on success, error message on failure.
    private static func runCommand(_ command: String, args: [String], cwd: URL) async -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        let escapedArgs = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let argStr = escapedArgs.joined(separator: " ")
        let script = "cd '\(cwd.path)' && \(command) \(argStr)"
        task.arguments = ["-lc", script]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                return nil
            } else {
                let output = String(data: data, encoding: .utf8) ?? ""
                return output.isEmpty ? "exit code \(task.terminationStatus)" : output
            }
        } catch {
            return error.localizedDescription
        }
    }

    /// Like `runCommand` but streams stdout/stderr line-by-line via `onLine`.
    private static func runCommandStreaming(
        _ command: String,
        args: [String],
        cwd: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        let escapedArgs = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let argStr = escapedArgs.joined(separator: " ")
        let script = "cd '\(cwd.path)' && \(command) \(argStr)"
        task.arguments = ["-lc", script]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let buffer = OutputBuffer()

        do {
            try task.run()
        } catch {
            return error.localizedDescription
        }

        return await withCheckedContinuation { continuation in
            let fd = pipe.fileHandleForReading.fileDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty {
                    source.cancel()
                    return
                }
                if let str = String(data: data, encoding: .utf8) {
                    buffer.append(str)
                    let lines = str.split(separator: "\n", omittingEmptySubsequences: true)
                    if let lastLine = lines.last {
                        let trimmed = String(lastLine).trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            onLine(String(trimmed.prefix(120)))
                        }
                    }
                }
            }
            source.setCancelHandler {
                pipe.fileHandleForReading.closeFile()
            }
            source.resume()

            task.terminationHandler = { process in
                source.cancel()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    let output = buffer.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: output.isEmpty ? "exit code \(process.terminationStatus)" : output)
                }
            }
        }
    }

    // MARK: - Friendly Error Mapping

    private static func friendlyError(raw: String, step: InstallStep) -> String {
        let lower = raw.lowercased()

        if lower.contains("could not resolve host") || lower.contains("network is unreachable") || lower.contains("urlopen error") {
            return "网络连接失败，请检查网络后重试。"
        }
        if lower.contains("connectionreseterror") || lower.contains("connection reset") {
            return "下载中断（连接被重置），请检查网络稳定性后重试。"
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "连接超时，请检查网络或尝试使用代理。"
        }
        if lower.contains("no space left on device") || lower.contains("disk full") {
            return "磁盘空间不足，模型约需 1.6 GB 可用空间。"
        }
        if lower.contains("permission denied") {
            return "权限不足，无法写入安装目录。请检查文件权限。"
        }
        if lower.contains("no module named") {
            return "Python 依赖缺失，请尝试重新安装。"
        }
        if lower.contains("failed building wheel") || lower.contains("compilation error") {
            return "依赖编译失败。请确认已安装 Xcode Command Line Tools (xcode-select --install)。"
        }

        let truncated = String(raw.prefix(200))
        switch step {
        case .creatingVenv:
            return "创建 Python 环境失败: \(truncated)"
        case .installingDeps:
            return "安装依赖失败: \(truncated)"
        case .downloadingModel:
            return "模型下载失败: \(truncated)"
        }
    }

    // MARK: - Model Cache Info

    static func modelCacheSize() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cachePath = home
            .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo")

        guard fm.fileExists(atPath: cachePath.path) else { return nil }

        guard let enumerator = fm.enumerator(at: cachePath, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var totalSize: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
}
