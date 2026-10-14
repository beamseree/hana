import CoreFoundation
import Foundation
import UniformTypeIdentifiers

/// A source prepares names once; file-type recognition never runs per query.
struct SearchName: Equatable, Sendable {
    enum Tier: Int, Comparable, Sendable {
        case exact, phrasePrefix, wordStart, substring, extensionOnly

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    private let full: SearchWords
    private let stem: SearchWords?
    private let fileExtension: String?
    var length: Int { (stem ?? full).value.count }

    init(_ name: String, stripExtension: Bool = false) {
        full = SearchWords(name)
        let suffix = (name as NSString).pathExtension
        if stripExtension, !suffix.isEmpty, UTType(filenameExtension: suffix)?.isDeclared == true {
            stem = SearchWords((name as NSString).deletingPathExtension)
            fileExtension = Self.normalized(suffix)
        } else {
            stem = nil
            fileExtension = nil
        }
    }

    static func normalized(_ text: String) -> String { SearchWords.normalized(text) }

    func tier(for query: String) -> Tier? {
        let fullTier = full.tier(for: query)
        let stemTier = stem?.tier(for: query)
        // A complete filename stays exact. Otherwise an extension alone must
        // not gain a word-start tier merely because the dot is a boundary.
        if fullTier != .exact, stemTier == nil, let fileExtension,
           query.split(separator: " ").allSatisfy({ fileExtension.contains($0) }) { return .extensionOnly }
        return [fullTier, stemTier].compactMap { $0 }.min()
    }

    func wordsInOrder(for query: String, tier: Tier) -> Bool {
        if let stem, stem.tier(for: query) == tier {
            return stem.wordsInOrder(for: query, atWordStarts: tier == .wordStart)
        }
        return full.wordsInOrder(for: query, atWordStarts: tier == .wordStart)
    }
}

/// Immutable matching data, prepared once when a source creates a result.
/// In particular, cached catalog names never need tokenizing per query.
private struct SearchWords: Equatable, Sendable {
    let value: String
    private let wordStarts: [String]

    init(_ name: String) {
        value = Self.normalized(name)
        let original = name.precomposedStringWithCanonicalMapping
        let tokenizer = CFStringTokenizerCreate(nil, original as CFString,
            CFRange(location: 0, length: original.utf16.count), kCFStringTokenizerUnitWord, nil)
        var starts = Set<String.Index>()
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if let range = Range(NSRange(location: range.location, length: range.length), in: original) {
                starts.insert(range.lowerBound)
            }
        }
        var previous: Character?
        for index in original.indices {
            let character = original[index]
            if previous?.isLowercase == true, character.isUppercase { starts.insert(index) }
            previous = character
        }
        // Suffixes retain literal punctuation and use exactly the query's
        // normalization, including folds that change the character count.
        wordStarts = starts.sorted().map { Self.normalized(String(original[$0...])) }
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func tier(for query: String) -> SearchName.Tier? {
        let words = query.split(separator: " ")
        guard words.allSatisfy({ value.contains($0) }) else { return nil }
        if value == query { return .exact }
        if value.hasPrefix(query) { return .phrasePrefix }
        if words.allSatisfy({ word in wordStarts.contains { $0.hasPrefix(word) } }) { return .wordStart }
        return .substring
    }

    func wordsInOrder(for query: String, atWordStarts: Bool) -> Bool {
        var end = 0
        for word in query.split(separator: " ") {
            if atWordStarts {
                guard let suffix = wordStarts.first(where: {
                    value.count - $0.count >= end && $0.hasPrefix(word)
                }) else { return false }
                end = value.count - suffix.count + word.count
            } else {
                let start = value.index(value.startIndex, offsetBy: end)
                guard let range = value.range(of: word, range: start..<value.endIndex) else { return false }
                end = value.distance(from: value.startIndex, to: range.upperBound)
            }
        }
        return true
    }
}
