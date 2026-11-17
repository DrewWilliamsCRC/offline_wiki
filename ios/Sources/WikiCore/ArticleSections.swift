import Foundation

/// Finds an article's section headings, for a menu that jumps to them.
///
/// A heading is an `<h2>` to `<h6>` tag that carries an `id`, which is how MediaWiki writes every
/// section heading (`<h2 id="History">History</h2>`). The `id` is also the anchor the page scrolls
/// to. Tags are found by scanning the bytes, which is safe in UTF-8 and avoids decoding a megabyte
/// of article to read thirty headings.
///
/// This is the Swift counterpart of ArticleSections.kt in reader/core, and the two must agree:
/// compare `wikicheck sections <file.zim> <path>` with `indexer sections <file.zim> <path>`. The
/// rules both follow:
///  - a heading starts at `<h` + a digit 2 to 6 + whitespace, `/` or `>`, and its tag ends at the
///    next `>`; its text runs to the next `</hN>` for the same N;
///  - the id is what follows ` id="` inside the tag, up to the next `"`; a heading without one is
///    skipped, and so is one whose id or title comes out empty;
///  - the title is the text with every `<...>` removed, entities decoded, runs of whitespace
///    (space, tab, line feed, carriage return, form feed, no-break space) made one space, and the
///    ends trimmed;
///  - entities decoded, in ids and titles: amp, lt, gt, quot, apos, nbsp, and numeric ones
///    (`&#8211;`, `&#x2013;`) for valid code points. Anything else is left as written.
public enum ArticleSections {
    /// `level` is 2 for a top-level section, 3 for a subsection of one, down to 6.
    public struct Section: Hashable, Identifiable, Sendable {
        public let level: Int
        public let id: String
        public let title: String
    }

    public static func parse(_ html: Data) -> [Section] {
        let data = [UInt8](html)
        var sections: [Section] = []
        var at = 0
        while true {
            guard let open = find(data, heading, at, data.count), open + 3 < data.count else { break }
            at = open + 2
            let level = Int(data[open + 2]) - 0x30
            guard (2...6).contains(level), endsTagName(data[open + 3]) else { continue }
            guard let tagEnd = find(data, gt, open + 3, data.count) else { break }
            guard let close = find(data, Array("</h\(level)>".utf8), tagEnd + 1, data.count) else { break }
            at = close + 5
            guard let id = id(data, open, tagEnd) else { continue }
            let title = title(data, tagEnd + 1, close)
            if !id.isEmpty, !title.isEmpty { sections.append(Section(level: level, id: id, title: title)) }
        }
        return sections
    }

    private static func endsTagName(_ b: UInt8) -> Bool {
        b == 0x3E || b == 0x2F || b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    private static func id(_ data: [UInt8], _ from: Int, _ to: Int) -> String? {
        guard let start = find(data, idAttribute, from, to) else { return nil }
        let valueStart = start + idAttribute.count
        guard let valueEnd = find(data, quote, valueStart, to) else { return nil }
        return decodeEntities(String(decoding: data[valueStart..<valueEnd], as: UTF8.self))
    }

    private static func title(_ data: [UInt8], _ from: Int, _ to: Int) -> String {
        var text: [UInt8] = []
        text.reserveCapacity(to - from)
        var i = from
        while i < to {
            if data[i] == 0x3C {
                guard let end = find(data, gt, i + 1, to) else { break }
                i = end + 1
            } else {
                text.append(data[i])
                i += 1
            }
        }
        return collapseSpace(decodeEntities(String(decoding: text, as: UTF8.self)))
    }

    private static func decodeEntities(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        guard scalars.contains("&") else { return s }
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            // An entity is "&", a name of one to nine characters, and ";".
            var decoded: String?
            var end = -1
            if scalars[i] == "&", let semicolon = scalars[(i + 1)...].firstIndex(of: ";") {
                end = semicolon
                if end >= i + 2, end <= i + 10 {
                    var name = String.UnicodeScalarView()
                    name.append(contentsOf: scalars[(i + 1)..<end])
                    decoded = entity(String(name))
                }
            }
            if let decoded {
                out.append(contentsOf: decoded.unicodeScalars)
                i = end + 1
            } else {
                out.append(scalars[i])
                i += 1
            }
        }
        return String(out)
    }

    private static func entity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default: return name.unicodeScalars.first == "#" ? numeric(name) : nil
        }
    }

    /// `#8211` or `#x2013`, as the character it names; nil unless it is a valid code point.
    private static func numeric(_ name: String) -> String? {
        let scalars = Array(name.unicodeScalars)
        let hex = scalars.count > 1 && (scalars[1] == "x" || scalars[1] == "X")
        let digits = scalars[(hex ? 2 : 1)...]
        if digits.isEmpty { return nil }
        var code: UInt32 = 0
        for c in digits {
            let value: UInt32
            switch c.value {
            case 0x30...0x39: value = c.value - 0x30
            case 0x61...0x66:
                guard hex else { return nil }
                value = c.value - 0x61 + 10
            case 0x41...0x46:
                guard hex else { return nil }
                value = c.value - 0x41 + 10
            default: return nil
            }
            code = code * (hex ? 16 : 10) + value
            if code > 0x10FFFF { return nil }
        }
        if code == 0 || (0xD800...0xDFFF).contains(code) { return nil }
        return Unicode.Scalar(code).map { String($0) }
    }

    private static func collapseSpace(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var gap = false
        for c in s.unicodeScalars {
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{000C}" || c == "\u{00A0}" {
                gap = !out.isEmpty
            } else {
                if gap { out.append(" ") }
                gap = false
                out.append(c)
            }
        }
        return String(out)
    }

    /// The first position of `wanted` in `data` between `from` and `to`, or nil.
    private static func find(_ data: [UInt8], _ wanted: [UInt8], _ from: Int, _ to: Int) -> Int? {
        let last = to - wanted.count
        var i = from
        outer: while i <= last {
            for k in 0..<wanted.count where data[i + k] != wanted[k] {
                i += 1
                continue outer
            }
            return i
        }
        return nil
    }

    private static let heading = Array("<h".utf8)
    private static let gt = Array(">".utf8)
    private static let quote = Array("\"".utf8)
    private static let idAttribute = Array(" id=\"".utf8)
}
