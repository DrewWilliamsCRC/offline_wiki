package wikireader.core

import com.github.luben.zstd.ZstdInputStream
import java.io.Closeable
import java.io.EOFException
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption

/**
 * Read-only access to a ZIM archive (the format Kiwix distributes Wikipedia in).
 *
 * Layout, as far as this reader needs it: an 80-byte header; a list of MIME types; a "path pointer
 * list" giving the file offset of every directory entry, sorted by namespace then path; and clusters
 * of blobs, each cluster optionally zstd-compressed. All integers are little-endian.
 *
 * Safe to use from several threads: every read is positional.
 */
class ZimFile(file: File) : Closeable {
    private val channel: FileChannel = FileChannel.open(file.toPath(), StandardOpenOption.READ)

    val uuid: ByteArray
    val entryCount: Int
    val clusterCount: Int
    val mimeTypes: List<String>
    private val pathPtrPos: Long
    private val clusterPtrPos: Long

    /** One directory entry: either an item stored in a cluster, or a redirect to another entry. */
    class Entry(
        val index: Int,
        val namespace: Char,
        val path: String,
        private val rawTitle: String,
        private val mimeIndex: Int,
        val redirectIndex: Int,
        val cluster: Int,
        val blob: Int,
    ) {
        val isRedirect: Boolean get() = mimeIndex == REDIRECT

        /** Display title. ZIM leaves the title empty when it equals the path. */
        val title: String get() = rawTitle.ifEmpty { path }

        internal val mime: Int get() = mimeIndex
    }

    init {
        val h = read(0, HEADER_SIZE)
        require(h.getInt(0) == MAGIC) { "not a ZIM file: $file" }
        uuid = ByteArray(16).also { h.position(8); h.get(it) }
        entryCount = h.getInt(24)
        clusterCount = h.getInt(28)
        pathPtrPos = h.getLong(32)
        clusterPtrPos = h.getLong(48)
        mimeTypes = readMimeTypes(h.getLong(56))
    }

    private fun readMimeTypes(pos: Long): List<String> {
        val bytes = read(pos, 8192).let { b -> ByteArray(b.remaining()).also(b::get) }
        val out = ArrayList<String>()
        var start = 0
        while (start < bytes.size) {
            val end = (start until bytes.size).firstOrNull { bytes[it] == 0.toByte() } ?: break
            if (end == start) break // an empty string ends the list
            out += String(bytes, start, end - start, Charsets.UTF_8)
            start = end + 1
        }
        return out
    }

    /** Reads up to [length] bytes at [pos]; fewer only at the end of the file. */
    private fun read(pos: Long, length: Int): ByteBuffer {
        val buf = ByteBuffer.allocate(length).order(ByteOrder.LITTLE_ENDIAN)
        var p = pos
        while (buf.hasRemaining()) {
            val n = channel.read(buf, p)
            if (n < 0) break
            p += n
        }
        buf.flip()
        return buf
    }

    private fun readFully(pos: Long, length: Int): ByteBuffer =
        read(pos, length).also { if (it.remaining() < length) throw EOFException("short read at $pos") }

    /** File offset of the directory entry with this index. */
    fun entryOffset(index: Int): Long {
        require(index in 0 until entryCount) { "entry index $index out of range" }
        return readFully(pathPtrPos + 8L * index, 8).getLong(0)
    }

    fun entry(index: Int): Entry = parseEntry(index, direntBytes(entryOffset(index)))

    /**
     * Visits entries [from, to) in order. Much faster than calling [entry] in a loop: directory
     * entries sit next to each other in the file, so whole batches are read at once.
     */
    fun scanEntries(from: Int, to: Int, action: (Entry) -> Unit) {
        var i = from
        while (i < to) {
            val n = minOf(SCAN_BATCH, to - i)
            val pointers = readFully(pathPtrPos + 8L * i, 8 * n)
            var lo = Long.MAX_VALUE
            var hi = 0L
            for (k in 0 until n) pointers.getLong(8 * k).let { lo = minOf(lo, it); hi = maxOf(hi, it) }
            val span = hi - lo + MAX_DIRENT
            if (span > SCAN_SPAN) {
                for (k in 0 until n) action(entry(i + k))
            } else {
                val chunk = read(lo, span.toInt())
                for (k in 0 until n) {
                    chunk.position((pointers.getLong(8 * k) - lo).toInt())
                    action(parseEntry(i + k, chunk.slice().order(ByteOrder.LITTLE_ENDIAN)))
                }
            }
            i += n
        }
    }

    /** The raw bytes of a directory entry, at least through the end of its title. */
    private fun direntBytes(offset: Long): ByteBuffer {
        var size = 320
        while (true) {
            val buf = read(offset, size)
            if (direntComplete(buf) || buf.remaining() < size || size >= MAX_DIRENT) return buf
            size *= 4
        }
    }

    private fun direntComplete(buf: ByteBuffer): Boolean {
        if (buf.remaining() < 16) return false
        var zeros = 0
        for (i in pathStart(buf) until buf.limit()) if (buf.get(i) == 0.toByte() && ++zeros == 2) return true
        return false
    }

