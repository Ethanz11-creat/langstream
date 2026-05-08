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
    /// Prefers paths that have a `.venv` directory already created.
    static func serverDirectory() -> URL? {
        let fm = FileManager.default
        let execPath = CommandLine.arguments[0]
        let execDir = URL(fileURLWithPath: execPath).deletingLastPathComponent()

        let candidates: [URL] = [
            // 1. Dev mode: current working directory
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("services/whisper_server"),
            // 2. Swift build products: two levels up from executable
            execDir.deletingLastPathComponent().appendingPathComponent("services/whisper_server"),
            // 3. .app bundle parent directory (project root when running from build/)
            // From: build/Flowtype.app/Contents/MacOS/FlowType
            // Up 1: Contents/MacOS/ → up 2: Flowtype.app/ → up 3: build/ → up 4: project root
            execDir.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("services/whisper_server"),
            // 4. .app bundle Resources
            execDir.deletingLastPathComponent().appendingPathComponent("Resources/services/whisper_server"),
            // 5. Relative to executable path
            execDir.appendingPathComponent("services/whisper_server"),
        ]

        var firstMatch: URL?
        for path in candidates {
            if fm.fileExists(atPath: path.path) {
                if firstMatch == nil { firstMatch = path }
                let venvPath = path.appendingPathComponent(".venv")
                if fm.fileExists(atPath: venvPath.path) {
                    return path // Prefer path with .venv already set up
                }
            }
        }
        return firstMatch
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
        // Use bash with the user's PATH to find uv, since `which` alone
        // only searches the system default PATH and misses e.g. ~/.local/bin.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "command -v uv"]
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
