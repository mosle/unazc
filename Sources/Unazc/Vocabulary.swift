import Foundation

/// User replacement dictionary for misrecognitions the model keeps making, e.g. 「ぎっとはぶ => GitHub」.
/// Plain text, one `wrong => right` per line, `#` starts a comment. The file is re-read when it
/// changes, so edits apply from the next utterance. Not thread-safe; use from one queue.
final class Vocabulary {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Unazc/vocab.txt")

    static let template = """
        # Unazc 置き換え辞書
        # 1行に「認識された文字 => 入れたい文字」。保存すると次の発話から効きます。
        # 長いものから優先して置き換え、置き換えた結果をさらに置き換えることはしません。
        #
        # 例:
        # ぎっとはぶ => GitHub
        # ぎっと => Git

        """

    private let url: URL
    /// Sorted longest source first, so a longer entry wins over one that is its prefix.
    private(set) var entries: [(from: String, to: String)] = []
    private var loadedStamp: Date?
    private var loadedTarget: URL?

    init(url: URL = Vocabulary.defaultURL) {
        self.url = url
    }

    /// Lines without `=>` or with an empty left side are reported and skipped.
    static func parse(_ text: String) -> (entries: [(from: String, to: String)], skipped: [Int]) {
        var entries: [(from: String, to: String)] = []
        var skipped: [Int] = []
        // Split on Characters so CRLF (one Character) counts as a single line break in line numbers.
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let arrow = line.range(of: "=>") else {
                skipped.append(i + 1)
                continue
            }
            let from = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let to = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else {
                skipped.append(i + 1)
                continue
            }
            entries.append((from, to))
        }
        // Stable for equal lengths, so the earlier line wins a duplicate.
        let sorted = entries.enumerated().sorted {
            $0.element.from.count != $1.element.from.count
                ? $0.element.from.count > $1.element.from.count
                : $0.offset < $1.offset
        }.map(\.element)
        return (sorted, skipped)
    }

    /// Single left-to-right pass: at each position the longest matching entry is replaced and the
    /// scan continues after it, so a replacement is never itself replaced again.
    static func apply(_ entries: [(from: String, to: String)], to text: String) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }
        var out = ""
        var i = text.startIndex
        outer: while i < text.endIndex {
            for entry in entries where text[i...].hasPrefix(entry.from) {
                out += entry.to
                i = text.index(i, offsetBy: entry.from.count)
                continue outer
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }

    enum RegisterError: Error, Equatable {
        case emptySource, newline, arrowInSource, commentSource

        var message: String {
            switch self {
            case .emptySource: return "認識された文字が空です"
            case .newline: return "改行は登録できません"
            case .arrowInSource: return "認識された文字に「=>」は使えません"
            case .commentSource: return "「#」で始まる行はコメントになるので登録できません"
            }
        }
    }

    /// `text` (the file's contents) with `from => to` added, or put in place of the first line that
    /// already replaces `from`: a second line for it would never apply, since the earlier one wins.
    static func registering(_ from: String, _ to: String, in text: String) throws -> String {
        let from = from.trimmingCharacters(in: .whitespaces)
        let to = to.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { throw RegisterError.emptySource }
        guard !(from + to).contains(where: \.isNewline) else { throw RegisterError.newline }
        guard !from.contains("=>") else { throw RegisterError.arrowInSource }
        guard !from.hasPrefix("#") else { throw RegisterError.commentSource }
        let entry = "\(from) => \(to)"
        // Only the matching line's text is touched; every line ending stays as it was. Lines are
        // split exactly as parse() splits them.
        var start = text.startIndex
        var i = text.startIndex
        while true {
            let end = i == text.endIndex || text[i].isNewline
            if end, parse(String(text[start..<i])).entries.first?.from == from {
                return text.replacingCharacters(in: start..<i, with: entry)
            }
            if i == text.endIndex { break }
            i = text.index(after: i)
            if end { start = i }
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let separator = text.isEmpty || text.last?.isNewline == true ? "" : newline
        return text + separator + entry + newline
    }

    static func existing(_ from: String, url: URL = defaultURL) -> String? {
        let from = from.trimmingCharacters(in: .whitespaces)
        guard let text = try? String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8) else { return nil }
        return parse(text).entries.first { $0.from == from }?.to
    }

    /// Writes the entry into the file (created from the template if missing). Written in place to
    /// the link's target, so a symlinked vocab.txt stays a link.
    static func register(_ from: String, _ to: String, url: URL = defaultURL) throws {
        let target = url.resolvingSymlinksInPath()
        let current: String
        if FileManager.default.fileExists(atPath: target.path) {
            current = try String(contentsOf: target, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            current = template
        }
        let updated = try registering(from, to, in: current)
        // Atomic: the ASR queue may be reading it meanwhile, and must see the old file or the new
        // one, never half of it. Replacing the resolved target leaves a symlink pointing at it.
        try Data(updated.utf8).write(to: target, options: .atomic)
        Log.info("vocab: registered \(from) => \(to)")
    }

    /// Re-reads the file when its modification date changed. A missing file means no entries; an
    /// unreadable one keeps the last good entries so a half-saved edit does not wipe them.
    func reloadIfChanged() {
        // Resolved every time, so editing a symlink's target (or re-pointing the link) is noticed.
        let target = url.resolvingSymlinksInPath()
        let stamp: Date?
        do {
            stamp = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            entries = []
            loadedStamp = nil
            loadedTarget = nil
            return
        } catch {
            Log.info("vocab: cannot stat \(target.path): \(error); keeping \(entries.count) entries")
            return
        }
        guard stamp != loadedStamp || target != loadedTarget else { return }
        guard let data = try? Data(contentsOf: target), let text = String(data: data, encoding: .utf8) else {
            Log.info("vocab: cannot read \(url.path) as UTF-8; keeping \(entries.count) entries")
            return
        }
        loadedStamp = stamp
        loadedTarget = target
        let parsed = Self.parse(text)
        entries = parsed.entries
        Log.info("vocab: \(entries.count) entries" + (parsed.skipped.isEmpty ? "" : ", skipped lines \(parsed.skipped)"))
    }

    func apply(to text: String) -> String {
        reloadIfChanged()
        return Self.apply(entries, to: text)
    }
}
