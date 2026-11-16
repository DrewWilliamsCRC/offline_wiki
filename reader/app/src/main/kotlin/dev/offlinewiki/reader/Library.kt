package dev.offlinewiki.reader

import android.content.Context
import android.os.Environment
import wikireader.core.TitleIndex
import wikireader.core.ZimFile
import java.io.File
import java.util.Random

/** The opened Wikipedia file and, if it is there, the title index built for it. */
class Library private constructor(val file: File, private val zim: ZimFile, private val index: TitleIndex?) {
    val hasIndex: Boolean get() = index != null
    private val random = Random()

    /** An article the reader can open. [foundAs] is the other name that matched, when it was not the title. */
    class Article(val title: String, val path: String, val foundAs: String? = null)

    class Item(val mimeType: String, val bytes: ByteArray)

    /** [cancelled] lets a search that the next keystroke has made pointless stop early. */
    fun search(query: String, limit: Int, cancelled: () -> Boolean): List<Article> =
        index?.search(query, limit, cancelled)?.map(::article) ?: emptyList()

    private fun article(hit: TitleIndex.Hit): Article {
        val target = zim.entry(hit.targetIndex)
        if (hit.entryIndex == hit.targetIndex) return Article(target.title, target.path)
        return Article(target.title, target.path, foundAs = zim.entry(hit.entryIndex).title)
    }

    fun randomArticle(): Article? = index?.randomArticle(random)?.let(::article)

    fun mainPage(): Article? = zim.find('W', "mainPage")?.let(zim::resolve)?.let { Article(it.title, it.path) }

    /** Where an article path really leads once redirects are followed; null if this copy lacks it. */
    fun resolvePath(path: String): String? = zim.find('C', path)?.let(zim::resolve)?.path

    /** An article or one of its stylesheets, by path. */
    fun item(path: String): Item? {
        val entry = zim.find('C', path)?.let(zim::resolve) ?: return null
        return Item(zim.mimeType(entry), zim.content(entry))
    }

    companion object {
        @Volatile
        private var current: Library? = null

        /** Opens the Wikipedia file on this device, or returns null if there is none. */
        fun open(context: Context): Library? {
            current?.let { return it }
            val file = findZim(context) ?: return null
            val zim = ZimFile(file)
            val indexFile = TitleIndex.fileFor(file)
            val index = if (!indexFile.isFile) null else runCatching { TitleIndex(indexFile) }.getOrNull()
                ?.takeIf { it.zimUuid.contentEquals(zim.uuid) } // an index built for another file would mislead
            return Library(file, zim, index).also { current = it }
        }

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
