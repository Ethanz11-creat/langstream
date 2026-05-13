import Foundation

/// Post-processes raw ASR text: whitespace normalization, filler stripping,
/// tech term correction, and common ASR error fixes.
struct ASRPostProcessor {
    private let techTerms: [(pattern: String, replacement: String)]
    private let fillers: [String]

    init() {
        self.techTerms = Self.loadTechTerms()
        self.fillers = Self.loadFillers()
    }

    private static let shared = ASRPostProcessor()

    /// Main entry point. Applies the full pipeline.
    static func process(_ text: String) -> String {
        let processor = shared
        var result = text
        result = processor.normalizeWhitespace(result)
        result = processor.stripFillers(result)
        result = processor.correctTechTerms(result)
        result = processor.fixCommonASRErrors(result)
        result = processor.convertPunctuationForChinese(result)
        result = processor.normalizeWhitespace(result)
        return result
    }

    // MARK: - Pipeline steps

    func normalizeWhitespace(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Conservative filler removal. Only removes fillers that appear as
    /// standalone tokens (surrounded by spaces or at boundaries).
    func stripFillers(_ text: String) -> String {
        var result = text
        for filler in fillers.sorted(by: { $0.count > $1.count }) {
            let patterns = [
                " \(filler) ",
                "^\(filler) ",
                " \(filler)$",
                "^\(filler)$"
            ]
            for pattern in patterns {
                result = result.replacingOccurrences(
                    of: pattern,
                    with: " ",
                    options: .regularExpression
                )
            }
        }
        return normalizeWhitespace(result)
    }

    /// Corrects tech terms using case-insensitive regex with word boundaries.
    func correctTechTerms(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in techTerms {
            // Escape regex special chars in pattern, replace spaces with \s+
            let escaped = pattern
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ".", with: "\\.")
                .replacingOccurrences(of: "+", with: "\\+")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "?", with: "\\?")
                .replacingOccurrences(of: "^", with: "\\^")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "{", with: "\\{")
                .replacingOccurrences(of: "}", with: "\\}")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
                .replacingOccurrences(of: " ", with: "\\s+")

