package wikireader.core

import java.io.Closeable
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import java.util.PriorityQueue

/**
 * The purpose-built title index that sits next to a ZIM file (`<name>.zim.idx`).
 *
 * It holds one record per searchable title, sorted by normalized title, plus a second sorted list of
 * every later word in every title, and a popularity rank for each. A search is a couple of binary
 * searches over a memory-mapped file followed by picking the best-ranked matches: a few dozen page
 * reads, however large Wikipedia is.
 *
 * File layout (little-endian):
 *   header      96 bytes: "WRIX", version, ZIM uuid, record count N, inner-word count M, section positions
 *   offsets     (N + 1) x u32: where each record starts in the blob; the last is the blob's size
 *   blob        per record: u32 ZIM entry index, u32 target entry index (itself unless a redirect),
 *               then the normalized title in UTF-8
 *   inner       M x 5 bytes: u32 record number, u8 byte offset of a word inside that record's title;
 *               sorted by the title text from that word onward
 *   title ranks one byte per record, then the maximum of every 256, then of every 65536
 *   inner ranks the same for the inner list (each entry carries its record's rank)
 */
class TitleIndex(private val channel: FileChannel, private val name: String) : Closeable {
    /** [channel] is open for reading, and becomes this index's to close; [name] is for messages. */
    constructor(file: File) : this(FileChannel.open(file.toPath(), StandardOpenOption.READ), file.name)
    val zimUuid: ByteArray
    val recordCount: Int
    val innerCount: Int
    private val offsets: ByteBuffer
    private val blob: ByteBuffer
    private val inner: ByteBuffer
    private val titleRanks: Ranks
    private val innerRanks: Ranks

    /** A search result: the title that matched and the entry it leads to. */
    data class Hit(val entryIndex: Int, val targetIndex: Int)

