package dev.offlinewiki.reader

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * The articles read most recently, newest first, with how far down each one the reader was, and
 * whether an article was on screen when the app was last seen. Kept across restarts, so the app
 * can open where it was left. Used from the main thread only.
 */
class History(context: Context) {
    /** [position] is how far the article was read: 0 at its top, 1 at its end. */
    class Entry(val title: String, val path: String, val position: Float)

    private val prefs = context.getSharedPreferences("history", Context.MODE_PRIVATE)
    private val entries = ArrayList<Entry>()
    private var unsaved = false

    init {
        runCatching {
            val array = JSONArray(prefs.getString(KEY, "[]"))
            for (i in 0 until array.length()) {
                val o = array.getJSONObject(i)
                entries += Entry(o.getString("t"), o.getString("p"), o.optDouble("y", 0.0).toFloat().coerceIn(0f, 1f))
            }
        }
    }

    fun list(): List<Entry> = ArrayList(entries)

    /** Puts an article at the top of the list. One that was there keeps how far it was read. */
    fun add(path: String, title: String) {
        val first = entries.firstOrNull()
        if (first != null && first.path == path && first.title == title) return
        val position = entries.firstOrNull { it.path == path }?.position ?: 0f
        entries.removeAll { it.path == path }
        entries.add(0, Entry(title, path, position))
        while (entries.size > MAX) entries.removeAt(entries.size - 1)
        unsaved = true
        save()
    }

    /** Notes how far an article in the list has been read. Kept at the next [save]. */
    fun setPosition(path: String, position: Float) {
        val i = entries.indexOfFirst { it.path == path }
        if (i < 0 || entries[i].position == position) return
        entries[i] = Entry(entries[i].title, path, position)
        unsaved = true
    }

    fun save() {
        if (!unsaved) return
        unsaved = false
        val array = JSONArray()
        for (e in entries) array.put(JSONObject().put("t", e.title).put("p", e.path).put("y", e.position.toDouble()))
        prefs.edit().putString(KEY, array.toString()).apply()
    }

    /** Whether an article, rather than the search screen, was showing when the app was last seen. */
    var reading: Boolean
        get() = prefs.getBoolean(READING, false)
        set(value) {
            if (value != reading) prefs.edit().putBoolean(READING, value).apply()
        }

    private companion object {
        const val KEY = "recent"
        const val READING = "reading"
        const val MAX = 40
    }
}
