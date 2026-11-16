package wikireader.core

import java.text.Normalizer

/**
 * Turns titles and queries into the form the title index is sorted and searched in, so that
 * "Beyoncé", "beyonce" and "BEYONCE" all meet. The index builder and the app must agree on this
 * exactly; both call this one function.
 */
object SearchText {
    /** Lower-case, accents removed, apostrophes dropped, other punctuation turned into single spaces. */
    fun normalize(text: String): String {
        val folded = fold(text)
        // Titles made only of punctuation ("!!", "+") would vanish; keep them searchable as typed.
        return folded.ifEmpty { text.trim().lowercase() }
    }

    private fun fold(text: String): String {
        val source = if (isAscii(text)) text else Normalizer.normalize(text, Normalizer.Form.NFKD)
        val out = StringBuilder(source.length)
        var pendingSpace = false
        var i = 0
        while (i < source.length) {
            val cp = source.codePointAt(i)
            i += Character.charCount(cp)
            val type = Character.getType(cp)
            if (type == Character.NON_SPACING_MARK.toInt() || type == Character.COMBINING_SPACING_MARK.toInt() ||
                type == Character.ENCLOSING_MARK.toInt()
            ) continue
            if (cp == '\''.code || cp == '’'.code || cp == 'ʼ'.code || cp == '`'.code) continue
            if (Character.isLetterOrDigit(cp)) {
                if (pendingSpace && out.isNotEmpty()) out.append(' ')
                pendingSpace = false
                val special = SPECIAL[cp]
                if (special != null) out.append(special) else out.appendCodePoint(Character.toLowerCase(cp))
            } else {
                pendingSpace = true
            }
        }
        return out.toString()
    }

    private fun isAscii(text: String): Boolean {
        for (c in text) if (c.code >= 0x80) return false
        return true
    }

    // Letters that Unicode decomposition leaves alone but people type as plain ASCII.
    private val SPECIAL: Map<Int, String> = mapOf(
        'ß' to "ss", 'æ' to "ae", 'Æ' to "ae", 'œ' to "oe", 'Œ' to "oe", 'ø' to "o", 'Ø' to "o",
        'đ' to "d", 'Đ' to "d", 'ð' to "d", 'Ð' to "d", 'ł' to "l", 'Ł' to "l", 'þ' to "th", 'Þ' to "th",
        'ħ' to "h", 'Ħ' to "h", 'ı' to "i",
    ).mapKeys { it.key.code }

    /** Words too common to be worth finding a title by; titles are still found by their other words. */
    val STOP_WORDS: Set<String> = setOf("a", "an", "and", "at", "by", "de", "for", "in", "la", "of", "on", "or", "the", "to")
}
