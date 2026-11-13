import Foundation

/// User-chosen search filters. A nil notebook means All Notebooks, the default scope.
nonisolated struct SearchFilters: Hashable, Sendable {
    enum Review: String, CaseIterable, Hashable, Sendable {
        case any, needsReview, reviewed
    }

    var notebookID: UUID?
    /// Inclusive journal-date bounds. Entries without a journal date are excluded when either is set.
    var dateFrom: Date?
    var dateThrough: Date?
    var favoritesOnly = false
    var review: Review = .any

    var isDefault: Bool { self == SearchFilters() }
}

/// Normal search is case- and diacritic-insensitive word-prefix search:
/// - Each whitespace-separated word must appear in the page text, entry title or notebook name.
///   The last letters may be unfinished: `pray` finds “prayer”.
/// - Punctuation splits words the same way the index does. A word that contains punctuation,
///   such as `3:16` or `don't`, must match as adjacent words, so `John 3:16` finds “John 3:16”
///   but not a page that merely contains a 3 and a 16 apart.
/// - Text in double quotes (straight or curly) is an exact phrase without prefix matching.
/// - FTS operators (AND, OR, NOT, NEAR, `*`, `^`, column filters) typed by the user are treated
///   as ordinary words. This is not substring, fuzzy or semantic search.
nonisolated enum SearchQuery {
    static let maxTerms = 12
    static let maxInputLength = 256

    struct Term: Equatable, Sendable {
        /// Lowercased letter/number runs. Never contains quotes, operators or whitespace.
        let tokens: [String]
        let isPrefix: Bool
    }

    static func terms(from input: String) -> [Term] {
        var terms: [Term] = []
        var buffer = ""
        var inQuote = false

        func flush(asPhrase: Bool) {
            if asPhrase {
                let tokens = tokenize(buffer)
                if !tokens.isEmpty { terms.append(Term(tokens: tokens, isPrefix: false)) }
            } else {
                for word in buffer.split(whereSeparator: \.isWhitespace) {
                    let tokens = tokenize(String(word))
                    if !tokens.isEmpty { terms.append(Term(tokens: tokens, isPrefix: true)) }
                }
            }
            buffer = ""
        }

        for character in input.prefix(maxInputLength) {
            if character == "\"" || character == "“" || character == "”" {
                flush(asPhrase: inQuote)
                inQuote.toggle()
            } else {
                buffer.append(character)
            }
        }
        // An unfinished quote (still being typed) is treated as a phrase.
        flush(asPhrase: inQuote)
        return Array(terms.prefix(maxTerms))
    }

    /// Builds an FTS5 MATCH expression from scratch. Every token is letters/numbers only and
    /// wrapped in double quotes, so user input can never form FTS syntax. Returns nil when
    /// nothing searchable was typed. The result must still be passed as a bound parameter.
    static func ftsExpression(from input: String) -> String? {
        let terms = terms(from: input)
        guard !terms.isEmpty else { return nil }
        return terms.map { term in
            "\"" + term.tokens.joined(separator: " ") + "\"" + (term.isPrefix ? "*" : "")
        }.joined(separator: " ")
    }

    /// Splits like FTS5's unicode61 tokenizer: letters and numbers form tokens; everything
    /// else separates them. Case and diacritics are folded to match `remove_diacritics 2`.
    static func tokenize(_ text: String) -> [String] {
        fold(text).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Used by the bounded fallback search: true when every term matches in order-insensitive
    /// fashion, with phrase tokens adjacent and the last token of a prefix term a prefix.
    static func matches(_ text: String, terms: [Term]) -> Bool {
        let tokens = tokenize(text)
        return terms.allSatisfy { term in tokenPosition(of: term, in: tokens) != nil }
    }

    static func tokenPosition(of term: Term, in tokens: [String]) -> Int? {
        let count = term.tokens.count
        guard count > 0, tokens.count >= count else { return nil }
        for start in 0...(tokens.count - count) {
            var matched = true
            for (offset, token) in term.tokens.enumerated() {
                let candidate = tokens[start + offset]
                let isLast = offset == count - 1
                if !(candidate == token || (isLast && term.isPrefix && candidate.hasPrefix(token))) {
                    matched = false
                    break
                }
            }
            if matched { return start }
        }
        return nil
    }

    /// Ranges in `text` to emphasize: word starts that match any query token (prefix-aware).
    /// Used to show the relevant text when a result opens a page.
    static func emphasisRanges(in text: String, terms: [Term]) -> [Range<String.Index>] {
        let wanted = terms.flatMap { term in
            term.tokens.enumerated().map { (token: $0.element, prefix: term.isPrefix && $0.offset == term.tokens.count - 1) }
        }
        guard !wanted.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, text[end].isLetter || text[end].isNumber { end = text.index(after: end) }
            let word = fold(String(text[index..<end]))
            if wanted.contains(where: { word == $0.token || ($0.prefix && word.hasPrefix($0.token)) }) {
                ranges.append(index..<end)
            }
            index = end
        }
        return ranges
    }

    /// A short excerpt around the first emphasized word, with emphasis marked by
    /// `SearchMarkup.open`/`close`. Used by the fallback; FTS5 builds its own snippets.
    static func excerpt(from text: String, terms: [Term], radius: Int = 60) -> String {
        let ranges = emphasisRanges(in: text, terms: terms)
        guard let first = ranges.first else { return String(text.prefix(radius * 2)) }
        let start = text.index(first.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(first.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var result = start == text.startIndex ? "" : "…"
        var cursor = start
        for range in ranges where range.lowerBound >= start && range.upperBound <= end {
            result += text[cursor..<range.lowerBound] + SearchMarkup.open + text[range] + SearchMarkup.close
            cursor = range.upperBound
        }
        result += text[cursor..<end]
        if end != text.endIndex { result += "…" }
        return result
    }
}

/// Control characters used to mark emphasis inside excerpts. They cannot be typed into the
/// editor's plain text in practice and are stripped from displayed output.
nonisolated enum SearchMarkup {
    static let open = "\u{1}"
    static let close = "\u{2}"

    static func hasEmphasis(_ text: String) -> Bool { text.contains(open) }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: open, with: "").replacingOccurrences(of: close, with: "")
    }
}
