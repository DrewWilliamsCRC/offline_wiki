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

/** The search box and its results; with an empty box it lists recently read articles instead. */
class SearchScreen(
    private val activity: Activity,
    private val library: Library,
    private val history: History,
    private val open: (Library.Article) -> Unit,
) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile
    private var generation = 0 // bumped on every keystroke so that slow, stale searches are dropped
    private var rows: List<Library.Article> = emptyList()

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
            val article = rows[position]
            (row.getChildAt(0) as TextView).text = article.title
            (row.getChildAt(1) as TextView).apply {
                text = article.foundAs?.let { "also: $it" }
                visibility = if (article.foundAs == null) View.GONE else View.VISIBLE
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
                Ui.button(activity, "Random") { library.randomArticle()?.let(::choose) },
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

    private fun choose(article: Library.Article) {
        keyboard().hideSoftInputFromWindow(input.windowToken, 0)
        open(article)
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
            val recent = history.list()
            display(recent, when {
                !library.hasIndex -> "No search index found next to ${library.file.name}. Build it on the Mac and copy it over."
                recent.isEmpty() -> "Type a title to search."
                else -> "Recently read"
            })
            return
        }
        worker.execute {
            val found = runCatching { library.search(query, LIMIT) { mine != generation } }.getOrDefault(emptyList())
            main.post { if (mine == generation) display(found, if (found.isEmpty()) "No titles match." else null) }
        }
    }

    private fun display(articles: List<Library.Article>, message: String?) {
        rows = articles
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
