package dev.offlinewiki.reader

import android.content.Context
import android.os.Environment
import wikireader.core.TitleIndex
import wikireader.core.ZimFile
import java.io.File
import java.nio.channels.ClosedChannelException
import java.util.Random

/**
 * The Wikipedia file on this device and, if it can be used, the title index built for it.
 *
 * The files are kept open only while the app is on screen. An open file keeps its space on the
 * disk even after it is deleted, so a reader that held on to Wikipedia in the background would
 * stop `wiki.sh update` from replacing it: the old snapshot would be gone from the folder with its
 * 53 GB still taken. [release] lets go when the app leaves the screen and [hold] takes hold again
 * when it returns; anything read in between opens the files for just that read.
 */
class Library private constructor(val file: File, private val stamp: String) {
    private val random = Random()
    private val gate = Any()
    private var files: Files? = null // guarded by gate, like the two below
    private var readers = 0          // reads in progress
    private var holds = 0            // screens that want the files kept open between reads

    /** Why titles cannot be searched, in words for the reader; null when they can. */
    @Volatile
    var indexProblem: String? = null
        private set

    /** An article the reader can open. [foundAs] is the other name that matched, when it was not the title. */
    class Article(val title: String, val path: String, val foundAs: String? = null)

    class Item(val mimeType: String, val bytes: ByteArray)

    private class Files(val zim: ZimFile, val index: TitleIndex?, val indexProblem: String?) {
        fun close() {
            runCatching { zim.close() }
            runCatching { index?.close() }
        }
    }

    /** Runs [block] with the files open, opening them first if they are not. */
    private inline fun <T> read(block: (Files) -> T): T {
        val open = synchronized(gate) {
            val f = files ?: openFiles(file).also {
                files = it
                indexProblem = it.indexProblem
            }
            readers++
            f
        }
        try {
            return block(open)
        } catch (e: ClosedChannelException) {
            // Something closed the file under this read. Forget it, so that the next read opens it afresh.
            synchronized(gate) { if (files === open) close() }
            throw e
        } finally {
            synchronized(gate) { if (--readers == 0 && holds == 0) close() }
        }
    }

    private fun close() {
        files?.close()
        files = null
    }

    /** Keeps the files open between reads from now on. Each call is undone by one [release]. */
    fun hold() {
        synchronized(gate) { holds++ }
    }

    /** Closes the files as soon as nothing is reading them, unless another [hold] is in force. */
    fun release() {
        synchronized(gate) {
            if (holds > 0) holds--
            if (holds == 0 && readers == 0) close()
        }
    }

    /** Lets go for good, whoever holds it: the files have changed and another library takes over. */
    private fun retire() {
        synchronized(gate) {
            holds = 0
            if (readers == 0) close()
        }
    }

    /** [cancelled] lets a search that the next keystroke has made pointless stop early. */
    fun search(query: String, limit: Int, cancelled: () -> Boolean): List<Article> = read { f ->
        f.index?.search(query, limit, cancelled)?.map { article(f.zim, it) } ?: emptyList()
    }

    private fun article(zim: ZimFile, hit: TitleIndex.Hit): Article {
        val target = zim.entry(hit.targetIndex)
        if (hit.entryIndex == hit.targetIndex) return Article(target.title, target.path)
        return Article(target.title, target.path, foundAs = zim.entry(hit.entryIndex).title)
    }

    fun randomArticle(): Article? = read { f -> f.index?.randomArticle(random)?.let { article(f.zim, it) } }

    /** Where an article path really leads once redirects are followed; null if this copy lacks it. */
    fun resolvePath(path: String): String? = read { f -> f.zim.find('C', path)?.let(f.zim::resolve)?.path }

    /** An article or one of its stylesheets, by path. */
    fun item(path: String): Item? = read { f ->
        val entry = f.zim.find('C', path)?.let(f.zim::resolve) ?: return@read null
        Item(f.zim.mimeType(entry), f.zim.content(entry))
    }

    companion object {
        @Volatile
        private var current: Library? = null

        /**
         * The Wikipedia file on this device, opened and held; null if there is none. While the
         * files there are the ones it was last opened for, this is the same library as before.
         */
        fun open(context: Context): Library? {
            val file = findZim(context)
            val stamp = file?.let(::stampOf)
            current?.let {
                if (it.stamp == stamp) return it.also(Library::hold)
                it.retire()
            }
            current = null
            if (file == null || stamp == null) return null
            val library = Library(file, stamp)
            library.hold()
            library.read { } // opened here, so that a file that cannot be opened is reported here
            return library.also { current = it }
        }

        /**
         * Whether the files on this device are no longer the ones [open] last found: a newer
         * snapshot or its index was copied over, or Wikipedia was removed.
         */
        fun changed(context: Context): Boolean = current?.let { it.stamp != findZim(context)?.let(::stampOf) } ?: false

        private fun openFiles(file: File): Files {
            val zim = ZimFile(file)
            val indexFile = TitleIndex.fileFor(file)
            if (!indexFile.isFile) {
                return Files(zim, null, "No search index found next to ${file.name}. Build it on the Mac (./wiki.sh index) and copy it over.")
            }
            val index = try {
                TitleIndex(indexFile)
            } catch (e: Exception) {
                return Files(zim, null, "Titles cannot be searched: ${e.message ?: e}.")
            }
            if (!index.zimUuid.contentEquals(zim.uuid)) { // an index built for another file would mislead
                index.close()
                return Files(zim, null, "Titles cannot be searched: ${indexFile.name} was built for a different Wikipedia file. Build it again on the Mac (./wiki.sh index) and copy it over.")
            }
            return Files(zim, index, null)
        }

        /** Tells one state of the files from another: which file, and the size and date of it and its index. */
        private fun stampOf(zim: File): String =
            listOf(zim, TitleIndex.fileFor(zim)).joinToString("|") { "${it.path}:${it.length()}:${it.lastModified()}" }

        private fun findZim(context: Context): File? {
            val shared = Environment.getExternalStorageDirectory()
            val folders = listOfNotNull(File(shared, "Download"), File(shared, "Documents"), shared, context.getExternalFilesDir(null))
            val zims = folders.flatMap { it.listFiles { f -> f.isFile && f.name.endsWith(".zim") }?.toList() ?: emptyList() }
            // Prefer a file that has its index; among those, the biggest (the fullest Wikipedia).
            return zims.sortedWith(compareByDescending<File> { TitleIndex.fileFor(it).isFile }.thenByDescending { it.length() })
                .firstOrNull()
        }
    }
}