    private fun pathStart(buf: ByteBuffer): Int = if ((buf.getShort(0).toInt() and 0xFFFF) == REDIRECT) 12 else 16

    private fun parseEntry(index: Int, buf: ByteBuffer): Entry {
        val mime = buf.getShort(0).toInt() and 0xFFFF
        val namespace = (buf.get(3).toInt() and 0xFF).toChar()
        val start = pathStart(buf)
        val pathEnd = indexOfZero(buf, start)
        val titleEnd = indexOfZero(buf, pathEnd + 1)
        val redirect = mime == REDIRECT
        return Entry(
            index = index,
            namespace = namespace,
            path = string(buf, start, pathEnd),
            rawTitle = string(buf, pathEnd + 1, titleEnd),
            mimeIndex = mime,
            redirectIndex = if (redirect) buf.getInt(8) else -1,
            cluster = if (redirect) -1 else buf.getInt(8),
            blob = if (redirect) -1 else buf.getInt(12),
        )
    }

    private fun indexOfZero(buf: ByteBuffer, from: Int): Int {
        for (i in from until buf.limit()) if (buf.get(i) == 0.toByte()) return i
        throw IllegalStateException("unterminated string in directory entry")
    }

    private fun string(buf: ByteBuffer, from: Int, to: Int): String =
        String(buf.array(), buf.arrayOffset() + from, to - from, Charsets.UTF_8)

