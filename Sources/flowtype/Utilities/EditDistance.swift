import Foundation

enum EditDistance {
    /// Compute Levenshtein edit distance between two strings (character-level).
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,         // deletion
                    curr[j - 1] + 1,     // insertion
                    prev[j - 1] + cost   // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    /// Find the best overlap alignment between the suffix of `anchor` and the
    /// prefix of `candidate`.
    ///
    /// Searches for a suffix of `anchor` (lengths 5, 8, 12, 16, 20, ...) that
    /// matches a prefix of `candidate` within an edit distance ratio of
    /// `maxRatio` (default 0.3). Returns the number of characters to trim from
    /// the front of `candidate` to remove the overlap, or 0 if no overlap found.
    static func findOverlapTrim(
        anchor: String,
        candidate: String,
        searchWindow: Int,
        maxRatio: Double = 0.3
    ) -> Int {
        guard !anchor.isEmpty, !candidate.isEmpty, searchWindow >= 5 else { return 0 }

        let anchorChars = Array(anchor)
        let candidateChars = Array(candidate)
        let anchorLen = anchorChars.count
        let candidateLen = candidateChars.count

        let maxAnchorSuffix = min(anchorLen, searchWindow)
        let maxCandidatePrefix = min(candidateLen, searchWindow)

        var bestTrim = 0
        var bestScore = Double.infinity

        // Try suffix lengths: 5, 8, 12, 16, 20, ...
        var suffixLen = 5
        while suffixLen <= maxAnchorSuffix {
            let suffix = String(anchorChars[(anchorLen - suffixLen)...])

            // Slide over candidate prefixes of similar length (+/- 30%)
            let minPrefixLen = max(3, Int(Double(suffixLen) * 0.7))
            let maxPrefixLen = min(maxCandidatePrefix, Int(Double(suffixLen) * 1.3))

            for prefixLen in minPrefixLen...maxPrefixLen {
                let prefix = String(candidateChars[0..<prefixLen])
                let dist = distance(suffix, prefix)
                let ratio = Double(dist) / Double(max(suffixLen, prefixLen))

                if ratio < maxRatio && ratio < bestScore {
                    bestScore = ratio
                    bestTrim = prefixLen
                }
            }

            if suffixLen < 8 { suffixLen = 8 }
            else { suffixLen += 4 }
        }

        return bestTrim
    }
}
