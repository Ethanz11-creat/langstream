import Foundation

/// Manages parallel transcription of audio slices with a limited number of workers.
/// Uses TaskGroup for concurrency control with a max worker limit.
final class ParallelTranscriber: @unchecked Sendable {
    private let provider: SpeechProvider
    private let maxWorkers: Int

    init(provider: SpeechProvider, maxWorkers: Int = 2) {
        self.provider = provider
        self.maxWorkers = maxWorkers
    }

    /// Transcribe a batch of slices with limited concurrency.
    /// Returns a dictionary mapping slice index to transcription text.
    func transcribe(slices: [AudioSlice], timeout: TimeInterval = 300) async -> [Int: String] {
        var results: [Int: String] = [:]

        guard !slices.isEmpty else { return [:] }

        let provider = self.provider
        let maxWorkers = self.maxWorkers

        await withTaskGroup(of: (index: Int, text: String?).self) { group in
            var iterator = slices.makeIterator()
            var submitted = 0

            // Submit initial batch up to maxWorkers
            while submitted < maxWorkers, let slice = iterator.next() {
                group.addTask {
                    let text = await transcribeOne(provider: provider, slice: slice, timeout: timeout)
                    return (slice.index, text)
                }
                submitted += 1
            }

            // As each task completes, submit the next one
            while let completed = await group.next() {
                if let text = completed.text {
                    results[completed.index] = text
                }

                // Submit next slice if available
                if let slice = iterator.next() {
                    group.addTask {
                        let text = await transcribeOne(provider: provider, slice: slice, timeout: timeout)
                        return (slice.index, text)
                    }
                    submitted += 1
                }
            }
        }

        return results
    }
}

/// Transcribe a single slice, catching errors gracefully.
private func transcribeOne(provider: SpeechProvider, slice: AudioSlice, timeout: TimeInterval) async -> String? {
    print("[ParallelTranscriber] Starting slice #\(slice.index) (\(String(format: "%.1f", slice.duration))s)")
    let startTime = Date()

    do {
        let text = try await provider.transcribe(audioData: slice.audioData, timeout: timeout)
        let elapsed = Date().timeIntervalSince(startTime)
        print("[ParallelTranscriber] Slice #\(slice.index) done in \(String(format: "%.1f", elapsed))s: '\(text.prefix(60))'")
        return text
    } catch {
        print("[ParallelTranscriber] Slice #\(slice.index) failed: \(error)")
        return nil
    }
}