    /** Finds an entry by namespace and exact path with a binary search of the path pointer list. */
    fun find(namespace: Char, path: String): Entry? {
        val key = path.toByteArray(Charsets.UTF_8)
        var lo = 0
        var hi = entryCount - 1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val buf = direntBytes(entryOffset(mid))
            val c = compareKey(buf, namespace, key)
            when {
                c == 0 -> return parseEntry(mid, buf)
                c < 0 -> lo = mid + 1
                else -> hi = mid - 1
            }
        }
        return null
    }

    /** Orders a directory entry against (namespace, path): negative when the entry sorts first. */
    private fun compareKey(buf: ByteBuffer, namespace: Char, key: ByteArray): Int {
        val ns = (buf.get(3).toInt() and 0xFF) - namespace.code
        if (ns != 0) return ns
        var i = pathStart(buf)
        var k = 0
        while (true) {
            val b = buf.get(i++).toInt() and 0xFF
            if (b == 0) return if (k == key.size) 0 else -1
            if (k == key.size) return 1
            val d = b - (key[k++].toInt() and 0xFF)
            if (d != 0) return d
        }
    }

    /** Follows redirects to the entry that holds content. */
    fun resolve(entry: Entry): Entry {
        var e = entry
        repeat(MAX_REDIRECTS) {
            if (!e.isRedirect) return e
            e = entry(e.redirectIndex)
        }
        throw IllegalStateException("redirect loop at ${entry.path}")
    }

    fun mimeType(entry: Entry): String = mimeTypes.getOrElse(entry.mime) { "application/octet-stream" }

    fun isHtml(entry: Entry): Boolean = !entry.isRedirect && mimeType(entry).startsWith("text/html")

    /** Index of the first entry in [namespace] (or of the next namespace if it has none). */
    fun namespaceStart(namespace: Char): Int {
        var lo = 0
        var hi = entryCount
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            val ns = (direntBytes(entryOffset(mid)).get(3).toInt() and 0xFF).toChar()
            if (ns < namespace) lo = mid + 1 else hi = mid
        }
        return lo
    }

    private fun clusterOffset(cluster: Int): Long {
        require(cluster in 0 until clusterCount) { "cluster $cluster out of range" }
        return readFully(clusterPtrPos + 8L * cluster, 8).getLong(0)
    }

    /** Where an item's bytes sit in the file, for items stored uncompressed; null if compressed. */
    fun rawLocation(entry: Entry): Pair<Long, Long>? {
        require(!entry.isRedirect) { "${entry.path} is a redirect" }
        val base = clusterOffset(entry.cluster)
        val info = readFully(base, 1).get(0).toInt()
        if ((info and 0x0F) > COMPRESSION_NONE) return null
        val width = if (info and EXTENDED != 0) 8 else 4
        val o = readFully(base + 1 + width.toLong() * entry.blob, width * 2)
        val from = if (width == 8) o.getLong(0) else o.getInt(0).toLong() and 0xFFFFFFFFL
        val to = if (width == 8) o.getLong(8) else o.getInt(4).toLong() and 0xFFFFFFFFL
        return Pair(base + 1 + from, to - from)
    }

    /** Reads [length] bytes of the file at [pos]. For walking large uncompressed items. */
    fun readRaw(pos: Long, length: Int): ByteBuffer = readFully(pos, length)

    /** The content of an item. Follow redirects with [resolve] first. */
    fun content(entry: Entry): ByteArray {
        rawLocation(entry)?.let { (pos, size) ->
            require(size <= Int.MAX_VALUE) { "${entry.path} is too large to load" }
            return readFully(pos, size.toInt()).array()
        }
        val data = cluster(entry.cluster)
        val width = if (data.extended) 8 else 4
        val b = ByteBuffer.wrap(data.bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun offset(i: Int): Int =
            if (width == 8) b.getLong(i * 8).toInt() else b.getInt(i * 4)
        return data.bytes.copyOfRange(offset(entry.blob), offset(entry.blob + 1))
    }

    private class Cluster(val bytes: ByteArray, val extended: Boolean)

    // Recently used decompressed clusters. A page and the next few link taps often share one.
    private val clusters = object : LinkedHashMap<Int, Cluster>(8, 0.75f, true) {
        var total = 0L
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Int, Cluster>): Boolean {
            if (total <= CACHE_BYTES || size <= 1) return false
            total -= eldest.value.bytes.size
            return true
        }
    }

    private fun cluster(number: Int): Cluster {
        synchronized(clusters) { clusters[number]?.let { return it } }
        val loaded = decompress(number)
        synchronized(clusters) {
            clusters.put(number, loaded)?.let { clusters.total -= it.bytes.size }
            clusters.total += loaded.bytes.size
        }
        return loaded
    }

    /**
     * A decompressed cluster is an offset table followed by the blobs. The first offset equals the
     * table's size and the last equals the cluster's size, so the stream tells us how much to read;
     * reading exactly that much also keeps the decoder from running into the next cluster.
     */
    private fun decompress(number: Int): Cluster {
        val base = clusterOffset(number)
        val info = readFully(base, 1).get(0).toInt()
        val compression = info and 0x0F
        if (compression != COMPRESSION_ZSTD) throw UnsupportedOperationException("cluster compression type $compression")
        val width = if (info and EXTENDED != 0) 8 else 4
        ZstdInputStream(ChannelStream(base + 1)).use { z ->
            val table = readTable(z, width, number)
            val total = le(table, table.size - width, width)
            require(total in table.size..MAX_CLUSTER) { "cluster $number is too large ($total bytes)" }
            val bytes = table.copyOf(total.toInt()).also { readAll(z, it, table.size, total.toInt() - table.size) }
            return Cluster(bytes, width == 8)
        }
    }

    /** Reads a cluster's offset table from the start of its (decompressed) data. */
    private fun readTable(input: InputStream, width: Int, number: Int): ByteArray {
        val first = ByteArray(width).also { readAll(input, it, 0, width) }
        val size = le(first, 0, width)
        require(size in width..MAX_CLUSTER && size % width == 0L) { "corrupt cluster $number" }
        return first.copyOf(size.toInt()).also { readAll(input, it, width, size.toInt() - width) }
    }

    /**
     * The size of every blob in a cluster, from its offset table alone: for compressed clusters only
     * the first few kilobytes are unpacked. Used to rank articles by length when building the index.
     */
    fun blobSizes(cluster: Int): LongArray {
        val base = clusterOffset(cluster)
        val info = readFully(base, 1).get(0).toInt()
        val width = if (info and EXTENDED != 0) 8 else 4
        val table = when (info and 0x0F) {
            0, COMPRESSION_NONE -> readTable(ChannelStream(base + 1), width, cluster)
            COMPRESSION_ZSTD -> ZstdInputStream(ChannelStream(base + 1)).use { readTable(it, width, cluster) }
            else -> throw UnsupportedOperationException("cluster compression type ${info and 0x0F}")
        }
        return LongArray(table.size / width - 1) { le(table, (it + 1) * width, width) - le(table, it * width, width) }
    }

    private fun le(b: ByteArray, at: Int, width: Int): Long {
        var v = 0L
        for (i in width - 1 downTo 0) v = (v shl 8) or (b[at + i].toLong() and 0xFF)
        return v
    }

    private fun readAll(input: InputStream, into: ByteArray, offset: Int, length: Int) {
        var done = 0
        while (done < length) {
            val n = input.read(into, offset + done, length - done)
            if (n < 0) throw EOFException("cluster data ended early")
            done += n
        }
    }

    /** Sequential view of the file from a start position, for feeding the decompressor. */
    private inner class ChannelStream(private var pos: Long) : InputStream() {
        private val one = ByteArray(1)

        override fun read(): Int = if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xFF

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            val n = channel.read(ByteBuffer.wrap(b, off, len), pos)
            if (n > 0) pos += n
            return n
        }
    }

    override fun close() = channel.close()

    companion object {
        private const val MAGIC = 0x044D495A
        private const val HEADER_SIZE = 80
        private const val REDIRECT = 0xFFFF
        private const val COMPRESSION_NONE = 1 // 0 and 1 both mean "stored"
        private const val COMPRESSION_ZSTD = 5
        private const val EXTENDED = 0x10 // cluster uses 8-byte offsets
        private const val MAX_REDIRECTS = 8
        private const val MAX_DIRENT = 8192
        private const val SCAN_BATCH = 65536
        private const val SCAN_SPAN = 64L * 1024 * 1024
        private const val MAX_CLUSTER = 512L * 1024 * 1024
        private const val CACHE_BYTES = 24L * 1024 * 1024
    }
}