            let regexPattern = "(?i)\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: regexPattern, options: []) else { continue }
            let range = NSRange(location: 0, length: result.utf16.count)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }

    /// Fixes common ASR artifacts: consecutive duplicate chars, etc.
    func fixCommonASRErrors(_ text: String) -> String {
        var result = text
        // Remove consecutive duplicate chars (3+ in a row -> 1)
        let chars = Array(result)
        guard chars.count >= 3 else { return result }

        var cleaned: [Character] = []
        var i = 0
        while i < chars.count {
            let current = chars[i]
            var runLength = 1
            while i + runLength < chars.count && chars[i + runLength] == current {
                runLength += 1
            }
            if runLength >= 3 {
                cleaned.append(current)
            } else {
                for j in 0..<runLength {
                    cleaned.append(chars[i + j])
                }
            }
            i += runLength
        }
        result = String(cleaned)
        return result
    }

    // MARK: - Chinese Punctuation Conversion

    /// Converts English punctuation to Chinese punctuation when the text is
    /// predominantly Chinese.  Protects code snippets, numbers, and English
    /// identifiers so AI-coding dictation isn't corrupted.
    func convertPunctuationForChinese(_ text: String) -> String {
        // Only process if text has a meaningful amount of Chinese characters.
        let chineseCount = text.filter { $0.isChinese }.count
        let totalCount = text.count
        guard totalCount > 0, Double(chineseCount) / Double(totalCount) > 0.15 else {
            return text
        }

        let chars = Array(text)
        // Precompute code-context map so each punctuation check is O(1)
        // instead of the old O(n) backward scan (which led to O(n²) overall).
        let codeContextMap = buildCodeContextMap(in: chars)

        var result = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]

            // Check if this char is an English punctuation we might convert.
            guard let conversion = chinesePunctuationMap[ch] else {
                result.append(ch)
                i += 1
                continue
            }

            // Decide whether to convert based on surrounding context.
            let prev = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil

            if shouldConvertPunctuation(
                ch, prev: prev, next: next,
                allChars: chars, index: i,
                codeContextMap: codeContextMap
            ) {
                result.append(conversion)
            } else {
                result.append(ch)
            }
            i += 1
        }

        return result
    }

    /// Map from English punctuation to Chinese equivalents.
    private let chinesePunctuationMap: [Character: Character] = [
        ",": "，",
        "!": "！",
        "?": "？",
        ":": "：",
        ";": "；",
        "(": "（",
        ")": "）",
        "[": "【",
        "]": "】",
    ]

    /// Determine whether a given punctuation mark should be converted.
    private func shouldConvertPunctuation(
        _ punct: Character,
        prev: Character?,
        next: Character?,
        allChars: [Character],
        index: Int,
        codeContextMap: [Bool]
    ) -> Bool {
        switch punct {
        case ".":
            return shouldConvertDot(prev: prev, next: next)
        case ",":
            return shouldConvertComma(prev: prev, next: next, codeContextMap: codeContextMap, index: index)
        case "(", "[":
            // Convert if preceded by Chinese (function calls like foo() keep English parens
            // because 'f' is a letter, but "你好(" should become "你好（").
            if let prev = prev, prev.isChinese { return true }
            return false
        case ")", "]":
            // Convert if followed by Chinese or end of string.
            if let next = next, next.isChinese { return true }
            if next == nil { return true }
            return false
        case "!", "?":
            // Always convert in Chinese-dominant text; rarely used in code.
            return true
        case ":":
            return shouldConvertColon(prev: prev, next: next, codeContextMap: codeContextMap, index: index)
        case ";":
            return shouldConvertSemicolon(prev: prev, next: next)
        default:
            return true
        }
    }

    /// `.` is the trickiest — it appears in decimals (3.14), method chains
    /// (numpy.array), file names (main.py), and sentence endings.
    private func shouldConvertDot(prev: Character?, next: Character?) -> Bool {
        // Decimal number: digit.digit  → keep
        if let prev = prev, let next = next, prev.isNumber, next.isNumber {
            return false
        }
        // Method/attribute access: letter.(letter|digit|_)  → keep
        if let prev = prev, let next = next,
           (prev.isLetter || prev == "_"),
           (next.isLetter || next.isNumber || next == "_" || next == "(") {
            return false
        }
        // File extension-ish: letter.py, letter.js  → keep (letter followed by dot followed by 2-4 letter suffix)
        if let prev = prev, let next = next,
           prev.isLetter, next.isLetter {
            // Conservative: if next 2-3 chars are all letters then space, likely file ext
            return false
        }
        // Domain / URL parts  → keep
        if let prev = prev, let next = next,
           (prev.isLetter || prev.isNumber || prev == "-"),
           (next.isLetter || next.isNumber || next == "/") {
            return false
        }
        // If prev is Chinese and next is space/Chinese/nil → convert to 。
        if let prev = prev, prev.isChinese {
            return true
        }
        // If next is Chinese and prev is space/nil → convert
        if let next = next, next.isChinese {
            return true
        }
        // Default: keep English dot (conservative)
        return false
    }

    /// `,` appears in lists [a, b], function args foo(a, b), and Chinese sentences.
    private func shouldConvertComma(
        prev: Character?,
        next: Character?,
        codeContextMap: [Bool],
        index: Int
    ) -> Bool {
        // Inside function-call / bracket context with mostly English → keep
        if codeContextMap[index] { return false }
        // If adjacent to Chinese → convert
        if let prev = prev, prev.isChinese { return true }
        if let next = next, next.isChinese { return true }
        // Default: keep (conservative)
        return false
    }

    /// `:` appears in dicts {"a": 1}, type hints (x: int), and Chinese dialogue.
    private func shouldConvertColon(
        prev: Character?,
        next: Character?,
        codeContextMap: [Bool],
        index: Int
    ) -> Bool {
        // Inside code context (braces, brackets with English identifiers) → keep
        if codeContextMap[index] { return false }
        // JSON / dict pattern: quote or letter followed by colon and space → keep
        if let next = next, next.isWhitespace || next == " " {
            if let prev = prev, (prev.isLetter || prev.isNumber || prev == "\"" || prev == "'") {
                return false
            }
        }
        // If adjacent to Chinese → convert
        if let prev = prev, prev.isChinese { return true }
        if let next = next, next.isChinese { return true }
        return false
    }

    /// `;` is rare in Chinese prose; usually code statement separator.
    private func shouldConvertSemicolon(prev: Character?, next: Character?) -> Bool {
        // If clearly in code (between English identifiers / brackets) → keep
        if let prev = prev, let next = next,
           (prev.isLetter || prev.isNumber || prev == ")" || prev == "}"),
           (next.isLetter || next.isNumber || next == " ") {
            return false
        }
        // If adjacent to Chinese → convert
        if let prev = prev, prev.isChinese { return true }
        if let next = next, next.isChinese { return true }
        return false
    }

    /// Precompute a boolean map: `result[i] == true` means index `i` is inside a
    /// code-like context (parens or brackets whose interior is mostly ASCII).
    /// Uses prefix sums for O(1) range queries; the fill loop is bounded by
    /// qualifying span lengths which are small in practice.
    private func buildCodeContextMap(in chars: [Character]) -> [Bool] {
        var map = Array(repeating: false, count: chars.count)
        guard !chars.isEmpty else { return map }

        var asciiPrefix = Array(repeating: 0, count: chars.count + 1)
        var chinesePrefix = Array(repeating: 0, count: chars.count + 1)
        for i in 0..<chars.count {
            let c = chars[i]
            asciiPrefix[i + 1] = asciiPrefix[i] + (c.isASCII && c.isLetter ? 1 : 0)
            chinesePrefix[i + 1] = chinesePrefix[i] + (c.isChinese ? 1 : 0)
        }

        var stack: [Int] = []

        for (i, ch) in chars.enumerated() {
            switch ch {
            case "(", "[":
                stack.append(i)
            case ")", "]":
                if let start = stack.popLast() {
                    let asciiCount = asciiPrefix[i] - asciiPrefix[start + 1]
                    let chineseCount = chinesePrefix[i] - chinesePrefix[start + 1]
                    if asciiCount > chineseCount * 2 && asciiCount > 2 {
                        for j in (start + 1)..<i {
                            map[j] = true
                        }
                    }
                }
            default:
                break
            }
        }
        return map
    }

    // MARK: - Resource loading

    private static func loadTechTerms() -> [(String, String)] {
        guard let url = Bundle.module.url(forResource: "tech_terms", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return []
        }
        // Sort by pattern length descending to avoid partial matches
        return dict.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
    }

    private static func loadFillers() -> [String] {
        guard let url = Bundle.module.url(forResource: "filler_words", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else {
            return ["嗯", "啊", "哦", "呃", "哼", "哈", "呀", "哪",
                    "那个", "这个", "那么", "就是", "对吧", "然后"]
        }
        return array
    }
}

// MARK: - Character Helpers

extension Character {
    /// CJK Unified Ideographs, CJK Unified Ideographs Extension A, and common CJK ranges.
    var isChinese: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3400...0x4DBF,   // CJK Extension A
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2A6DF, // CJK Extension B
             0x2A700...0x2B73F, // CJK Extension C
             0x2B740...0x2B81F, // CJK Extension D
             0x2F800...0x2FA1F: // CJK Compatibility Supplement
            return true
        default:
            return false
        }
    }

}
