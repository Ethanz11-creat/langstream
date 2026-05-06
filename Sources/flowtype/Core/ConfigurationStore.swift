import Foundation
import Combine

class ConfigurationStore: ObservableObject, @unchecked Sendable {
    static let shared = ConfigurationStore()

    @Published var current: Configuration

    private let defaultsKey = "flowtype.config"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let config = try? JSONDecoder().decode(Configuration.self, from: data) {
            self.current = config
        } else {
            self.current = Configuration.default
        }
    }

    private var saveWorkItem: DispatchWorkItem?

    func save(_ config: Configuration) {
        // Update in-memory state immediately so UI responds
        self.current = config

        // Debounce disk write: cancel pending save and schedule a new one
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: self.defaultsKey)
            }
        }
        self.saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
}
