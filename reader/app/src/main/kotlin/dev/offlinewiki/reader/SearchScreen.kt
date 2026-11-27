package dev.offlinewiki.reader

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.BaseAdapter
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import java.util.concurrent.Executors

/**
 * The search box and its results; with an empty box it lists recently read articles instead, each
 * with how far it was read. [open] is given an article's path and how far down it to start: where
 * the reader left off for a recently read one, the top for a search result. The last line of
 * that list leads to the downloads screen, [onDownloads].
 */
class SearchScreen(
    private val activity: Activity,
    private val library: Library,
    private val history: History,
    private val onDownloads: () -> Unit,
    private val open: (path: String, position: Float) -> Unit,
) {
    /**
     * One line of the list. [note] is the smaller text under the title, if any. A line with an
     * [action] does that instead of opening an article.
     */
    private class Row(
        val title: String,
        val path: String,
        val note: String?,
        val position: Float = 0f,
        val action: (() -> Unit)? = null,
    )

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile
    private var generation = 0 // bumped on every keystroke so that slow, stale searches are dropped
    private var rows: List<Row> = emptyList()

    private val input = EditText(activity).apply {
        hint = "Search Wikipedia"
        textSize = 22f
        setTextColor(Color.BLACK)
        setHintTextColor(Color.DKGRAY)
        setSingleLine()
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        imeOptions = EditorInfo.IME_ACTION_SEARCH or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        background = Ui.border(activity)
        setPadding(Ui.dp(activity, 12), Ui.dp(activity, 10), Ui.dp(activity, 12), Ui.dp(activity, 10))
    }

    private val note = TextView(activity).apply {
        textSize = 15f
        setTextColor(Color.BLACK)
        setPadding(Ui.dp(activity, 14), Ui.dp(activity, 8), Ui.dp(activity, 14), Ui.dp(activity, 8))
    }

    private val adapter = object : BaseAdapter() {
        override fun getCount(): Int = rows.size
        override fun getItem(position: Int): Any = rows[position]
        override fun getItemId(position: Int): Long = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val row = (convertView as? LinearLayout) ?: newRow()
            val item = rows[position]
            (row.getChildAt(0) as TextView).text = item.title
            (row.getChildAt(1) as TextView).apply {
                text = item.note
                visibility = if (item.note == null) View.GONE else View.VISIBLE
            }
            return row
        }

        private fun newRow() = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            minimumHeight = Ui.dp(activity, 56)
            gravity = Gravity.CENTER_VERTICAL
            setPadding(Ui.dp(activity, 14), Ui.dp(activity, 8), Ui.dp(activity, 14), Ui.dp(activity, 8))
            addView(TextView(activity).apply {
                textSize = 20f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(Color.BLACK)
            })
            addView(TextView(activity).apply {
                textSize = 15f
                setTextColor(Color.BLACK)
            })
        }
    }

    private val list = ListView(activity).apply {
        adapter = this@SearchScreen.adapter
        divider = ColorDrawable(Color.BLACK)
        dividerHeight = Ui.dp(activity, 1)
        selector = ColorDrawable(Color.TRANSPARENT)
        overScrollMode = View.OVER_SCROLL_NEVER
        isVerticalFadingEdgeEnabled = false
        setOnItemClickListener { _, _, position, _ -> rows.getOrNull(position)?.let(::choose) }
    }

    val view: LinearLayout = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(Color.WHITE)
        val top = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(Ui.dp(activity, 8), Ui.dp(activity, 8), Ui.dp(activity, 8), Ui.dp(activity, 8))
            addView(input, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(
                Ui.button(activity, "Random") { runCatching { library.randomArticle() }.getOrNull()?.let { choose(row(it)) } },
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT).apply {
                    leftMargin = Ui.dp(activity, 8)
                },
            )
        }
        addView(top)
        addView(note)
        addView(Ui.rule(activity), ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(activity, 1))
        addView(list, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
    }

    init {
        input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) = schedule()
        })
        input.setOnEditorActionListener { _, _, _ ->
            rows.firstOrNull()?.takeIf { input.text.isNotBlank() }?.let(::choose)
            true
        }
        refresh()
    }

    /** Called when the screen comes to the front. */
    fun show() {
        input.requestFocus()
        input.selectAll()
        refresh()
        main.postDelayed({ keyboard().showSoftInput(input, 0) }, 100)
    }

    private fun keyboard() = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager

    /**
     * Stops the search thread once it has finished what it is doing; for when the screen is being
     * replaced. It is not interrupted: interrupting a thread that is reading a file closes the file
     * for everyone else too.
     */
    fun close() {
        generation++ // which makes a search that is under way give up at its next step
        worker.shutdown()
    }

    private fun choose(row: Row) {
        keyboard().hideSoftInputFromWindow(input.windowToken, 0)
        row.action?.invoke() ?: open(row.path, row.position)
    }

    /** The way to the downloads screen, saying how a download is getting on if one is. */
    private fun downloadsRow(): Row {
        val status = Downloads.status
        val note = when {
            status == null || status.doing == "Done" -> "Wikipedia and its index, over Wi-Fi"
            Downloads.running -> "${status.book.title}: ${Downloads.gb(status.done)} of ${Downloads.gb(status.total)}"
            status.problem != null -> "Stopped: ${status.problem}"
            else -> "Paused: ${status.book.title}"
        }
        return Row("Downloads", "", note, action = onDownloads)
    }

    private fun row(article: Library.Article) = Row(article.title, article.path, article.foundAs?.let { "also: $it" })

    /** A recently read article, which opens where the reader left it and says how far that is. */
    private fun row(entry: History.Entry): Row {
        val percent = (entry.position * 100).toInt()
        return Row(entry.title, entry.path, if (percent >= 1) "$percent% read" else null, entry.position)
    }

    private fun schedule() {
        generation++
        main.removeCallbacksAndMessages(SEARCH)
        // A short pause so that fast typing runs one search, not one per letter.
        main.postAtTime(::refresh, SEARCH, android.os.SystemClock.uptimeMillis() + 120)
    }

    private fun refresh() {
        val query = input.text.toString().trim()
        val mine = ++generation
        if (query.isEmpty()) {
            val recent = history.list().map(::row)
            display(recent + downloadsRow(), library.indexProblem ?: if (recent.isEmpty()) "Type a title to search." else "Recently read")
            return
        }
        worker.execute {
            val found = runCatching { library.search(query, LIMIT) { mine != generation } }.getOrDefault(emptyList()).map(::row)
            main.post { if (mine == generation) display(found, if (found.isEmpty()) library.indexProblem ?: "No titles match." else null) }
        }
    }

    private fun display(found: List<Row>, message: String?) {
        rows = found
        adapter.notifyDataSetChanged()
        list.setSelection(0)
        note.text = message
        note.visibility = if (message == null) View.GONE else View.VISIBLE
    }

    private companion object {
        const val LIMIT = 40
        val SEARCH = Any() // token for pending search callbacks
    }
}
