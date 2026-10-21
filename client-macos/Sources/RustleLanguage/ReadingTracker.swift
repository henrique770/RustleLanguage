import Foundation

/// Live karaoke: lines up what the recognizer has heard so far with the text being read, so each
/// word can be colored as you go (read, near miss, wrong, skipped) and the cursor follows you.
/// Same edit-distance alignment as the server's final assessment (server/alignment.py), except
/// that the reference may stop anywhere: you have only read part of it so far.
enum ReadingTracker {
    enum Status: String {
        case pending, current, correct, close, wrong, missed, unclear
    }

    struct Word: Identifiable, Hashable {
        let id: Int
        /// As written, with its punctuation ("today,").
        let display: String
        /// Lowercased, no punctuation ("today").
        let key: String
        /// Range in the original text (to match the speech synthesizer's spoken range).
        let range: NSRange
    }

    struct Progress: Equatable {
        var statuses: [Status]
        /// What was heard for wrong / close words.
        var heard: [Int: String]
        /// Index of the next word to read.
        var position: Int

        var reachedFraction: Double { statuses.isEmpty ? 0 : Double(position) / Double(statuses.count) }
        var accuracy: Int {
            let done = statuses.prefix(position)
            guard !done.isEmpty else { return 0 }
            let points = done.reduce(0.0) { $0 + ($1 == .correct ? 1 : $1 == .close ? 0.6 : 0) }
            return Int((points / Double(done.count) * 100).rounded())
        }
    }

    private static let wordPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9]+(?:['’][A-Za-z]+)*[^\\sA-Za-z0-9]*")
    private static let keyPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9]+(?:['’][A-Za-z]+)*")

    static func words(in text: String) -> [Word] {
        let ns = text as NSString
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).enumerated().map { i, m in
            let display = ns.substring(with: m.range)
            return Word(id: i, display: display, key: key(display), range: m.range)
        }
    }

    static func key(_ s: String) -> String {
        let ns = s as NSString
        guard let m = keyPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return "" }
        return ns.substring(with: m.range).lowercased().replacingOccurrences(of: "’", with: "'")
    }

    static func keys(_ text: String) -> [String] {
        let ns = text as NSString
        return keyPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'")
        }
    }

    /// Index of the word containing a character location (for the "Ouvir" highlight).
    static func wordIndex(at range: NSRange, in words: [Word]) -> Int? {
        words.firstIndex { NSIntersectionRange($0.range, range).length > 0 || $0.range.location >= range.location }
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Aligns heard words against the reference, where reading may have stopped at any word.
    static func track(reference: [Word], heardText: String) -> Progress {
        let ref = reference.map(\.key)
        let heard = keys(heardText)
        let n = ref.count, m = heard.count
        var statuses = Array(repeating: Status.pending, count: n)
        guard n > 0 else { return Progress(statuses: [], heard: [:], position: 0) }
        guard m > 0 else {
            statuses[0] = .current
            return Progress(statuses: statuses, heard: [:], position: 0)
        }

        // cost[i][j]: aligning the first i reference words with the first j heard words.
        let inf = Double.infinity
        var cost = Array(repeating: Array(repeating: inf, count: m + 1), count: n + 1)
        var back = Array(repeating: Array(repeating: UInt8(0), count: m + 1), count: n + 1)
        cost[0][0] = 0
        for i in 0...n {
            for j in 0...m {
                let c = cost[i][j]
                if c == inf { continue }
                if i < n && j < m {
                    let sim = similarity(ref[i], heard[j])
                    let step = sim == 1 ? 0 : sim >= 0.7 ? 0.4 : 1
                    if c + step < cost[i + 1][j + 1] { cost[i + 1][j + 1] = c + step; back[i + 1][j + 1] = 0 }
                }
                if i < n && c + 1 < cost[i + 1][j] { cost[i + 1][j] = c + 1; back[i + 1][j] = 1 }
                if j < m && c + 1 < cost[i][j + 1] { cost[i][j + 1] = c + 1; back[i][j + 1] = 2 }
            }
        }
        // Where did the reading stop? The cheapest end point; on ties, the furthest one.
        var end = 0
        for i in 0...n where cost[i][m] <= cost[end][m] { end = i }

        var heardFor: [Int: String] = [:]
        var i = end, j = m
        while i > 0 || j > 0 {
            switch back[i][j] {
            case 0:
                let sim = similarity(ref[i - 1], heard[j - 1])
                statuses[i - 1] = sim == 1 ? .correct : sim >= 0.7 ? .close : .wrong
                if sim < 1 { heardFor[i - 1] = heard[j - 1] }
                i -= 1; j -= 1
            case 1:
                statuses[i - 1] = .missed
                i -= 1
            default:
                j -= 1
            }
            if i == 0 && j > 0 { j = 0 }
        }
        if end < n { statuses[end] = .current }
        return Progress(statuses: statuses, heard: heardFor, position: end)
    }
}
