import Foundation

/// Accumulates transcription results into a growing text stream with
/// stable (frozen) and pending (revisable) regions.
///
/// Results are processed in index order via an internal reorder buffer.
/// Low-quality segments (empty, hallucination) are discarded. Overlap
/// between adjacent segments is deduplicated using edit-distance alignment.
final class StableTextAccumulator: @unchecked Sendable {
    // MARK: - Public State

    private(set) var stablePrefix: String = ""
    private(set) var lastStableQuality: SegmentQuality = .normal

    // MARK: - Internal State

    private var pendingTail: String = ""
    private var pendingQuality: SegmentQuality = .normal
    private var nextExpectedIndex: Int = 1
    private var resultBuffer: [Int: SegmentResult] = [:]
    private var lastSnapshot: TextSnapshot = TextSnapshot(stable: "", pending: "", fullText: "")

    // MARK: - Configuration

    /// Estimated Chinese speech rate in characters per second.
    private let charsPerSecond: Double = 4.0

    // MARK: - Public API

    /// Accept a transcription result. Results may arrive out of order;
    /// they are buffered and processed sequentially by index.
    func accept(_ result: SegmentResult) -> TextSnapshot {
        resultBuffer[result.index] = result

        while let next = resultBuffer[nextExpectedIndex] {
            resultBuffer.removeValue(forKey: nextExpectedIndex)
            nextExpectedIndex += 1
            processInOrder(next)
        }

        lastSnapshot = TextSnapshot(
            stable: stablePrefix,
            pending: pendingTail,
            fullText: stablePrefix + pendingTail
        )
        return lastSnapshot
    }

    /// Force-freeze all pending content. Called when recording ends.
    func finalize() -> String {
        if !pendingTail.isEmpty {
            stablePrefix += pendingTail
            lastStableQuality = pendingQuality
            pendingTail = ""
        }
        return stablePrefix
    }

    // MARK: - Sequential Processing

    private func processInOrder(_ result: SegmentResult) {
        // 1. Anomaly filter
        switch result.quality {
        case .empty:
            AppLogger.log("[Accumulator] Segment #\(result.index): skipped (quality=empty)")
            return
        case .hallucination:
            AppLogger.log("[Accumulator] Segment #\(result.index): skipped (quality=hallucination)")
            return
        case .normal, .fallback:
            break
        }

        // 2. Freeze previous pending
        if !pendingTail.isEmpty {
            stablePrefix += pendingTail
            lastStableQuality = pendingQuality
        }

        // 3. Overlap dedup
        var newText = result.text.trimmingCharacters(in: .whitespaces)
        if !stablePrefix.isEmpty && result.overlapDuration > 0 {
            newText = deduplicateOverlap(newText: newText, overlapDuration: result.overlapDuration)
        }

        // 4. Boundary repair
        newText = repairBoundary(newText: newText)

        // 5. Update pending
        pendingTail = newText
        pendingQuality = result.quality

        AppLogger.log("[Accumulator] Segment #\(result.index): accepted, stable=\(stablePrefix.count) chars, pending=\(pendingTail.count) chars")
    }

    // MARK: - Overlap Deduplication

    private func deduplicateOverlap(newText: String, overlapDuration: Double) -> String {
        let estimatedOverlapChars = Int(overlapDuration * charsPerSecond)
        let searchWindow = max(10, estimatedOverlapChars * 2)

        let anchorLen = min(stablePrefix.count, searchWindow)
        guard anchorLen >= 5 else { return newText }

        let anchor = String(stablePrefix.suffix(anchorLen))

        let trimCount = EditDistance.findOverlapTrim(
            anchor: anchor,
            candidate: newText,
            searchWindow: searchWindow
        )

        if trimCount > 0 && trimCount < newText.count {
            let trimmed = String(newText.dropFirst(trimCount))
            AppLogger.log("[Accumulator] Overlap dedup: removed \(trimCount) chars from segment prefix")
            return trimmed
        }

        return newText
    }

    // MARK: - Boundary Repair

    private func repairBoundary(newText: String) -> String {
        guard !stablePrefix.isEmpty, !newText.isEmpty else { return newText }

        let stableLast = stablePrefix.last!
        let newFirst = newText.first!

        // Deduplicate overlapping punctuation at boundary
        let punctuation: Set<Character> = ["，", "。", "！", "？", "；", "、", ",", ".", "!", "?", ";"]
        if punctuation.contains(stableLast) && stableLast == newFirst {
            return String(newText.dropFirst())
        }

        // Chinese text: no space separator needed
        let isChinese = stableLast.isChineseCharacter || newFirst.isChineseCharacter
        if isChinese {
            return newText
        }

        // English/mixed: ensure single space between words
        if !stableLast.isWhitespace && !newFirst.isWhitespace && !punctuation.contains(newFirst) {
            return " " + newText
        }

        return newText
    }
}

// MARK: - Character Extension

private extension Character {
    var isChineseCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)    // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(value)    // CJK Extension A
            || (0x20000...0x2A6DF).contains(value)  // CJK Extension B
            || (0x3000...0x303F).contains(value)    // CJK Symbols and Punctuation
            || (0xFF00...0xFFEF).contains(value)    // Fullwidth Forms
    }
}
