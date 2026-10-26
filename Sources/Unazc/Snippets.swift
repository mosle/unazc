import Foundation

/// Canned texts inserted by voice: when a whole utterance is one of a snippet's trigger phrases,
/// the snippet's body (which may span lines) is pasted instead. Only the whole utterance counts, so
/// a phrase said inside a sentence stays as it was said. The file is re-read when it changes, so
/// edits apply from the next utterance. Not thread-safe; use from one queue.
final class Snippets {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Unazc/snippets.txt")

    static let template = """
        # Unazc 定型文
        # 「== 呼び出す言葉」の行の下に、入れたい文を書きます（何行でも）。次の「==」までが1つの定型文です。
        # 呼び出す言葉だけを話すと、定型文に置き換わります。文の途中で言ったときは置き換えません。
        # 句読点・空白・ひらがなとカタカナの違いは無視して比べます。「|」で区切ると呼び出す言葉を複数書けます。
        # 「#」で始まる行がコメントになるのは、最初の「==」より前だけです。
        #
        # 例:
        # == メールの締め | めーるのしめ
        # よろしくお願いいたします。
        # 山田

        """

    private let url: URL
    /// Normalized trigger -> body. The first snippet to use a trigger keeps it.
    private(set) var entries: [String: String] = [:]
    private var loadedStamp: Date?
    private var loadedTarget: URL?

    init(url: URL = Snippets.defaultURL) {
        self.url = url
    }

    /// The form two phrases are compared in: width and letter case folded, katakana as hiragana,
    /// and every space, punctuation mark and symbol dropped (「ー」 is a letter, so it stays).
    static func normalize(_ text: String) -> String {
        // Before width folding too, so a symbol never unfolds into letters (「™」 into 「TM」);
        // emoji presentation selectors and joiners go with the symbols they belong to.
        let dropped = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
            .union(CharacterSet(charactersIn: "\u{FE00}"..."\u{FE0F}")).union(CharacterSet(charactersIn: "\u{200D}"))
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { !dropped.contains($0) }))
        // By code point, not ICU's transform, which turns 「メール」 into 「めえる」.
        let scalars = kept.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
            .filter { !dropped.contains($0) }
            .map { (0x30A1...0x30F6).contains($0.value) ? Unicode.Scalar($0.value - 0x60)! : $0 }
        return String(String.UnicodeScalarView(scalars))
    }

    /// A header whose triggers all normalize to nothing is reported and its body skipped.
    /// Blank lines around a body are trimmed; lines inside it are kept as written.
    static func parse(_ text: String) -> (entries: [String: String], skipped: [Int]) {
        var entries: [String: String] = [:]
        var skipped: [Int] = []
        var triggers: [String]?
        var body: [Substring] = []
        func flush() {
            guard let triggers else { return }
            let joined = body.drop { $0.allSatisfy(\.isWhitespace) }.reversed()
                .drop { $0.allSatisfy(\.isWhitespace) }.reversed().joined(separator: "\n")
            for trigger in triggers where entries[trigger] == nil { entries[trigger] = joined }
        }
        // Split on Characters so CRLF (one Character) counts as a single line break in line numbers.
        for (i, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if line.hasPrefix("==") {
                flush()
                let found = line.dropFirst(2).split(separator: "|").map { normalize(String($0)) }.filter { !$0.isEmpty }
                if found.isEmpty { skipped.append(i + 1) }
                triggers = found.isEmpty ? nil : found
                body = []
            } else if triggers != nil {
                body.append(line)
            } else if !line.allSatisfy(\.isWhitespace) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                // Text before the first header (or under a skipped one) belongs to no snippet.
                skipped.append(i + 1)
            }
        }
        flush()
        return (entries, skipped)
    }

    /// Re-reads the file when its modification date changed. A missing file means no snippets; an
    /// unreadable one keeps the last good snippets so a half-saved edit does not wipe them.
    func reloadIfChanged() {
        // Resolved every time, so editing a symlink's target (or re-pointing the link) is noticed.
        let target = url.resolvingSymlinksInPath()
        let stamp: Date?
        do {
            stamp = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            entries = [:]
            loadedStamp = nil
            loadedTarget = nil
            return
        } catch {
            Log.info("snippets: cannot stat \(target.path): \(error); keeping \(entries.count) triggers")
            return
        }
        guard stamp != loadedStamp || target != loadedTarget else { return }
        guard let data = try? Data(contentsOf: target), let text = String(data: data, encoding: .utf8) else {
            Log.info("snippets: cannot read \(url.path) as UTF-8; keeping \(entries.count) triggers")
            return
        }
        loadedStamp = stamp
        loadedTarget = target
        let parsed = Self.parse(text)
        entries = parsed.entries
        Log.info("snippets: \(entries.count) triggers" + (parsed.skipped.isEmpty ? "" : ", skipped lines \(parsed.skipped)"))
    }

    /// The body of the snippet whose trigger is the whole of any of `candidates`, tried in order.
    func match(_ candidates: String...) -> String? {
        reloadIfChanged()
        guard !entries.isEmpty else { return nil }
        for candidate in candidates {
            let key = Self.normalize(candidate)
            if !key.isEmpty, let body = entries[key] { return body }
        }
        return nil
    }
}
