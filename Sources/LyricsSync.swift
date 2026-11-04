import Foundation

// Times the lyrics to the words actually sung.
// LRCLIB only says when each line starts. When "listen" is on (AudioListener.swift), Crate hears Spotify,
// macOS speech recognition says when it heard each word, and this lines the recognized words up with the lyrics.
// Each word of a line then gets the time it's sung. The text stays LRCLIB's: recognition only tells *when*.
// Results are cached per song and get better with each listen.

/// A word the speech recognizer heard, at a position in the song (s)
struct HeardWord: Codable {
    let text: String
    let start: Double
    let end: Double
}

/// When each word of the synced lyrics is sung, learned by listening
struct WordTimings: Codable {
    static let currentVersion = 1
    var version = WordTimings.currentVersion
    /// The lines these timings were made for: if LRCLIB's lyrics change, the timings no longer apply
    var signature: String
    /// Per line: start time of each word (words are split on spaces), or nil if the line hasn't been heard
    var words: [[Double]?]
    /// Per line: how many of its words the recognizer matched, to keep the best of several listens
    var anchors: [Int]
    /// Complete listens so far: after two, Crate stops listening to this song
    var listens = 0
    /// Plays already counted as a listen
    var counted: [String] = []

    /// Same lyrics, same signature, from one launch to the next (Swift's hashValue changes every launch)
    static func signature(of lines: [Line]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a
        for byte in (lines.map { "\($0.t)|\($0.text)" }.joined(separator: "\n")).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return "\(lines.count)-" + String(hash, radix: 36)
    }
}

