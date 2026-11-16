import Foundation

/// Turns queries into the form the title index is sorted and searched in, so that "Beyoncé",
/// "beyonce" and "BEYONCE" all meet.
///
/// The index is built by the Kotlin `SearchText.normalize` (reader/core) running on the JVM, and
/// this must produce the same bytes for the same text. It follows that function step by step,
/// including which Unicode categories count as letters, digits and marks. `wikicheck normalize`
/// compares the two over a whole index.
///
/// One difference cannot be closed from here: both sides use their platform's Unicode tables, and
/// the JVM's are older. A letter added to Unicode since then is a letter here and unknown there.
/// In the June 2026 Wikipedia that affects about ten titles out of 16.8 million.
public enum SearchText {
    /// Lower-case, accents removed, apostrophes dropped, other punctuation turned into single spaces.
    public static func normalize(_ text: String) -> String {
        let folded = fold(text)
        // Titles made only of punctuation ("!!", "+") would vanish; keep them searchable as typed.
        return folded.isEmpty ? trim(text).lowercased() : folded
    }

    /// Kotlin's `trim()`: strips what `Char.isWhitespace` accepts, which is not quite Foundation's
    /// idea of whitespace (it leaves zero-width spaces alone, for one).
    private static func trim(_ text: String) -> String {
        func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
            default: return (0x09...0x0D).contains(scalar.value) || (0x1C...0x1F).contains(scalar.value)
            }
        }
        var scalars = text.unicodeScalars[...]
        while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        return String(scalars)
    }

    private static func fold(_ text: String) -> String {
        let isAscii = text.utf8.allSatisfy { $0 < 0x80 }
        let source = isAscii ? text : text.decomposedStringWithCompatibilityMapping
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in source.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                continue
            default:
                break
            }
            if apostrophes.contains(scalar.value) { continue }
            if isLetterOrDigit(scalar) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                if let replacement = special[scalar.value] {
                    out.append(contentsOf: replacement.unicodeScalars)
                } else {
                    out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
                }
            } else {
                pendingSpace = true
            }
        }
        return String(out)
    }

    /// What Java's `Character.isLetterOrDigit` accepts: the five letter categories and decimal digits.
    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
            return true
        default:
            return false
        }
    }

    private static let apostrophes: Set<UInt32> = [0x27, 0x2019, 0x02BC, 0x60]

    // Letters that Unicode decomposition leaves alone but people type as plain ASCII.
    private static let special: [UInt32: String] = [
        0xDF: "ss", 0xE6: "ae", 0xC6: "ae", 0x153: "oe", 0x152: "oe", 0xF8: "o", 0xD8: "o",
        0x111: "d", 0x110: "d", 0xF0: "d", 0xD0: "d", 0x142: "l", 0x141: "l", 0xFE: "th", 0xDE: "th",
        0x127: "h", 0x126: "h", 0x131: "i",
    ]

    /// Words too common to be worth finding a title by; titles are still found by their other words.
    public static let stopWords: Set<String> = ["a", "an", "and", "at", "by", "de", "for", "in", "la", "of", "on", "or", "the", "to"]
}
