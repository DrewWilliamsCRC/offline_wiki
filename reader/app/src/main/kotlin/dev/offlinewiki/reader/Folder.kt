package dev.offlinewiki.reader

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.nio.channels.FileChannel

/**
 * The folder the reader chose for Wikipedia, through Android's folder picker: the one place the app
 * reads and writes. It asks for no wider access to storage ("all files access" is for file managers
 * and the like on Google Play). Android does not let an app be given the Download folder itself,
 * so this is a folder of its own, "Wikipedia" at the top of the device's storage by default, which
 * is where `./wiki.sh push` copies to.
 *
 * Its files are reached by name, as documents of the folder: listed, opened as file descriptors,
 * created, appended to, renamed and deleted. A listing is kept for a moment, since the screens ask
 * about the same few files many times over; anything that changes the folder forgets it.
 */
class Folder private constructor(private val context: Context, private val tree: Uri) {
    /** A file in the folder. [modified] is in milliseconds. */
    class Doc(val name: String, val uri: Uri, val size: Long, val modified: Long)

    private val resolver get() = context.contentResolver
    private val root: Uri = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
    private var listed: List<Doc>? = null
    private var listedAt = 0L

    /** The folder's name, for messages. */
    val name: String = DocumentsContract.getTreeDocumentId(tree).substringAfterLast(':').substringAfterLast('/').ifEmpty { "the folder" }

    /** The files in it, not its sub-folders. */
    @Synchronized
    fun list(): List<Doc> {
        val now = System.currentTimeMillis()
        listed?.let { if (now - listedAt < KEEP_MILLIS) return it }
        val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_MIME_TYPE)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(root))
        val docs = mutableListOf<Doc>()
        resolver.query(children, columns, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(4) == Document.MIME_TYPE_DIR) continue
                docs += Doc(c.getString(1), DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0)), c.getLong(2), c.getLong(3))
            }
        } ?: throw IOException("$name cannot be read. Choose the folder again.")
        listed = docs
        listedAt = now
        return docs
    }

    /** Lists afresh next time: for sizes that must be exact, such as where to carry a download on from. */
    @Synchronized
    fun forget() {
        listed = null
    }

    private fun changed() = forget()

    fun find(name: String): Doc? = list().firstOrNull { it.name == name }

    /** A file's size, or 0 if it is not there, as File.length gives. */
    fun size(name: String): Long = find(name)?.size ?: 0

    fun exists(name: String): Boolean = find(name) != null

    /** Opens a file for reading, as a channel that closes the file descriptor with it. */
    fun channel(doc: Doc): FileChannel = ParcelFileDescriptor.AutoCloseInputStream(open(doc.uri, "r")).channel

    fun input(name: String): FileInputStream =
        ParcelFileDescriptor.AutoCloseInputStream(open((find(name) ?: throw FileNotFoundException(name)).uri, "r"))

    /** Opens a file for writing at its end, creating it if need be; [fresh] empties it first. */
    fun output(name: String, fresh: Boolean = false): FileOutputStream {
        val uri = find(name)?.uri ?: create(name)
        changed()
        return ParcelFileDescriptor.AutoCloseOutputStream(open(uri, if (fresh) "wt" else "wa"))
    }

    /** Makes sure what was written to a file is on the disk, not only on its way there. */
    fun sync(name: String) {
        val uri = (find(name) ?: return).uri
        open(uri, "rw").use { it.fileDescriptor.sync() }
    }

    /** Renames [from] to [to], replacing any [to] there is. */
    fun rename(from: String, to: String) {
        val doc = find(from) ?: throw FileNotFoundException(from)
        delete(to)
        val renamed = DocumentsContract.renameDocument(resolver, doc.uri, to)
        changed()
        // A provider may keep the name it was asked for only nearly ("name (1)"): then it is not usable.
        if (renamed == null || find(to) == null) throw IOException("$from could not be renamed to $to")
    }

    fun delete(name: String) {
        val doc = find(name) ?: return
        DocumentsContract.deleteDocument(resolver, doc.uri)
        changed()
    }

    /** Bytes free where the folder is. */
    fun free(): Long {
        // The device's own storage is "primary:<path>"; a memory card is "<id>:<path>".
        val id = DocumentsContract.getTreeDocumentId(tree)
        val volume = id.substringBefore(':')
        val base = if (volume == "primary") Environment.getExternalStorageDirectory() else File("/storage/$volume")
        return File(base, id.substringAfter(':', "")).usableSpace.takeIf { it > 0 } ?: base.usableSpace
    }

    private fun create(name: String): Uri {
        // A type with no extension of its own, so that the provider keeps the name as it is.
        val uri = DocumentsContract.createDocument(resolver, root, "application/octet-stream", name)
            ?: throw IOException("$name could not be made in ${this.name}")
        changed()
        return uri
    }

    private fun open(uri: Uri, mode: String): ParcelFileDescriptor =
        resolver.openFileDescriptor(uri, mode) ?: throw FileNotFoundException(uri.toString())

    companion object {
        private const val KEEP_MILLIS = 1_000L
        private const val PREFS = "folder"
        private const val KEY = "tree"

        @Volatile
        private var cached: Folder? = null

        /** The folder chosen before, if the app may still use it; null if none is. */
        fun chosen(context: Context): Folder? {
            val uri = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)?.let(Uri::parse) ?: return null
            cached?.let { if (it.tree == uri) return it }
            val allowed = context.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission }
            if (!allowed) return null
            return Folder(context.applicationContext, uri).also { cached = it }
        }

        /** Keeps what the folder picker returned, with lasting permission to read and write there. */
        fun choose(context: Context, uri: Uri) {
            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            context.contentResolver.takePersistableUriPermission(uri, flags)
            // Only one folder is kept: let go of any other.
            for (held in context.contentResolver.persistedUriPermissions) {
                if (held.uri != uri) context.contentResolver.releasePersistableUriPermission(held.uri, flags)
            }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, uri.toString()).apply()
            cached = null
        }

        /** The folder picker, opening at the top of the device's storage, where "Wikipedia" goes. */
        fun picker(): Intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            putExtra(DocumentsContract.EXTRA_INITIAL_URI, DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:"))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
    }
}