enum LyricsAligner {
    /// Lowercase letters and digits only, without accents: "C'était," -> "cetait"
    static func normalize<S: StringProtocol>(_ word: S) -> String {
        String(word).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Without timings: the line is shared between its words by length, as long as the next line lets it,
    /// without stretching over a long silence
    static func guessedStarts(_ lines: [Line], _ i: Int) -> [Double] {
        let line = lines[i]
        let next = i + 1 < lines.count ? lines[i + 1].t : line.t + 4
        let length = Double(line.text.count + 1)
        let sung = min(next - line.t, 0.11 * length + 0.6) * 0.92
        var start = line.t
        return line.text.split(separator: " ").map { word in
            defer { start += sung * Double(word.count + 1) / length }
            return start
        }
    }

    struct Result {
        /// Per line: word start times, nil outside the part of the song that was heard
        let words: [[Double]?]
        let anchors: [Int]
        /// Lines in the heard part, and how many of them had at least one recognized word
        let linesHeard: Int
        let linesMatched: Int
        let wordsHeard: Int
        let wordsMatched: Int
        /// How far LRCLIB's timing is from what was heard, overall (s)
        let offset: Double
        /// Enough recognized words, in the right places, to trust the result
        var reliable: Bool {
            wordsMatched >= 8 && Double(linesMatched) >= max(3, 0.3 * Double(linesHeard))
                && Double(wordsMatched) >= 0.12 * Double(wordsHeard)
        }
    }

    private struct LyricWord {
        let key: String
        let line: Int
        let index: Int
        let guess: Double
        /// Characters from the start of the lyrics, to place words between two recognized ones
        let position: Int
    }

    /// Lines up recognized words with the lyrics. `offsetRange`: how far LRCLIB's timing may be from the song
    /// (the song position is known, so only by a few seconds). `window`: how far a word may be from where it's expected.
    static func align(_ lines: [Line], heard: [HeardWord], offsetRange: ClosedRange<Double> = -3...3, window: Double = 2.5) -> Result? {
        let heard = heard.filter { !normalize($0.text).isEmpty }.sorted { $0.start < $1.start }
        guard let first = heard.first, let last = heard.last else { return nil }
        let heardKeys = heard.map { normalize($0.text) }

        var words: [LyricWord] = []
        var position = 0
        for i in lines.indices where !lines[i].text.isEmpty {
            let starts = guessedStarts(lines, i)
            for (k, token) in lines[i].text.split(separator: " ").enumerated() {
                let key = normalize(token)
                if !key.isEmpty { words.append(LyricWord(key: key, line: i, index: k, guess: starts[k], position: position)) }
                position += token.count + 1
            }
        }
        guard !words.isEmpty else { return nil }

        // 1. Overall offset: the most common gap between a lyric word and the same word heard nearby
        var byKey: [String: [Int]] = [:]
        for (j, key) in heardKeys.enumerated() where key.count >= 3 { byKey[key, default: []].append(j) }
        var votes: [Int: Int] = [:]
        for word in words where word.key.count >= 3 {
            for j in byKey[word.key] ?? [] {
                let gap = heard[j].start - word.guess
                if offsetRange.contains(gap) { votes[Int((gap * 4).rounded()), default: 0] += 1 }
            }
        }
        let offset = Double(votes.max { $0.value < $1.value || ($0.value == $1.value && abs($0.key) > abs($1.key)) }?.key ?? 0) / 4

        // 2. Longest run of matches in order, each word only near where it's expected: repeated choruses can't cross.
        //    Between equally long runs, the one whose words are closest to where they're expected
        let n = words.count, m = heard.count
        func score(_ i: Int, _ j: Int) -> Float {
            guard words[i].key == heardKeys[j] else { return 0 }
            let distance = abs(heard[j].start - (words[i].guess + offset))
            return distance < window ? 1 + Float(0.5 * (1 - distance / window)) : 0
        }
        var table = [Float](repeating: 0, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Float { table[i * (m + 1) + j] }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                var best = max(at(i + 1, j), at(i, j + 1))
                let s = score(i, j)
                if s > 0 { best = max(best, at(i + 1, j + 1) + s) }
                table[i * (m + 1) + j] = best
            }
        }
        var anchor: [Int: Double] = [:]   // lyric word -> when it was heard
        var i = 0, j = 0
        while i < n && j < m {
            let s = score(i, j)
            if s > 0 && abs(at(i, j) - (at(i + 1, j + 1) + s)) < 0.0001 { anchor[i] = heard[j].start; i += 1; j += 1 }
            else if at(i + 1, j) >= at(i, j + 1) { i += 1 }
            else { j += 1 }
        }

        // 3. Every word of the heard part gets a time: recognized ones as heard, the others placed between
        //    their recognized neighbours, or moved like the nearest recognized word
        let span = (first.start - 1)...(last.end + 1)
        let heardWords = words.indices.filter { span.contains(words[$0].guess + offset) }
        let anchored = anchor.keys.sorted()
        func time(_ k: Int) -> Double {
            if let t = anchor[k] { return t }
            let before = anchored.last { $0 < k }, after = anchored.first { $0 > k }
            if let b = before, let a = after, a - b <= 12, let tb = anchor[b], let ta = anchor[a], ta > tb, ta - tb < 8 {
                let f = Double(words[k].position - words[b].position) / Double(max(1, words[a].position - words[b].position))
                return tb + f * (ta - tb)
            }
            let near = [before, after].compactMap { $0 }.min { abs(words[$0].guess - words[k].guess) < abs(words[$1].guess - words[k].guess) }
            if let near, abs(words[near].guess - words[k].guess) < 15, let t = anchor[near] { return words[k].guess + (t - words[near].guess) }
            return words[k].guess + offset
        }
        var result: [[Double]?] = Array(repeating: nil, count: lines.count)
        var anchors = Array(repeating: 0, count: lines.count)
        let heardLines = Set(heardWords.map { words[$0].line })
        for line in heardLines.sorted() {
            let tokens = lines[line].text.split(separator: " ")
            var starts = guessedStarts(lines, line).map { $0 + offset }
            for k in heardWords where words[k].line == line {
                starts[words[k].index] = time(k)
                if anchor[k] != nil { anchors[line] += 1 }
            }
            // Never backwards inside a line
            for w in 1..<max(1, starts.count) where starts[w] < starts[w - 1] + 0.05 { starts[w] = starts[w - 1] + 0.05 }
            if starts.count == tokens.count { result[line] = starts }
        }
        let matchedLines = Set(anchor.keys.map { words[$0].line })
        return Result(words: result, anchors: anchors, linesHeard: heardLines.count, linesMatched: matchedLines.count,
                      wordsHeard: heardWords.count, wordsMatched: anchor.count, offset: offset)
    }

