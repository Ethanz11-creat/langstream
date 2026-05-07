import Foundation

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
    /// Locate the whisper_server directory relative to the project.
    static func serverDirectory() -> URL? {
        let fm = FileManager.default

        // 1. Try relative to current working directory (dev mode)
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let cwdPath = cwd.appendingPathComponent("services/whisper_server")
        if fm.fileExists(atPath: cwdPath.path) {
            return cwdPath
        }

        // 2. Try relative to executable path
        let execPath = CommandLine.arguments[0]
        let execDir = URL(fileURLWithPath: execPath).deletingLastPathComponent()
        let execRelPath = execDir.appendingPathComponent("services/whisper_server")
        if fm.fileExists(atPath: execRelPath.path) {
            return execRelPath
        }

        // 3. Try two levels up from executable (Swift build products)
        let execRelPath2 = execDir.deletingLastPathComponent().appendingPathComponent("services/whisper_server")
        if fm.fileExists(atPath: execRelPath2.path) {
            return execRelPath2
        }

        return nil
    }

    static func check() async -> WhisperSetupStatus {
        guard let serverDir = serverDirectory() else {
            return .unknown("找不到 services/whisper_server 目录")
        }

        // 1. Check uv
        if !checkUV() {
            return .uvMissing
        }

        // 2. Check venv
        let venvPath = serverDir.appendingPathComponent(".venv")
        if !FileManager.default.fileExists(atPath: venvPath.path) {
            return .venvMissing
        }

        // 3. Check deps
        let pythonPath = venvPath.appendingPathComponent("bin/python")
        if !FileManager.default.fileExists(atPath: pythonPath.path) {
            return .venvMissing
        }

        let depsOK = await checkDeps(pythonPath: pythonPath)
        if !depsOK {
            return .depsMissing
        }

        // 4. Check model cache
        if !checkModelCache() {
            return .modelMissing
        }

        return .ready
    }

    static func checkUV() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["uv"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
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

        // HuggingFace cache path
        let cachePath = home
            .appendingPathComponent(".cache")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
            .appendingPathComponent("models--mlx-community--whisper-large-v3-turbo")

        return fm.fileExists(atPath: cachePath.path)
    }
}
