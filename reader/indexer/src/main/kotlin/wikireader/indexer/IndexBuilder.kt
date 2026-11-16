package wikireader.indexer

import it.unimi.dsi.fastutil.ints.IntArrays
import it.unimi.dsi.fastutil.longs.LongArrays
import wikireader.core.SearchText
import wikireader.core.TitleIndex
import wikireader.core.ZimFile
import java.io.BufferedOutputStream
import java.io.File
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.BitSet
import java.util.stream.IntStream
import kotlin.math.ln
import kotlin.math.roundToInt

/**
 * Builds the title index for a ZIM file (see [TitleIndex] for the file layout). Runs on the Mac:
 * it holds every title in memory, which the e-reader could not.
 */
class IndexBuilder(
    private val zim: ZimFile,
    /** Sets of article paths known to be widely read, most select first (see [rankArticles]). */
    private val popular: List<Set<String>>,
    private val log: (String) -> Unit,
) {
    // Content entries are the contiguous index range [first, end) in namespace 'C'.
    private val first = zim.namespaceStart('C')
    private val end = zim.namespaceStart('D')
    private val count = end - first

    private val isArticle = BitSet(count)
    private val redirectTo = IntArray(count) { -1 } // absolute entry index, for redirects
    private val clusterOf = IntArray(count)          // where each article's content is, to look up its size
    private val blobOf = IntArray(count)
    private val tier = ByteArray(count)              // 1 + position of the first "popular" set holding the article, or 0
    private val text = ByteStore()                    // normalized titles of searchable entries, back to back
    private val textStart = IntArray(count + 1)       // entry i's title is text[textStart[i], textStart[i + 1])
    private val rawLength = ShortArray(count)         // length of the title as written, to pick the tidiest duplicate

    fun build(out: File) {
        readTitles()
        val target = IntArray(count) { -1 }
        val rank = rankArticles(resolveTargets(target))
        val records = sortedRecords(target)
        val inner = innerWords(records)
        write(out, records, target, inner, rank)
    }

    /** Entries that Wikipedia's ZIM marks as articles people look up, or null if it does not say. */
    private fun frontArticles(): BitSet? {
        val listing = zim.find('X', "listing/titleOrdered/v1") ?: return null
        val (pos, size) = zim.rawLocation(listing) ?: return null
        val front = BitSet(zim.entryCount)
        var done = 0L
        while (done < size) {
            val n = minOf(size - done, 4L * 1024 * 1024).toInt()
            val buf = zim.readRaw(pos + done, n)
            for (i in 0 until n / 4) front.set(buf.getInt(i * 4))
            done += n
        }
        return front
    }

    private fun readTitles() {
        val front = frontArticles()
        log("reading $count entries" + if (front == null) "" else " (${front.cardinality()} marked as articles)")
        zim.scanEntries(first, end) { e ->
            val i = e.index - first
            textStart[i] = text.size
            val wanted = (front == null || front.get(e.index)) && (e.isRedirect || zim.isHtml(e))
            if (wanted) {
                if (e.isRedirect) {
                    redirectTo[i] = e.redirectIndex
                } else {
                    isArticle.set(i)
                    clusterOf[i] = e.cluster
                    blobOf[i] = e.blob
                    tier[i] = (popular.indexOfFirst { e.path in it } + 1).toByte()
                }
                rawLength[i] = minOf(e.title.length, Short.MAX_VALUE.toInt()).toShort()
                text.append(SearchText.normalize(e.title).toByteArray(Charsets.UTF_8))
            }
        }
        textStart[count] = text.size
    }

    /**
     * Fills [target] with the article each searchable entry leads to (relative index), leaving -1 for
     * entries to omit. Returns how many redirects point at each article, a sign of how well known it is.
     */
    private fun resolveTargets(target: IntArray): IntArray {
        val inbound = IntArray(count)
        for (i in 0 until count) {
            if (isArticle.get(i)) {
                target[i] = i
            } else if (redirectTo[i] >= 0) {
                var t = redirectTo[i] - first
                var hops = 0
                while (t in 0 until count && !isArticle.get(t) && redirectTo[t] >= 0 && hops++ < 8) t = redirectTo[t] - first
                if (t !in 0 until count || !isArticle.get(t)) continue
                inbound[t]++
                // A redirect that reads the same as its article ("Beyonce" for "Beyoncé") adds nothing.
                if (compareText(i, 0, t, 0) != 0) target[i] = t
            }
        }
        return inbound
    }

    /**
     * A 0-255 popularity rank per article. Wikipedia's ZIM carries no page-view numbers, so this
     * combines the signals available:
     *  - membership of Kiwix's "top articles" selections, which are chosen by page views;
     *  - length, since well-developed articles are long;
     *  - the number of alternative names (redirects) pointing at it, capped because list articles
     *    collect thousands of them without being popular.
     */
    private fun rankArticles(inbound: IntArray): ByteArray {
        log("measuring ${isArticle.cardinality()} articles in ${zim.clusterCount} clusters")
        val sizes = arrayOfNulls<LongArray>(zim.clusterCount)
        val needed = BitSet(zim.clusterCount)
        var i = isArticle.nextSetBit(0)
        while (i >= 0) {
            needed.set(clusterOf[i])
            i = isArticle.nextSetBit(i + 1)
        }
        IntStream.range(0, zim.clusterCount).parallel().filter(needed::get).forEach { c ->
            sizes[c] = runCatching { zim.blobSizes(c) }.getOrNull()
        }
        val rank = ByteArray(count)
        val perTier = IntArray(TIER_BOOST.size)
        i = isArticle.nextSetBit(0)
        while (i >= 0) {
            val bytes = sizes[clusterOf[i]]?.getOrNull(blobOf[i]) ?: 0L
            // Tiny pages are stubs that only forward to a section of another article; never boost those.
            val boost = if (bytes < STUB_BYTES) 0 else TIER_BOOST[minOf(tier[i].toInt(), TIER_BOOST.size - 1)]
            if (boost > 0) perTier[tier[i].toInt()]++
            val score = boost + 7 * log2(1.0 + bytes / 1024.0) + 5 * log2(1.0 + minOf(inbound[i], 200))
            rank[i] = score.roundToInt().coerceIn(0, 255).toByte()
            i = isArticle.nextSetBit(i + 1)
        }
        if (popular.isNotEmpty()) log("articles found in the popular selections: " + perTier.drop(1).take(popular.size).joinToString())
        return rank
    }

    private fun log2(x: Double): Double = ln(x) / ln(2.0)

    /** Unsigned byte-wise comparison of two titles from the given byte offsets; a prefix sorts first. */
    private fun compareText(a: Int, fromA: Int, b: Int, fromB: Int): Int {
        var p = textStart[a] + fromA
        var q = textStart[b] + fromB
        val endA = textStart[a + 1]
        val endB = textStart[b + 1]
        val data = text.data
        while (p < endA && q < endB) {
            val d = (data[p++].toInt() and 0xFF) - (data[q++].toInt() and 0xFF)
            if (d != 0) return d
        }
        return (endA - p) - (endB - q)
    }

    /**
     * Searchable entries in index order: by title, then articles ahead of redirects, then the
     * shortest spelling ("USA" rather than "(USA)"), so that the duplicate kept is the tidiest one.
     */
    private fun sortedRecords(target: IntArray): IntArray {
        var searchable = 0
        for (i in 0 until count) if (target[i] >= 0 && textStart[i + 1] > textStart[i]) searchable++
        val all = IntArray(searchable)
        var next = 0
        for (i in 0 until count) if (target[i] >= 0 && textStart[i + 1] > textStart[i]) all[next++] = i
        log("sorting ${all.size} titles")
        IntArrays.parallelQuickSort(all) { a, b ->
            val c = compareText(a, 0, b, 0)
            if (c != 0) c
            else if (isArticle.get(a) != isArticle.get(b)) (if (isArticle.get(a)) -1 else 1)
            else if (rawLength[a] != rawLength[b]) rawLength[a].compareTo(rawLength[b])
            else a.compareTo(b)
        }
        var kept = 0
        for (i in all.indices) {
            val r = all[i]
            // Two titles that read the same and lead to the same article would be one result twice.
            val duplicate = kept > 0 && target[all[kept - 1]] == target[r] && compareText(all[kept - 1], 0, r, 0) == 0
            if (!duplicate) all[kept++] = r
        }
        return all.copyOf(kept)
    }

    /** One (record, offset) pair for every word after the first in every title, sorted by the text there. */
    private fun innerWords(records: IntArray): LongArray {
        val data = text.data
        var out = LongArray(records.size * 2)
        var n = 0
        for (r in records.indices) {
            val start = textStart[records[r]]
            val stop = textStart[records[r] + 1]
            var p = start + 1
            while (p < stop && p - start <= 255) {
                if (data[p - 1] == SPACE) {
                    var wordEnd = p
                    while (wordEnd < stop && data[wordEnd] != SPACE) wordEnd++
                    if (String(data, p, wordEnd - p, Charsets.UTF_8) !in SearchText.STOP_WORDS) {
                        if (n == out.size) out = out.copyOf(n + n / 2)
                        out[n++] = (r.toLong() shl 8) or (p - start).toLong()
                    }
                }
                p++
            }
        }
        out = out.copyOf(n)
        log("sorting $n later words")
        LongArrays.parallelQuickSort(out) { a, b ->
            val ra = (a ushr 8).toInt()
            val rb = (b ushr 8).toInt()
            val c = compareText(records[ra], (a and 0xFF).toInt(), records[rb], (b and 0xFF).toInt())
            if (c != 0) c else a.compareTo(b)
        }
        return out
    }

    private fun write(out: File, records: IntArray, target: IntArray, inner: LongArray, articleRank: ByteArray) {
        val n = records.size
        var blobSize = 0L
        for (r in records) blobSize += TitleIndex.RECORD_HEADER + (textStart[r + 1] - textStart[r])
        check(blobSize < Int.MAX_VALUE) { "title data is too large for this index format ($blobSize bytes)" }
        val offsetsPos = TitleIndex.HEADER_SIZE.toLong()
        val blobPos = offsetsPos + 4L * (n + 1)
        val innerPos = blobPos + blobSize
        val titleRanksPos = innerPos + TitleIndex.INNER_SIZE.toLong() * inner.size

        // An alternative name ranks below the article it leads to, and further below the wordier it
        // is: "Einstein" is a likely thing to type for Albert Einstein, "USA President Donald Trump"
        // is not, and without this every odd name for a famous article would crowd out real titles.
        val titleRanks = ByteArray(n) { r ->
            val entry = records[r]
            val base = articleRank[target[entry]].toInt() and 0xFF
            (if (target[entry] == entry) base else (base * redirectFactor(entry, target[entry])).roundToInt()).toByte()
        }
        val innerRanks = ByteArray(inner.size) { titleRanks[(inner[it] ushr 8).toInt()] }
        val innerRanksPos = titleRanksPos + titleRanks.size + maxima(titleRanks).size + maxima(maxima(titleRanks)).size

        val tmp = File(out.path + ".tmp")
        BufferedOutputStream(tmp.outputStream(), 1 shl 20).use { o ->
            val h = ByteBuffer.allocate(TitleIndex.HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN)
            h.putInt(TitleIndex.MAGIC).putInt(TitleIndex.VERSION).put(zim.uuid)
            h.putInt(n).putInt(inner.size).putLong(offsetsPos).putLong(blobPos).putLong(blobSize).putLong(innerPos)
            h.putLong(titleRanksPos).putLong(innerRanksPos)
            o.write(h.array())

            var offset = 0
            for (r in records) {
                o.int(offset)
                offset += TitleIndex.RECORD_HEADER + (textStart[r + 1] - textStart[r])
            }
            o.int(offset)

            for (r in records) {
                o.int(first + r)
                o.int(first + target[r])
                o.write(text.data, textStart[r], textStart[r + 1] - textStart[r])
            }

            for (v in inner) {
                o.int((v ushr 8).toInt())
                o.write((v and 0xFF).toInt())
            }

            for (ranks in listOf(titleRanks, innerRanks)) {
                o.write(ranks)
                o.write(maxima(ranks))
                o.write(maxima(maxima(ranks)))
            }
        }
        check(tmp.renameTo(out)) { "could not move $tmp into place" }
        log("wrote ${out.name}: $n titles, ${inner.size} later words, ${out.length() / 1_000_000} MB")
    }

    private fun words(entry: Int): List<String> =
        String(text.data, textStart[entry], textStart[entry + 1] - textStart[entry], Charsets.UTF_8)
            .split(' ').filter { it.isNotEmpty() && it !in SearchText.STOP_WORDS }

    /**
     * How much of its article's rank an alternative name keeps. A short form made of the article's
     * own words ("Einstein" for "Albert Einstein") keeps most; otherwise fewer words keep more.
     */
    private fun redirectFactor(redirect: Int, article: Int): Double {
        val own = words(redirect)
        if (own.isNotEmpty() && words(article).containsAll(own)) return SHORT_FORM_FACTOR
        return REDIRECT_FACTOR[minOf(own.size, 3)]
    }

    /** The largest (unsigned) value in each run of [TitleIndex.RANK_BLOCK] bytes. */
    private fun maxima(values: ByteArray): ByteArray {
        val block = TitleIndex.RANK_BLOCK
        return ByteArray((values.size + block - 1) / block) { b ->
            var max = 0
            for (i in b * block until minOf(values.size, (b + 1) * block)) max = maxOf(max, values[i].toInt() and 0xFF)
            max.toByte()
        }
    }

    private fun OutputStream.int(v: Int) {
        write(v)
        write(v ushr 8)
        write(v ushr 16)
        write(v ushr 24)
    }

    /** A growable byte array; all normalized titles end up in one of these. */
    private class ByteStore {
        var data = ByteArray(1 shl 26)
            private set
        var size = 0
            private set

        fun append(bytes: ByteArray) {
            if (size + bytes.size > data.size) {
                val wanted = maxOf(size.toLong() + bytes.size, data.size * 2L)
                check(wanted <= Int.MAX_VALUE - 16) { "too much title text for one array" }
                data = data.copyOf(wanted.toInt())
            }
            bytes.copyInto(data, size)
            size += bytes.size
        }
    }

    private companion object {
        const val SPACE = ' '.code.toByte()
        const val STUB_BYTES = 2048
        val TIER_BOOST = intArrayOf(0, 100, 55, 30)            // not selected, then each popular set in order
        val REDIRECT_FACTOR = doubleArrayOf(0.85, 0.85, 0.55, 0.35) // by number of significant words: 0-1, 2, 3+
        const val SHORT_FORM_FACTOR = 0.92
    }
}
