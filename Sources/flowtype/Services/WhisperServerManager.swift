import Foundation
import SwiftUI

/// Manages the full lifecycle of the local Whisper ASR service:
/// environment check → installation → server start → health polling → ready.
/// Single source of truth for all ASR status UI (onboarding, settings, menu bar).
final class WhisperServerManager: ObservableObject, @unchecked Sendable {
    static let shared = WhisperServerManager()

    @Published private(set) var serverStage: ServerStage = .notStarted
    @Published var lastError: String?
    @Published var installDetail: String?

    nonisolated(unsafe) private var _isServerReady: Bool = false
    nonisolated var isServerReady: Bool { _isServerReady }

    private var process: Process?
    nonisolated(unsafe) private var _serverPort: Int?
    nonisolated var port: Int? { _serverPort }
    private var healthCheckTask: Task<Void, Never>?

    private var restartCount: Int = 0
    private let maxRestarts = 3
    private var restartTask: Task<Void, Never>?
    private var intentionalStop = false

    // MARK: - Server Stage

    enum ServerStage: String, Equatable {
        case notStarted       = "未启动"
        case checking         = "检查环境中..."
        case needsInstall     = "环境未安装"
        case installingVenv   = "正在创建 Python 环境..."
        case installingDeps   = "正在安装依赖..."
        case downloadingModel = "正在下载模型..."
        case starting         = "启动服务中..."
        case processStarted   = "进程已启动"
        case modelLoading     = "模型加载中..."
        case ready            = "模型已就绪"
        case restarting       = "正在重启..."
        case error            = "错误"
    }

    // MARK: - Public API

    func checkAndStart() async {
        guard serverStage == .notStarted || serverStage == .error else {
            AppLogger.log("[WhisperServerManager] checkAndStart: already in progress or ready (stage=\(serverStage))")
            return
        }

        WhisperSetupChecker.ensureResourcesInApplicationSupport()

        serverStage = .checking
        lastError = nil
        installDetail = nil
        AppLogger.log("[WhisperServerManager] Checking environment...")

        let status = await WhisperSetupChecker.check()
        AppLogger.log("[WhisperServerManager] Environment check result: \(status)")

        if !status.isReady {
            serverStage = .needsInstall
            print("[WhisperServerManager] Environment not ready: \(status)")
            return
        }

        await startServer()
    }

    func startServer() async {
        guard serverStage != .ready else { return }

        intentionalStop = false
        restartCount = 0
        serverStage = .starting
        lastError = nil
        installDetail = nil

        await launchAndWaitForReady()
    }