    /// Keeps, line by line, whichever listen recognized more of its words
    static func merge(_ old: WordTimings?, _ new: Result, lines: [Line]) -> WordTimings {
        let signature = WordTimings.signature(of: lines)
        var merged = old.flatMap { $0.signature == signature && $0.version == WordTimings.currentVersion ? $0 : nil }
            ?? WordTimings(signature: signature, words: Array(repeating: nil, count: lines.count), anchors: Array(repeating: 0, count: lines.count))
        for i in lines.indices {
            guard let words = new.words[i] else { continue }
            if merged.words[i] == nil || new.anchors[i] > merged.anchors[i] {
                merged.words[i] = words
                merged.anchors[i] = new.anchors[i]
            }
        }
        return merged
    }
}

extension LyricsAligner {
    /// Plain lyrics (no times) + what was heard over the whole song -> when each line starts.
    /// nil unless most lines, including the first and last ones, could be placed from what was recognized
    static func alignPlain(_ texts: [String], heard: [HeardWord], duration: Double, minPlaced: Double = 0.75) -> [Line]? {
        let heard = heard.filter { !normalize($0.text).isEmpty }.sorted { $0.start < $1.start }
        guard heard.count >= 20, !texts.isEmpty else { return nil }
        // 1. A rough skeleton from what's sure: runs of recognized words in the lyrics' order
        guard let rough = skeleton(texts, heard: heard, duration: duration) else { return nil }
        // 2. Then each word only near where the skeleton expects it, like synced lyrics: repeated choruses stay apart
        guard let result = align(rough, heard: heard, offsetRange: -1...1, window: 4) else { return nil }
        var starts: [Double?] = texts.indices.map { result.anchors[$0] > 0 ? result.words[$0]?.first : nil }

        // Lines come in order, each taking some time to sing: drop starts that don't fit
        var last: (index: Int, start: Double)?
        for i in texts.indices {
            guard let s = starts[i] else { continue }
            if let l = last, s < l.start + 0.03 * Double(texts[l.index].count) { starts[i] = nil; continue }
            last = (i, s)
        }
        let placed = starts.indices.filter { starts[$0] != nil }
        guard let first = placed.first, let final = placed.last,
              Double(placed.count) >= minPlaced * Double(texts.count),
              first == 0, texts.count - 1 - final <= 1 else { return nil }
        // The first line is what's seen first: several of its words recognized, and sung only once, so it can't be
        // a repeat of the chorus taken for another. The last placed line, recognized too
        let keys = texts.map { normalize($0) }
        guard result.anchors[0] >= 2, keys.filter({ $0 == keys[0] }).count == 1, result.anchors[final] >= 2 else { return nil }
        // Singing heard well before the first line or well after the last one: the edges are wrong
        let sung = heard.filter { normalize($0.text).count >= 3 }
        if let firstSung = sung.first?.start, let lastSung = sung.last?.start, let s0 = starts[first], let s1 = starts[final],
           s0 > firstSung + 4 || s1 < lastSung - 8 { return nil }

        // How fast this song is sung (s per character), to place the few lines in between
        var chars: [Int] = [], total = 0
        for text in texts { chars.append(total); total += text.count + 1 }
        let rates = zip(placed, placed.dropFirst()).compactMap { b, a -> Double? in
            guard let sb = starts[b], let sa = starts[a] else { return nil }
            return (sa - sb) / Double(chars[a] - chars[b])
        }.sorted()
        let rate = rates.isEmpty ? 0.1 : min(0.2, max(0.04, rates[rates.count / 2]))
        return texts.indices.map { i in
            if let s = starts[i] { return Line(t: min(max(0, s), duration), text: texts[i]) }
            let before = placed.last { $0 < i }, after = placed.first { $0 > i }
            let t: Double
            if let b = before, let a = after, let sb = starts[b], let sa = starts[a] {
                t = sb + (sa - sb) * Double(chars[i] - chars[b]) / Double(chars[a] - chars[b])
            } else if let b = before, let sb = starts[b] {
                t = min(duration - 1, sb + Double(chars[i] - chars[b]) * rate)
            } else {
                t = max(0, starts[first]! - Double(chars[first] - chars[i]) * rate)
            }
            return Line(t: min(max(0, t), duration), text: texts[i])
        }
    }

