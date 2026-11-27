package dev.offlinewiki.reader

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.concurrent.thread

/**
 * The books in the [Catalog], each with how much of it is here and a button to download it, carry
 * on, pause, or open it once it has arrived. The download itself runs in [Downloads]; this screen
 * looks at it every couple of seconds and changes only text that has changed, which is what an
 * e-ink screen can redraw without flashing. With [openWhenDone], for when there is nothing to read
 * yet, a download that finishes while the screen is up opens at once ([onReady]); otherwise it
 * waits for Open, so as not to pull the reader out of what they have open. [reading] is the name
 * of the Wikipedia file open now, if any: a book that is open offers no Open.
 */
class DownloadScreen(
    private val activity: Activity,
    private val openWhenDone: Boolean,
    private val reading: String?,
    private val onClose: () -> Unit,
    private val onReady: () -> Unit,
) {
    /** The parts of one book's entry that change. */
    private class Entry(val book: Catalog.Book, val state: TextView, val button: TextView)

    private val main = Handler(Looper.getMainLooper())
    private val entries = mutableListOf<Entry>()
    private var closed = false
    private var sawRunning = false

    private val body = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(Ui.dp(activity, 16), Ui.dp(activity, 8), Ui.dp(activity, 16), Ui.dp(activity, 16))
    }

    val view: LinearLayout = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(Color.WHITE)
        isClickable = true // nothing beneath it takes a tap
        addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(Ui.dp(activity, 8), Ui.dp(activity, 8), Ui.dp(activity, 8), Ui.dp(activity, 8))
            addView(Ui.button(activity, "Back") { onClose() })
            addView(text("Downloads", 22f, bold = true).apply { setPadding(Ui.dp(activity, 16), 0, 0, 0) })
        })
        addView(Ui.rule(activity), ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(activity, 1))
        addView(ScrollView(activity).apply {
            overScrollMode = View.OVER_SCROLL_NEVER
            isVerticalFadingEdgeEnabled = false
            addView(body)
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
    }

    init {
        load()
        tick()
    }

    /** Stops looking at the download; for when the screen goes. The download carries on. */
    fun close() {
        closed = true
        main.removeCallbacksAndMessages(null)
    }

    private fun load() {
        body.removeAllViews()
        entries.clear()
        body.addView(text("Looking for what can be downloaded…", 18f))
        thread(name = "catalog") {
            val result = runCatching { Catalog.fetch() }
            main.post { if (!closed) show(result) }
        }
    }

    private fun show(result: Result<Catalog>) {
        body.removeAllViews()
        val catalog = result.getOrElse { e ->
            body.addView(text("The list of downloads could not be fetched: ${e.message ?: e}.", 18f))
            body.addView(Ui.button(activity, "Try again", onClick = ::load), wrap(top = 16))
            return
        }
        body.addView(text(
            "Each one is Wikipedia, from Kiwix, and the index that makes its titles searchable. " +
                "Downloads use Wi-Fi only, and carry on with the app closed.",
            16f,
        ), wrap(bottom = 8))
        for (book in catalog.books) {
            body.addView(Ui.rule(activity), LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(activity, 1)).apply {
                topMargin = Ui.dp(activity, 12)
            })
            body.addView(text(book.title, 20f, bold = true), wrap(top = 12))
            body.addView(text("${book.about} ${Downloads.gb(book.size)}", 16f), wrap(top = 4))
            val state = text("", 16f)
            body.addView(state, wrap(top = 4))
            val entry = Entry(book, state, Ui.button(activity, "") {})
            entry.button.setOnClickListener { act(entry) }
            body.addView(entry.button, wrap(top = 8))
            entries += entry
        }
        refresh()
    }

    private fun tick() {
        refresh()
        main.postDelayed(::tick, 2_000)
    }

    private fun refresh() {
        val status = Downloads.status
        if (Downloads.running) sawRunning = true
        if (openWhenDone && sawRunning && !Downloads.running && status?.doing == "Done") {
            main.post { if (!closed) onReady() }
            return
        }
        for (entry in entries) {
            val book = entry.book
            val mine = status?.book?.id == book.id
            val (state, button) = when {
                mine && Downloads.running -> {
                    val doing = status!!.doing
                    val amount = if (doing.endsWith("%")) "" else ": ${Downloads.gb(status.done)} of ${Downloads.gb(status.total)}"
                    "$doing$amount" to "Pause"
                }
                Downloads.complete(book) -> {
                    // Open is for one that has just arrived and is not the one open already.
                    val fresh = mine && status!!.doing == "Done" && book.files.none { it.name == reading }
                    (if (fresh) "Downloaded. It is ready to read." else "On this device.") to (if (fresh) "Open" else null)
                }
                mine && status!!.problem != null -> status.problem to "Try again"
                Downloads.running -> waiting(book) to null // one download at a time
                Downloads.have(book) > 0 -> "Paused: ${Downloads.gb(Downloads.have(book))} of ${Downloads.gb(book.size)} is here." to "Carry on"
                else -> "Not on this device." to "Download"
            }
            if (entry.state.text.toString() != state) entry.state.text = state
            if (button == null) {
                entry.button.visibility = View.GONE
            } else {
                if (entry.button.text.toString() != button) entry.button.text = button
                entry.button.visibility = View.VISIBLE
            }
        }
    }

    private fun waiting(book: Catalog.Book): String {
        val have = Downloads.have(book)
        return if (have > 0) "Paused: ${Downloads.gb(have)} of ${Downloads.gb(book.size)} is here." else "Not on this device."
    }

    private fun act(entry: Entry) {
        when (entry.button.text.toString()) {
            "Pause" -> Downloads.stop()
            "Open" -> onReady()
            else -> {
                askToNotify()
                Downloads.start(activity, entry.book)
            }
        }
        refresh()
    }

    /** The download's progress is a notification; Android 13 and later ask before showing one. */
    private fun askToNotify() {
        if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    private fun text(value: String, size: Float, bold: Boolean = false) = TextView(activity).apply {
        text = value
        textSize = size
        setTextColor(Color.BLACK)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun wrap(top: Int = 0, bottom: Int = 0) =
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = Ui.dp(activity, top)
            bottomMargin = Ui.dp(activity, bottom)
        }
}