    /// One-click install: creates venv, installs deps, downloads model, then starts server.
    func install() async {
        guard !serverStage.isInstalling else {
            AppLogger.log("[WhisperServerManager] install: already installing")
            return
        }

        lastError = nil
        installDetail = nil
        serverStage = .installingVenv

        WhisperSetupChecker.ensureResourcesInApplicationSupport()

        guard let serverDir = WhisperSetupChecker.serverDirectory() else {
            serverStage = .error
            lastError = "找不到 whisper_server 目录"
            return
        }

        let result = await WhisperSetupChecker.runInstallation(
            serverDir: serverDir,
            onStep: { [weak self] step in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch step {
                    case .creatingVenv:    self.serverStage = .installingVenv
                    case .installingDeps:  self.serverStage = .installingDeps
                    case .downloadingModel: self.serverStage = .downloadingModel
                    }
                }
            },
            onDetail: { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.installDetail = line
                }
            }
        )

        if let error = result {
            serverStage = .error
            lastError = error
            AppLogger.log("[WhisperServerManager] Installation failed: \(error)")
        } else {
            installDetail = nil
            AppLogger.log("[WhisperServerManager] Installation succeeded, starting server...")
            await launchAndWaitForReady()
        }
    }

    /// Smart retry: re-checks environment, then either installs or restarts server.
    func retry() async {
        guard serverStage == .error || serverStage == .needsInstall else { return }

        lastError = nil
        installDetail = nil
        serverStage = .checking

        let status = await WhisperSetupChecker.check()
        if !status.isReady {
            await install()
        } else {
            await startServer()
        }
    }

    /// Manual restart triggered by user (resets retry counter).
    func restartServer() async {
        AppLogger.log("[WhisperServerManager] Manual restart requested")
        stopServerInternal()
        intentionalStop = false
        restartCount = 0
        serverStage = .starting
        lastError = nil
        installDetail = nil
        await launchAndWaitForReady()
    }

    func stopServer() {
        intentionalStop = true
        restartTask?.cancel()
        restartTask = nil
        stopServerInternal()
    }

    // MARK: - Private

    private func stopServerInternal() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        process?.terminate()
        process = nil
        _serverPort = nil
        _isServerReady = false
        serverStage = .notStarted
    }

    private func launchAndWaitForReady() async {
        serverStage = .starting
        do {
            try await launchPythonProcess()
            serverStage = .processStarted

            let ready = await waitForReady(timeout: 120)
            if ready {
                serverStage = .ready
                _isServerReady = true
                restartCount = 0
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

    private func handleUnexpectedTermination(exitCode: Int32) {
        Task { @MainActor [weak self] in
            guard let self = self, !self.intentionalStop else { return }
            guard self.restartCount < self.maxRestarts else {
                self.serverStage = .error
                self._isServerReady = false
                self.lastError = "服务连续崩溃 \(self.maxRestarts) 次，已停止自动重启"
                AppLogger.log("[WhisperServerManager] Max restarts reached (\(self.maxRestarts)), giving up")
                return
            }

            self.restartCount += 1
            let delay = UInt64(pow(2.0, Double(self.restartCount)))
            AppLogger.log("[WhisperServerManager] Process exited (\(exitCode)), auto-restart #\(self.restartCount) in \(delay)s")
            self.serverStage = .restarting
            self._isServerReady = false
            self._serverPort = nil
            self.lastError = "服务意外退出，正在重启 (\(self.restartCount)/\(self.maxRestarts))..."

            self.restartTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                await self.launchAndWaitForReady()
            }
        }
    }

    private func launchPythonProcess() async throws {
        guard let serverDir = WhisperSetupChecker.serverDirectory() else {
            AppLogger.log("[WhisperServerManager] launchPythonProcess: serverDirectory not found")
            throw ServerError.serverDirectoryNotFound
        }
        AppLogger.log("[WhisperServerManager] launchPythonProcess: serverDir=\(serverDir.path)")

        let pythonPath = serverDir.appendingPathComponent(".venv/bin/python")
        let mainPyPath = serverDir.appendingPathComponent("main.py")
        AppLogger.log("[WhisperServerManager] pythonPath=\(pythonPath.path), exists=\(FileManager.default.fileExists(atPath: pythonPath.path))")
        AppLogger.log("[WhisperServerManager] mainPyPath=\(mainPyPath.path), exists=\(FileManager.default.fileExists(atPath: mainPyPath.path))")

        guard FileManager.default.fileExists(atPath: pythonPath.path) else {
            AppLogger.log("[WhisperServerManager] Python not found at \(pythonPath.path)")
            throw ServerError.pythonNotFound
        }
        guard FileManager.default.fileExists(atPath: mainPyPath.path) else {
            AppLogger.log("[WhisperServerManager] main.py not found at \(mainPyPath.path)")
            throw ServerError.mainScriptNotFound
        }

        let config = Configuration.shared
        let model = config.whisperModel
        let language = config.whisperLanguage.rawValue
        AppLogger.log("[WhisperServerManager] Launching with model=\(model), language=\(language)")

        let task = Process()
        task.executableURL = pythonPath
        task.arguments = [
            mainPyPath.path,
            "--model", model,
            "--language", language,
        ]
        task.currentDirectoryURL = serverDir

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        task.terminationHandler = { [weak self] process in
            guard let self = self else { return }
            let exitCode = process.terminationStatus
            if exitCode != 0 && !self.intentionalStop {
                self.handleUnexpectedTermination(exitCode: exitCode)
            }
        }

        try task.run()
        self.process = task
        AppLogger.log("[WhisperServerManager] Python process launched, waiting for port...")

        let fd = stderrPipe.fileHandleForReading.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global())
            source.setEventHandler {
                let data = stderrPipe.fileHandleForReading.availableData
                if data.isEmpty {
                    source.cancel()
                    return
                }
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                    AppLogger.log("[WhisperServer-stderr] \(str)")
                }
            }
            source.setCancelHandler {
                stderrPipe.fileHandleForReading.closeFile()
            }
        source.resume()

        let port = try await self.readPortFromStdout(pipe: stdoutPipe, timeout: 15)

        guard let port = port else {
            AppLogger.log("[WhisperServerManager] Failed to read port from stdout")
            task.terminate()
            throw ServerError.portNotReceived
        }

        self._serverPort = port
        AppLogger.log("[WhisperServerManager] Python process started, port \(port)")
    }

    private func readPortFromStdout(pipe: Pipe, timeout: TimeInterval = 15) async throws -> Int? {
        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        var accumulatedOutput = ""

        while Date() < deadline {
            if Task.isCancelled {
                return nil
            }

            let data = handle.availableData
            if !data.isEmpty {
                if let str = String(data: data, encoding: .utf8) {
                    accumulatedOutput += str
                    AppLogger.log("[WhisperServerManager] stdout chunk: \(str.prefix(200).replacingOccurrences(of: "\n", with: "\\n"))")
                    if let match = accumulatedOutput.range(of: "SERVER_PORT=") {
                        let start = accumulatedOutput.index(match.upperBound, offsetBy: 0)
                        let remainder = String(accumulatedOutput[start...])
                        if let newlineRange = remainder.range(of: "\n") {
                            let portStr = String(remainder[..<newlineRange.lowerBound])
                            if let port = Int(portStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                AppLogger.log("[WhisperServerManager] Found SERVER_PORT=\(port)")
                                return port
                            }
                        } else if let port = Int(remainder.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            AppLogger.log("[WhisperServerManager] Found SERVER_PORT=\(port)")
                            return port
                        }
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        AppLogger.log("[WhisperServerManager] Port read timeout. Accumulated output: \(accumulatedOutput.prefix(500).replacingOccurrences(of: "\n", with: "\\n"))")
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
                            self.serverStage = .ready
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

// MARK: - ServerStage UI Properties

extension WhisperServerManager.ServerStage {

    var isInstalling: Bool {
        switch self {
        case .installingVenv, .installingDeps, .downloadingModel: return true
        default: return false
        }
    }

    var isTransient: Bool {
        switch self {
        case .checking, .installingVenv, .installingDeps, .downloadingModel,
             .starting, .processStarted, .modelLoading, .restarting:
            return true
        default:
            return false
        }
    }

    var canInstall: Bool {
        self == .needsInstall
    }

    var canRetry: Bool {
        self == .error
    }

    var iconName: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .modelLoading, .starting, .processStarted, .checking, .restarting,
             .installingVenv, .installingDeps, .downloadingModel:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .needsInstall, .notStarted:
            return "exclamationmark.circle.fill"
        case .error:
            return "xmark.circle.fill"
        }
    }

    var statusColor: Color {
        switch self {
        case .ready:
            return .green
        case .modelLoading, .starting, .processStarted, .checking, .restarting,
             .installingVenv, .installingDeps, .downloadingModel:
            return .orange
        case .needsInstall, .notStarted, .error:
            return .red
        }
    }

    var statusTitle: String {
        switch self {
        case .ready:            return "本地模型已就绪"
        case .modelLoading:     return "模型加载中..."
        case .starting, .processStarted, .checking:
                                return "服务启动中..."
        case .restarting:       return "服务重启中..."
        case .installingVenv:   return "正在创建 Python 环境..."
        case .installingDeps:   return "正在安装依赖..."
        case .downloadingModel: return "正在下载模型..."
        case .needsInstall:     return "本地 ASR 未安装"
        case .notStarted:       return "本地 ASR 未启动"
        case .error:            return "服务启动失败"
        }
    }
}
