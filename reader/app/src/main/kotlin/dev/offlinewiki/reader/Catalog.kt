package dev.offlinewiki.reader

import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * What the app can download: each Wikipedia on offer and its title index, as `./wiki.sh publish`
 * lists them in catalog.json on this repository's "downloads" release. Wikipedia itself comes from
 * Kiwix; only the index and the list are kept on GitHub.
 */
class Catalog(val books: List<Book>) {
    /** A Wikipedia and its index; [files] in the order to download them, the small index first. */
    class Book(val id: String, val title: String, val about: String, val files: List<Remote>) {
        val size: Long get() = files.sumOf { it.size }
    }

    /** One file to download, with what it must come to. */
    class Remote(val name: String, val url: String, val size: Long, val sha256: String)

    companion object {
        /** The same address as in the iOS app (Catalog.url) and in wiki.sh (PUBLISH_REPO and PUBLISH_TAG). */
        const val URL = "https://github.com/DrewWilliamsCRC/offline_wiki/releases/download/downloads/catalog.json"
        private const val FORMAT = 1

        /** Fetches the catalog. Slow, so not on the main thread. Fails with words for the reader. */
        fun fetch(): Catalog {
            val connection = Http.open(URL)
            try {
                if (connection.responseCode != 200) throw IOException("the server answered ${connection.responseCode}")
                return parse(connection.inputStream.use { it.readBytes() }.toString(Charsets.UTF_8))
            } finally {
                connection.disconnect()
            }
        }

        /**
         * Reads catalog.json. It comes over the network, so every file's name, address, size and
         * checksum is checked here: a name is a plain file name for this app, nothing that could
         * lead outside the Download folder.
         */
        fun parse(text: String): Catalog = try {
            val json = JSONObject(text)
            if (json.getInt("format") != FORMAT) throw IOException("the list of downloads is for a newer Wiki Reader: update the app")
            val books = json.getJSONArray("books")
            Catalog((0 until books.length()).map { i ->
                val book = books.getJSONObject(i)
                val files = book.getJSONArray("files")
                Book(
                    book.getString("id"),
                    book.getString("title"),
                    book.optString("about"),
                    (0 until files.length()).map { j ->
                        val file = files.getJSONObject(j)
                        Remote(file.getString("name"), file.getString("url"), file.getLong("size"), file.getString("sha256")).also {
                            if (!NAME.matches(it.name) || !it.url.startsWith("https://") || it.size <= 0 || !SHA256.matches(it.sha256)) {
                                throw IOException("the list of downloads names a file this app cannot take: ${it.name}")
                            }
                        }
                    },
                )
            })
        } catch (e: JSONException) {
            throw IOException("the list of downloads could not be read (${e.message})")
        }

        private val NAME = Regex("[A-Za-z0-9][A-Za-z0-9_.-]*\\.zim(\\.idx)?")
        private val SHA256 = Regex("[0-9a-f]{64}")
    }
}

/** HTTPS requests, following redirects: Kiwix sends each download to a mirror, GitHub to its file store. */
object Http {
    fun open(url: String, from: Long = 0): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000
            readTimeout = 60_000
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", "WikiReader (Android)")
            if (from > 0) setRequestProperty("Range", "bytes=$from-")
        }
}
