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
class TitleIndex(file: File) : Closeable {
    private val channel = FileChannel.open(file.toPath(), StandardOpenOption.READ)
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
        val h = ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        while (h.hasRemaining()) if (channel.read(h, h.position().toLong()) < 0) break
        require(!h.hasRemaining() && h.getInt(0) == MAGIC) { "not a title index: $file" }
        require(h.getInt(4) == VERSION) { "title index version ${h.getInt(4)} is not supported; rebuild it" }
        zimUuid = ByteArray(16).also { h.position(8); h.get(it) }
        recordCount = h.getInt(24)
        innerCount = h.getInt(28)
        offsets = map(h.getLong(32), 4L * (recordCount + 1))
        blob = map(h.getLong(40), h.getLong(48))
        inner = map(h.getLong(56), INNER_SIZE.toLong() * innerCount)
        titleRanks = Ranks(map(h.getLong(64), Ranks.size(recordCount)), recordCount)
        innerRanks = Ranks(map(h.getLong(72), Ranks.size(innerCount)), innerCount)
    }

    private fun map(pos: Long, size: Long): ByteBuffer =
        channel.map(FileChannel.MapMode.READ_ONLY, pos, size).order(ByteOrder.LITTLE_ENDIAN)

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

    /** First position in [0, count) whose text is not before [query]; [after] moves past matches too. */
    private inline fun bound(count: Int, query: ByteArray, after: Boolean, compare: (Int, ByteArray) -> Int): Int {
        var lo = 0
        var hi = count
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

    private fun titleRange(q: ByteArray) = Range(bound(recordCount, q, false, ::compareTitle), bound(recordCount, q, true, ::compareTitle))
    private fun innerRange(q: ByteArray) = Range(bound(innerCount, q, false, ::compareInner), bound(innerCount, q, true, ::compareInner))

    /**
     * Up to [limit] titles for [query], best first:
     *  1. titles that are exactly the query;
     *  2. titles that start with it, most popular first;
     *  3. titles with the query starting at a later word, most popular first;
     *  4. if that leaves the list short and there are several words, titles containing all of them.
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

    /** A record chosen at random that is an article rather than a redirect, if one turns up. */
    fun randomArticle(random: java.util.Random): Hit? {
        if (recordCount == 0) return null
        repeat(64) {
            val h = hit(random.nextInt(recordCount))
            if (h.entryIndex == h.targetIndex) return h
        }
        return hit(random.nextInt(recordCount))
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
        private const val FEW = 8      // below this many results, also try the words in any order

        /** The index file that belongs to a ZIM file. */
        fun fileFor(zim: File): File = File(zim.path + ".idx")
    }
}