    init {
        try {
            val h = ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN)
            while (h.hasRemaining()) if (channel.read(h, h.position().toLong()) < 0) break
            require(!h.hasRemaining() && h.getInt(0) == MAGIC) { "$name is not a title index" }
            val version = h.getInt(4)
            require(version == VERSION) {
                // Which side is behind decides what to do about it.
                if (version > VERSION) "$name is a newer kind of index (version $version) than this reader knows (version $VERSION); install the newer reader"
                else "$name is an older kind of index (version $version) than this reader needs (version $VERSION); build it again"
            }
            zimUuid = ByteArray(16).also { h.position(8); h.get(it) }
            recordCount = h.getInt(24)
            innerCount = h.getInt(28)
            // A copy that stopped part-way has the header of a whole index and less than all of it.
            val size = channel.size()
            fun section(pos: Long, length: Long): ByteBuffer {
                require(pos >= 0 && length >= 0 && pos <= size - length) { "$name is cut short; copy it again" }
                return channel.map(FileChannel.MapMode.READ_ONLY, pos, length).order(ByteOrder.LITTLE_ENDIAN)
            }
            require(recordCount >= 0 && innerCount >= 0) { "$name is too large for this reader" }
            offsets = section(h.getLong(32), 4L * (recordCount + 1))
            blob = section(h.getLong(40), h.getLong(48))
            inner = section(h.getLong(56), INNER_SIZE.toLong() * innerCount)
            titleRanks = Ranks(section(h.getLong(64), Ranks.size(recordCount)), recordCount)
            innerRanks = Ranks(section(h.getLong(72), Ranks.size(innerCount)), innerCount)
        } catch (e: Throwable) {
            channel.close()
            throw e
        }
    }

    private fun recordStart(record: Int): Int = offsets.getInt(record * 4)
    private fun titleStart(record: Int): Int = recordStart(record) + RECORD_HEADER
    private fun titleEnd(record: Int): Int = recordStart(record + 1)

    private fun hit(record: Int): Hit = recordStart(record).let { Hit(blob.getInt(it), blob.getInt(it + 4)) }

    /**
     * Compares the text of [record] from byte [from] with [query].
     * Negative: the text sorts before the query. Zero: the text starts with the query. Positive: after.
     */
    private fun comparePrefix(record: Int, from: Int, query: ByteArray): Int {
        var p = titleStart(record) + from
        val end = titleEnd(record)
        for (q in query) {
            if (p >= end) return -1
            val d = (blob.get(p++).toInt() and 0xFF) - (q.toInt() and 0xFF)
            if (d != 0) return d
        }
        return 0
    }

    /** First position in [from, to) whose text is not before [query]; [after] moves past matches too. */
    private inline fun bound(from: Int, to: Int, query: ByteArray, after: Boolean, compare: (Int, ByteArray) -> Int): Int {
        var lo = from
        var hi = to
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            val c = compare(mid, query)
            if (c < 0 || (after && c == 0)) lo = mid + 1 else hi = mid
        }
        return lo
    }

    private fun compareTitle(record: Int, query: ByteArray): Int = comparePrefix(record, 0, query)

    private fun innerRecord(i: Int): Int = inner.getInt(i * INNER_SIZE)

    private fun compareInner(i: Int, query: ByteArray): Int =
        comparePrefix(innerRecord(i), inner.get(i * INNER_SIZE + 4).toInt() and 0xFF, query)

    private class Range(val from: Int, val to: Int) {
        val size: Int get() = to - from
    }

    private fun titleRange(q: ByteArray) = Range(bound(0, recordCount, q, false, ::compareTitle), bound(0, recordCount, q, true, ::compareTitle))
    private fun innerRange(q: ByteArray) = Range(bound(0, innerCount, q, false, ::compareInner), bound(0, innerCount, q, true, ::compareInner))

    /**
     * Up to [limit] titles for [query], best first:
     *  1. titles that are exactly the query;
     *  2. titles that start with it, most popular first;
     *  3. titles with the query starting at a later word, most popular first;
     *  4. if that leaves the list short and there are several words, titles containing all of them;
     *  5. if the list is still short, a few titles one slip of the fingers away (see [nearMisses]).
     * Each article appears once, under the first title that found it. [cancelled] is polled so a
     * search made stale by the next keystroke can stop early.
     */
    fun search(query: String, limit: Int, cancelled: () -> Boolean = { false }): List<Hit> {
        val normalized = SearchText.normalize(query)
        if (normalized.isEmpty() || limit <= 0) return emptyList()
        val q = normalized.toByteArray(Charsets.UTF_8)
        val hits = ArrayList<Hit>(limit)
        val seenTargets = HashSet<Int>()
        fun add(record: Int): Boolean {
            val h = hit(record)
            if (seenTargets.add(h.targetIndex)) hits += h
            return hits.size < limit && !cancelled()
        }

        val titles = titleRange(q)
        // Exact titles sort first within the range, being the shortest strings that start with the
        // query. Several can read the same ("Par", "PAR", "Pär"); lead with the best-known few.
        var exactEnd = titles.from
        while (exactEnd < titles.to && exactEnd - titles.from < MAX_EXACT && titleEnd(exactEnd) - titleStart(exactEnd) == q.size) exactEnd++
        for (r in (titles.from until exactEnd).sortedByDescending(titleRanks::rank).take(LEAD_EXACT)) if (!add(r)) return hits
        if (!titleRanks.descending(titles.from, titles.to, VISITS, ::add)) return hits

        val inners = innerRange(q)
        if (!innerRanks.descending(inners.from, inners.to, VISITS) { add(innerRecord(it)) }) return hits

        val words = normalized.split(' ').filter { it.isNotEmpty() && it !in SearchText.STOP_WORDS }
        if (words.size > 1 && hits.size < FEW) allWords(words, ::add)

        if (hits.size < minOf(FEW, limit) && !cancelled()) {
            var more = NEAR_MOST
            for (record in nearMisses(q, cancelled)) {
                val had = hits.size
                if (!add(record) || (hits.size > had && --more == 0)) break
            }
        }
        return hits
    }

    /**
     * Titles containing every word (as a word prefix), found by walking the rarest word's matches
     * from most popular down. Stop words are left out by the caller: they are not in the inner list.
     */
    private fun allWords(words: List<String>, add: (Int) -> Boolean) {
        val keys = words.map { it.toByteArray(Charsets.UTF_8) }
        var best = -1
        var bestTitles = Range(0, 0)
        var bestInners = Range(0, 0)
        for ((n, key) in keys.withIndex()) {
            val t = titleRange(key)
            val i = innerRange(key)
            if (best < 0 || t.size.toLong() + i.size < bestTitles.size.toLong() + bestInners.size) {
                best = n
                bestTitles = t
                bestInners = i
            }
        }
        val others = keys.filterIndexed { n, _ -> n != best }
        fun consider(record: Int): Boolean = !others.all { hasWord(record, it) } || add(record)
        if (!titleRanks.descending(bestTitles.from, bestTitles.to, VISITS, ::consider)) return
        innerRanks.descending(bestInners.from, bestInners.to, VISITS) { consider(innerRecord(it)) }
    }

    /**
     * Titles one slip away from the query [q], for a search that found next to nothing: a letter
     * too many, one missing, two swapped or one wrong ("berln", "nvidai", "the beatls"). Each
     * corrected spelling is looked up as the start of a title, as the query itself is.
     *
     * Best first: the titles in which a corrected spelling ends where a word ends ("Berlin",
     * "Berlin Wall") come before those in which it stops inside a word ("Berlusconi", from
     * "berl"), and within each kind the most popular come first.
     *
     * The first letter is taken as right, and so is every byte of a letter that takes more than
     * one. A query shorter than [NEAR_MIN] bytes is left alone: one slip from a few letters is
     * half the alphabet.
     */
    private fun nearMisses(q: ByteArray, cancelled: () -> Boolean): List<Int> {
        if (q.size < NEAR_MIN) return emptyList()
        val whole = ArrayList<Int>()
        val part = ArrayList<Int>()
        val tried = HashSet<String>() // a doubled letter gives the same spelling twice
        // Takes the titles in [from, to) that start with [spelling]; the range holds all of them.
        fun look(spelling: ByteArray, from: Int, to: Int) {
            if (!tried.add(String(spelling, Charsets.ISO_8859_1))) return
            val first = bound(from, to, spelling, false, ::compareTitle)
            if (first >= to || compareTitle(first, spelling) != 0) return
            val end = bound(first, to, spelling, true, ::compareTitle)
            // The titles that are the spelling and nothing more sort first, then those that go on
            // with a space; `word` is where both have ended.
            val word = bound(first, end, spelling + SPACE, true, ::compareTitle)
            titleRanks.descending(first, word, NEAR_EACH) { whole += it; true }
            titleRanks.descending(word, end, NEAR_EACH) { part += it; true }
        }
        // [from, to) holds the titles that start with the query's first i bytes. A slip at byte i
        // leaves those as they are, so every correction of it is in there; and once no title
        // starts with them, no slip further along can lead to one.
        var from = 0
        var to = recordCount
        fun narrow(start: ByteArray) {
            from = bound(from, to, start, false, ::compareTitle)
            to = bound(from, to, start, true, ::compareTitle)
        }
        narrow(q.copyOf(1))
        for (i in 1 until q.size) {
            if (from >= to || cancelled()) break
            val here = q[i]
            if (here >= 0) { // one byte, one letter
                val before = q.copyOf(i)
                val after = q.copyOfRange(i + 1, q.size)
                look(before + after, from, to) // typed a letter too many
                if (i + 1 < q.size && q[i + 1] >= 0 && q[i + 1] != here) { // typed two the wrong way round
                    look(before + q[i + 1] + here + q.copyOfRange(i + 2, q.size), from, to)
                }
                if (here != SPACE && q[i - 1] != SPACE) look(before + SPACE + here + after, from, to) // left a space out
                for (letter in 'a'.code..'z'.code) {
                    // Only letters that some title has at this point are worth trying.
                    val next = before + letter.toByte()
                    val first = bound(from, to, next, false, ::compareTitle)
                    val last = bound(first, to, next, true, ::compareTitle)
                    if (first == last) continue
                    if (letter.toByte() != here) look(next + after, first, last) // typed a wrong letter
                    look(next + here + after, first, last) // left a letter out
                }
            }
            narrow(q.copyOf(i + 1))
        }
        val best = compareByDescending<Int> { titleRanks.rank(it) }.thenBy { it }
        return whole.sortedWith(best) + part.sortedWith(best)
    }

    /** Whether some word of the record's title starts with [word]. */
    private fun hasWord(record: Int, word: ByteArray): Boolean {
        val start = titleStart(record)
        val end = titleEnd(record)
        var p = start
        while (p < end) {
            if (p == start || blob.get(p - 1) == SPACE) {
                var k = 0
                while (k < word.size && p + k < end && blob.get(p + k) == word[k]) k++
                if (k == word.size) return true
            }
            p++
        }
        return false
    }

    /**
     * A record chosen at random that is an article with something to read: not another name for
     * one, and not one of the tiny pages that only forward to a section of another article (over a
     * million of them, which the index builder ranks below [MIN_ARTICLE_RANK]). If none turns up,
     * any article, and failing that any record.
     */
    fun randomArticle(random: java.util.Random): Hit? {
        if (recordCount == 0) return null
        var other: Hit? = null
        repeat(RANDOM_TRIES) {
            val record = random.nextInt(recordCount)
            val h = hit(record)
            if (h.entryIndex == h.targetIndex) {
                if (titleRanks.rank(record) >= MIN_ARTICLE_RANK) return h
                if (other == null) other = h
            }
        }
        return other ?: hit(random.nextInt(recordCount))
    }

    override fun close() = channel.close()

    /**
     * One rank byte per position, with the maximum of every 256 and of every 65536 stored after
     * them, so the best-ranked positions in any range can be found without reading the whole range.
     */
    private class Ranks(private val data: ByteBuffer, private val count: Int) {
        private val blocks = (count + BLOCK - 1) / BLOCK
        private val level1 = count
        private val level2 = count + blocks

        private fun value(at: Int): Int = data.get(at).toInt() and 0xFF

        fun rank(position: Int): Int = value(position)

        /**
         * Calls [visit] with positions in [from, to) from the highest rank down, ties in position
         * order, until it returns false or [budget] positions have been visited.
         * Returns false if [visit] asked to stop.
         */
        fun descending(from: Int, to: Int, budget: Int, visit: (Int) -> Boolean): Boolean {
            if (from >= to) return true
            // Node = rank, then the first position it covers, then its level (0 = one position).
            val queue = PriorityQueue<LongArray>(64) { a, b ->
                if (a[0] != b[0]) b[0].compareTo(a[0]) else if (a[1] != b[1]) a[1].compareTo(b[1]) else b[2].compareTo(a[2])
            }
            fun push(level: Int, index: Int) {
                val rank = value(if (level == 0) index else if (level == 1) level1 + index else level2 + index)
                val start = if (level == 0) index.toLong() else if (level == 1) index.toLong() * BLOCK else index.toLong() * BLOCK * BLOCK
                queue.add(longArrayOf(rank.toLong(), start, level.toLong(), index.toLong()))
            }
            var i = from
            while (i < to) {
                if (i % (BLOCK * BLOCK) == 0 && i.toLong() + BLOCK * BLOCK <= to) {
                    push(2, i / (BLOCK * BLOCK))
                    i += BLOCK * BLOCK
                } else if (i % BLOCK == 0 && i + BLOCK <= to) {
                    push(1, i / BLOCK)
                    i += BLOCK
                } else {
                    push(0, i++)
                }
            }
            var left = budget
            while (true) {
                val node = queue.poll() ?: return true
                val index = node[3].toInt()
                when (node[2].toInt()) {
                    0 -> {
                        if (!visit(index)) return false
                        if (--left <= 0) return true
                    }
                    1 -> for (p in index * BLOCK until minOf(count, (index + 1) * BLOCK)) push(0, p)
                    else -> for (b in index * BLOCK until minOf(blocks, (index + 1) * BLOCK)) push(1, b)
                }
            }
        }

        companion object {
            const val BLOCK = 256

            /** Bytes taken by the ranks of [count] positions together with both levels of maxima. */
            fun size(count: Int): Long {
                val blocks = (count + BLOCK - 1) / BLOCK
                return count.toLong() + blocks + (blocks + BLOCK - 1) / BLOCK
            }
        }
    }

    companion object {
        const val MAGIC = 0x58495257 // "WRIX"
        const val VERSION = 2
        const val HEADER_SIZE = 96
        const val RECORD_HEADER = 8
        const val INNER_SIZE = 5
        const val RANK_BLOCK = Ranks.BLOCK
        private const val SPACE = ' '.code.toByte()
        private const val MAX_EXACT = 64
        private const val LEAD_EXACT = 3
        private const val VISITS = 600 // matches examined per step; many titles lead to the same article
        private const val FEW = 8      // below this many results, also try the words in any order, then near misses
        private const val NEAR_MIN = 5  // the shortest query, in bytes, that near misses are looked for
        private const val NEAR_EACH = 16 // titles taken from each corrected spelling: its best-ranked
        private const val NEAR_MOST = 8 // near misses added to a list at most
        private const val RANDOM_TRIES = 64

        /**
         * The lowest rank the index builder gives an article with something to read. A page under
         * 2 KB, which is what a forwarding page is, scores below this unless other names point at
         * it (see IndexBuilder.rankArticles).
         */
        const val MIN_ARTICLE_RANK = 12

        /** The index file that belongs to a ZIM file. */
        fun fileFor(zim: File): File = File(zim.path + ".idx")
    }
}
