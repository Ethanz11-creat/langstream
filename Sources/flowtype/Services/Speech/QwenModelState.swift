import Foundation
import Combine

enum QwenModelStatus: Equatable {
    case notLoaded
    case downloading(progress: Double, status: String)
    case loading
    case ready
    case error(String)

    var isLoading: Bool {
        switch self {
        case .downloading, .loading: return true
        default: return false
        }
    }
}

@MainActor
final class QwenModelState: ObservableObject {
    static let shared = QwenModelState()

    @Published private(set) var status: QwenModelStatus = .notLoaded

    func loadModel(provider: QwenASRProvider) async {
        guard !status.isLoading else { return }

        if provider.isLoaded {
            status = .ready
            return
        }

        status = .downloading(progress: 0, status: "准备下载...")

        do {
            try await provider.loadModel { @Sendable progress, statusText in
                Task { @MainActor in
                    if progress >= 1.0 {
                        QwenModelState.shared.status = .loading
                    } else {
                        QwenModelState.shared.status = .downloading(progress: progress, status: statusText)
                    }
                }
            }
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}