    /// Rough line times for plain lyrics: runs of at least 3 recognized words in order anchor lines, the rest is spread
    /// between them. nil if too little of the song was recognized
    private static func skeleton(_ texts: [String], heard: [HeardWord], duration: Double) -> [Line]? {
        let heardKeys = heard.map { normalize($0.text) }
        struct Word { let key: String; let line: Int; let position: Int }
        var words: [Word] = []
        var lineChars: [Int] = []
        var position = 0
        for (i, text) in texts.enumerated() {
            lineChars.append(position)
            for token in text.split(separator: " ") {
                let key = normalize(token)
                if !key.isEmpty { words.append(Word(key: key, line: i, position: position)) }
                position += token.count + 1
            }
        }
        let n = words.count, m = heard.count
        guard n > 0 else { return nil }
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int32 { table[i * (m + 1) + j] }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                var best = max(at(i + 1, j), at(i, j + 1))
                if words[i].key == heardKeys[j] { best = max(best, at(i + 1, j + 1) + 1) }
                table[i * (m + 1) + j] = best
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if words[i].key == heardKeys[j] && at(i, j) == at(i + 1, j + 1) + 1 { pairs.append((i, j)); i += 1; j += 1 }
            else if at(i + 1, j) >= at(i, j + 1) { i += 1 }
            else { j += 1 }
        }
        // Keep runs of 3 or more words recognized one after the other
        var kept: [(Int, Int)] = []
        var run: [(Int, Int)] = []
        for pair in pairs + [(-9, -9)] {
            if let previous = run.last, pair.0 == previous.0 + 1, pair.1 == previous.1 + 1 { run.append(pair); continue }
            if run.count >= 3 { kept += run }
            run = [pair]
        }
        var starts: [Double?] = Array(repeating: nil, count: texts.count)
        for (w, h) in kept where starts[words[w].line] == nil {
            starts[words[w].line] = max(0, heard[h].start - Double(words[w].position - lineChars[words[w].line]) * 0.06)
        }
        var last: Double = -1
        for k in starts.indices { if let s = starts[k] { if s < last { starts[k] = nil } else { last = s } } }
        let placed = starts.indices.filter { starts[$0] != nil }
        guard Double(placed.count) >= 0.3 * Double(texts.count), let first = placed.first else { return nil }
        return texts.indices.map { k in
            if let s = starts[k] { return Line(t: s, text: texts[k]) }
            let before = placed.last { $0 < k }, after = placed.first { $0 > k }
            if let b = before, let a = after, let sb = starts[b], let sa = starts[a] {
                return Line(t: sb + (sa - sb) * Double(lineChars[k] - lineChars[b]) / Double(max(1, lineChars[a] - lineChars[b])), text: texts[k])
            }
            if let b = before, let sb = starts[b] { return Line(t: min(duration - 1, sb + Double(lineChars[k] - lineChars[b]) * 0.08), text: texts[k]) }
            return Line(t: max(0, starts[first]! - Double(lineChars[first] - lineChars[k]) * 0.08), text: texts[k])
        }
    }

    /// LRCLIB's plain lyrics -> one entry per sung line ("[Chorus]" and blank lines left out)
    static func plainLines(_ plain: String) -> [String] {
        plain.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) }
    }
}
