package dev.offlinewiki.reader

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** The articles read most recently, newest first, kept across restarts. */
class History(context: Context) {
    private val prefs = context.getSharedPreferences("history", Context.MODE_PRIVATE)

    fun list(): List<Library.Article> = runCatching {
        val array = JSONArray(prefs.getString(KEY, "[]"))
        (0 until array.length()).map { array.getJSONObject(it) }.map { Library.Article(it.getString("t"), it.getString("p")) }
    }.getOrDefault(emptyList())

    fun add(path: String, title: String) {
        val kept = list().filter { it.path != path }.take(MAX - 1)
        val array = JSONArray()
        for (a in listOf(Library.Article(title, path)) + kept) array.put(JSONObject().put("t", a.title).put("p", a.path))
        prefs.edit().putString(KEY, array.toString()).apply()
    }

    private companion object {
        const val KEY = "recent"
        const val MAX = 40
    }
}
