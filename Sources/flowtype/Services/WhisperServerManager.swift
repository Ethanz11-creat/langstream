import Foundation

/// Manages the lifecycle of the local Python Whisper server.
/// - Checks environment readiness on app startup
/// - Starts the Python process when environment is ready
/// - Reads the dynamic port from stdout
/// - Polls /health until model is loaded
/// - Falls back to AppleSpeech if server is not available
final class WhisperServerManager: ObservableObject, @unchecked Sendable {
    static let shared = WhisperServerManager()

    @Published private(set) var serverStage: ServerStage = .notStarted
    @Published var lastError: String?

    // These are accessed from nonisolated contexts (e.g. SpeechRouter init),
    // so we use nonisolated(unsafe) since they are write-once-read-many.
    nonisolated(unsafe) private var _isServerReady: Bool = false
    nonisolated var isServerReady: Bool { _isServerReady }

    private var process: Process?
    nonisolated(unsafe) private var _serverPort: Int?
    nonisolated var port: Int? { _serverPort }
    private var healthCheckTask: Task<Void, Never>?

    enum ServerStage: String, Equatable {
        case notStarted       = "未启动"
        case checking         = "检查环境中..."
        case envMissing       = "环境未安装"
        case starting         = "启动服务中..."
        case processStarted   = "进程已启动"
        case modelLoading     = "模型加载中..."
        case modelLoaded      = "模型已就绪"
        case error            = "启动失败"
    }

    // MARK: - Public API

    /// Check environment and start server if everything is ready.
    /// If env is missing, sets stage to .envMissing and does NOT auto-install.
    func checkAndStart() async {
        guard serverStage == .notStarted || serverStage == .error else {
            return // Already in progress or ready
        }

        serverStage = .checking
        lastError = nil

        let status = await WhisperSetupChecker.check()

        if !status.isReady {
            serverStage = .envMissing
            print("[WhisperServerManager] Environment not ready: \(status)")
            return
        }

        await startServer()
    }

    /// Force-start the server (called after user clicks "Install" + setup completes).
    func startServer() async {
        guard serverStage != .modelLoaded else { return }

        serverStage = .starting
        lastError = nil

        do {
            try await launchPythonProcess()
            serverStage = .processStarted

            // Wait for model to be loaded
            let ready = await waitForReady(timeout: 120)
            if ready {
                serverStage = .modelLoaded
                _isServerReady = true
                print("[WhisperServerManager] Server ready on port \(_serverPort ?? 0)")
            } else {
                serverStage = .error
                _isServerReady = false
                lastError = "模型加载超时"
                print("[WhisperServerManager] Model loading timed out")
            }
        } catch {
            serverStage = .error
            _isServerReady = false
            lastError = error.localizedDescription
            print("[WhisperServerManager] Failed to start server: \(error)")
        }
    }

    func stopServer() {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        process?.terminate()
        process = nil

        _serverPort = nil
        _isServerReady = false
        serverStage = .notStarted
    }

    // MARK: - Private

    private func launchPythonProcess() async throws {
        guard let serverDir = WhisperSetupChecker.serverDirectory() else {
            throw ServerError.serverDirectoryNotFound
        }

        let pythonPath = serverDir.appendingPathComponent(".venv/bin/python")
        let mainPyPath = serverDir.appendingPathComponent("main.py")

        guard FileManager.default.fileExists(atPath: pythonPath.path) else {
            throw ServerError.pythonNotFound
        }
        guard FileManager.default.fileExists(atPath: mainPyPath.path) else {
            throw ServerError.mainScriptNotFound
        }

        let config = Configuration.shared
        let model = config.whisperModel
        let language = config.whisperLanguage.rawValue

        let task = Process()
        task.executableURL = pythonPath
        task.arguments = [
            mainPyPath.path,
            "--model", model,
            "--language", language,
        ]
        task.currentDirectoryURL = serverDir

        // Capture stdout to read SERVER_PORT
        let stdoutPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = FileHandle.nullDevice

        // Set up termination handler
        task.terminationHandler = { [weak self] process in
            Task { [weak self] in
                guard let self = self else { return }
                if process.terminationStatus != 0 && self.serverStage != .notStarted {
                    self.serverStage = .error
                    self._isServerReady = false
                    self.lastError = "Python process exited with code \(process.terminationStatus)"
                }
            }
        }

        try task.run()
        self.process = task

        // Read stdout asynchronously to find SERVER_PORT
        let port = try await self.readPortFromStdout(pipe: stdoutPipe, timeout: 10)

        guard let port = port else {
            task.terminate()
            throw ServerError.portNotReceived
        }

        self._serverPort = port
        print("[WhisperServerManager] Python process started, port \(port)")
    }

    private func readPortFromStdout(pipe: Pipe, timeout: TimeInterval = 10) async throws -> Int? {
        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if Task.isCancelled {
                return nil
            }

            if let data = try? handle.read(upToCount: 1024), !data.isEmpty {
                if let str = String(data: data, encoding: .utf8) {
                    // Look for SERVER_PORT=xxxx pattern
                    if let match = str.range(of: "SERVER_PORT=") {
                        let start = str.index(match.upperBound, offsetBy: 0)
                        let remainder = String(str[start...])
                        if let newlineRange = remainder.range(of: "\n") {
                            let portStr = String(remainder[..<newlineRange.lowerBound])
                            if let port = Int(portStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                return port
                            }
                        } else if let port = Int(remainder.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            return port
                        }
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return nil
    }

    private func waitForReady(timeout: TimeInterval) async -> Bool {
        guard let port = _serverPort else { return false }

        let startTime = Date()
        let url = URL(string: "http://127.0.0.1:\(port)/health")!

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let stage = json["stage"] as? String {

                    await MainActor.run {
                        switch stage {
                        case "model_loaded":
                            self.serverStage = .modelLoaded
                        case "model_loading":
                            self.serverStage = .modelLoading
                        case "process_started", "deps_ready":
                            self.serverStage = .processStarted
                        default:
                            break
                        }
                    }

                    if stage == "model_loaded" {
                        return true
                    }
                }
            } catch {
                // Server not responding yet, keep polling
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return false
    }

    // MARK: - Errors

    enum ServerError: Error, LocalizedError {
        case serverDirectoryNotFound
        case pythonNotFound
        case mainScriptNotFound
        case portNotReceived

        var errorDescription: String? {
            switch self {
            case .serverDirectoryNotFound:
                return "找不到 whisper_server 目录"
            case .pythonNotFound:
                return "找不到 Python 虚拟环境"
            case .mainScriptNotFound:
                return "找不到 main.py"
            case .portNotReceived:
                return "无法获取服务端口"
            }
        }
    }
}
