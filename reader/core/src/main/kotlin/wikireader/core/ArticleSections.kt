package wikireader.core

/**
 * Finds an article's section headings, for a menu that jumps to them.
 *
 * A heading is an `<h2>` to `<h6>` tag that carries an `id`, which is how MediaWiki writes every
 * section heading (`<h2 id="History">History</h2>`). The `id` is also the anchor the page scrolls
 * to. Tags are found by scanning the bytes, which is safe in UTF-8 and avoids decoding a megabyte
 * of article to read thirty headings.
 *
 * The iOS app has the same code in Swift (ArticleSections.swift), and the two must agree: compare
 * `indexer sections <file.zim> <path>` with `wikicheck sections <file.zim> <path>`. The rules both
 * follow:
 *  - a heading starts at `<h` + a digit 2 to 6 + whitespace, `/` or `>`, and its tag ends at the
 *    next `>`; its text runs to the next `</hN>` for the same N;
 *  - the id is what follows ` id="` inside the tag, up to the next `"`; a heading without one is
 *    skipped, and so is one whose id or title comes out empty;
 *  - the title is the text with every `<...>` removed, entities decoded, runs of whitespace
 *    (space, tab, line feed, carriage return, form feed, no-break space) made one space, and the
 *    ends trimmed;
 *  - entities decoded, in ids and titles: amp, lt, gt, quot, apos, nbsp, and numeric ones
 *    (`&#8211;`, `&#x2013;`) for valid code points. Anything else is left as written.
 */
object ArticleSections {
    /** [level] is 2 for a top-level section, 3 for a subsection of one, down to 6. */
    class Section(val level: Int, val id: String, val title: String)

    fun parse(html: ByteArray): List<Section> {
        val sections = ArrayList<Section>()
        var at = 0
        while (true) {
            val open = find(html, HEADING, at, html.size)
            if (open < 0 || open + 3 >= html.size) break
            at = open + 2
            val level = html[open + 2] - '0'.code
            if (level !in 2..6 || !endsTagName(html[open + 3])) continue
            val tagEnd = find(html, GT, open + 3, html.size)
            if (tagEnd < 0) break
            val close = find(html, closing(level), tagEnd + 1, html.size)
            if (close < 0) break
            at = close + 5
            val id = id(html, open, tagEnd) ?: continue
            val title = title(html, tagEnd + 1, close)
            if (id.isNotEmpty() && title.isNotEmpty()) sections += Section(level, id, title)
        }
        return sections
    }

    private fun endsTagName(b: Byte): Boolean =
        b == '>'.code.toByte() || b == '/'.code.toByte() || b == ' '.code.toByte() || b == '\t'.code.toByte() ||
            b == '\n'.code.toByte() || b == '\r'.code.toByte() || b == 0x0C.toByte()

    private fun closing(level: Int): ByteArray = "</h$level>".toByteArray(Charsets.US_ASCII)

    private fun id(html: ByteArray, from: Int, to: Int): String? {
        val start = find(html, ID, from, to)
        if (start < 0) return null
        val valueStart = start + ID.size
        val valueEnd = find(html, QUOTE, valueStart, to)
        if (valueEnd < 0) return null
        return decodeEntities(String(html, valueStart, valueEnd - valueStart, Charsets.UTF_8))
    }

    private fun title(html: ByteArray, from: Int, to: Int): String {
        val text = ByteArray(to - from)
        var length = 0
        var i = from
        while (i < to) {
            if (html[i] == '<'.code.toByte()) {
                val end = find(html, GT, i + 1, to)
                if (end < 0) break
                i = end + 1
            } else {
                text[length++] = html[i++]
            }
        }
        return collapseSpace(decodeEntities(String(text, 0, length, Charsets.UTF_8)))
    }

    private fun decodeEntities(s: String): String {
        if ('&' !in s) return s
        val out = StringBuilder(s.length)
        var i = 0
        while (i < s.length) {
            // An entity is "&", a name of one to nine characters, and ";".
            val end = if (s[i] == '&') s.indexOf(';', i + 1) else -1
            val decoded = if (end >= i + 2 && end <= i + 10) entity(s.substring(i + 1, end)) else null
            if (decoded == null) {
                out.append(s[i++])
            } else {
                out.append(decoded)
                i = end + 1
            }
        }
        return out.toString()
    }

    private fun entity(name: String): String? = when (name) {
        "amp" -> "&"
        "lt" -> "<"
        "gt" -> ">"
        "quot" -> "\""
        "apos" -> "'"
        "nbsp" -> " "
        else -> if (name[0] != '#') null else numeric(name)
    }

    /** `#8211` or `#x2013`, as the character it names; null unless it is a valid code point. */
    private fun numeric(name: String): String? {
        val hex = name.length > 1 && (name[1] == 'x' || name[1] == 'X')
        val digits = name.substring(if (hex) 2 else 1)
        if (digits.isEmpty()) return null
        var code = 0
        for (c in digits) {
            val value = when (c) {
                in '0'..'9' -> c - '0'
                in 'a'..'f' -> if (hex) c - 'a' + 10 else return null
                in 'A'..'F' -> if (hex) c - 'A' + 10 else return null
                else -> return null
            }
            code = code * (if (hex) 16 else 10) + value
            if (code > 0x10FFFF) return null
        }
        if (code == 0 || code in 0xD800..0xDFFF) return null
        return String(Character.toChars(code))
    }

    private fun collapseSpace(s: String): String {
        val out = StringBuilder(s.length)
        var gap = false
        for (c in s) {
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u000C' || c == ' ') {
                gap = out.isNotEmpty()
            } else {
                if (gap) out.append(' ')
                gap = false
                out.append(c)
            }
        }
        return out.toString()
    }

    /** The first position of [wanted] in [data] between [from] and [to], or -1. */
    private fun find(data: ByteArray, wanted: ByteArray, from: Int, to: Int): Int {
        val last = to - wanted.size
        var i = from
        outer@ while (i <= last) {
            for (k in wanted.indices) {
                if (data[i + k] != wanted[k]) {
                    i++
                    continue@outer
                }
            }
            return i
        }
        return -1
    }

    private val HEADING = "<h".toByteArray(Charsets.US_ASCII)
    private val GT = ">".toByteArray(Charsets.US_ASCII)
    private val QUOTE = "\"".toByteArray(Charsets.US_ASCII)
    private val ID = " id=\"".toByteArray(Charsets.US_ASCII)
}
