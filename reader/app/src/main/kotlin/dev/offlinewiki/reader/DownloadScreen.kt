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
 * The books in the [Catalog] (each size of Wikipedia on offer), each with how much of it is here
 * and what can be done: download it, pause, carry on, open it once it has arrived, update an older
 * snapshot of it, or delete it. The download itself runs in [Downloads]; this screen looks at it
 * every couple of seconds and changes only text that has changed, which is what an e-ink screen
 * can redraw without flashing. Deleting asks first, in place, rather than in a dialog.
 *
 * [openWhenDone] says whether there is nothing to read yet: then a download that finishes while
 * the screen is up opens at once ([onReady]); otherwise it waits for Open, so as not to pull the
 * reader out of what they have open. [reading] is the name of the Wikipedia file open now, if
 * any: a book that is open offers no Open. [letGo] is asked to close any of the given files
 * before they are deleted, since a deleted file that is still open keeps its space.
 */
class DownloadScreen(
    private val activity: Activity,
    private val openWhenDone: () -> Boolean,
    private val reading: () -> String?,
    private val letGo: (names: Set<String>) -> Unit,
    private val onClose: () -> Unit,
    private val onReady: () -> Unit,
) {
    /** The parts of one book's entry that change: what is said, and up to two buttons. */
    private class Entry(val book: Catalog.Book, val state: TextView, val first: TextView, val second: TextView)

    /** What an entry says and offers at the moment. */
    private class Look(val state: String, val first: String? = null, val second: String? = null)

    private val main = Handler(Looper.getMainLooper())
    private val entries = mutableListOf<Entry>()
    private var closed = false
    private var sawRunning = false
    private var confirming: String? = null // "Delete <id>" or "Replace <id>", waiting for the second tap

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
            val entry = Entry(book, state, Ui.button(activity, "") {}, Ui.button(activity, "") {})
            entry.first.setOnClickListener { act(entry, entry.first.text.toString()) }
            entry.second.setOnClickListener { act(entry, entry.second.text.toString()) }
            body.addView(LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(entry.first)
                addView(entry.second, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    leftMargin = Ui.dp(activity, 12)
                })
            }, wrap(top = 8))
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
        // Only at the moment a download ends: what was done before (a book deleted since, say)
        // must not open anything.
        if (Downloads.running) {
            sawRunning = true
        } else if (sawRunning) {
            sawRunning = false
            if (status?.doing == "Done" && openWhenDone()) {
                main.post { if (!closed) onReady() }
                return
            }
        }
        for (entry in entries) {
            val look = look(entry.book, status)
            if (entry.state.text.toString() != look.state) entry.state.text = look.state
            show(entry.first, look.first)
            show(entry.second, look.second)
        }
    }

    private fun show(button: TextView, label: String?) {
        if (label == null) {
            button.visibility = View.GONE
        } else {
            if (button.text.toString() != label) button.text = label
            button.visibility = View.VISIBLE
        }
    }

    private fun look(book: Catalog.Book, status: Downloads.Status?): Look {
        val mine = status?.book?.id == book.id
        val snapshot = Downloads.snapshotOf(book)?.month ?: "the catalog's"
        val older = Downloads.older(book).firstOrNull()?.let { Snapshot.of(it.name)?.month }
        val have = Downloads.have(book)
        val amount = "${Downloads.gb(have)} of ${Downloads.gb(book.size)}"
        return when {
            mine && Downloads.running -> {
                val doing = status!!.doing
                Look(if (doing.endsWith("%")) doing else "$doing: ${Downloads.gb(status.done)} of ${Downloads.gb(status.total)}", "Pause")
            }
            confirming == "Delete ${book.id}" ->
                Look("Delete this Wikipedia from the device? It cannot be undone, but it can be downloaded again.", "Delete", "Keep")
            confirming == "Replace ${book.id}" && older != null ->
                Look("There is not room for both copies, so the $older one is deleted first: until the download finishes there is no copy of it to read.", "Replace", "Keep")
            Downloads.complete(book) -> {
                // Open is for one that has just arrived and is not the one open already.
                val fresh = mine && status!!.doing == "Done" && book.files.none { it.name == reading() }
                if (fresh) Look("Downloaded. It is ready to read.", "Open")
                else Look("On this device: $snapshot.", if (Downloads.running) null else "Delete")
            }
            mine && status!!.problem != null -> Look(status.problem, "Try again", if (older != null) "Delete" else null)
            Downloads.running -> Look(if (have > 0) "Paused: $amount is here." else if (older != null) "On this device: $older." else "Not on this device.")
            have > 0 -> Look("Paused: $amount is here.", "Carry on", "Delete")
            older != null -> Look(
                "On this device: $older. A newer copy, from $snapshot, can be downloaded.",
                if (Downloads.roomFor(book) || !Downloads.roomIfReplaced(book)) "Update" else "Replace",
                "Delete",
            )
            else -> Look("Not on this device.", "Download")
        }
    }

    private fun act(entry: Entry, action: String) {
        val book = entry.book
        val asked = confirming
        confirming = null
        when (action) {
            "Pause" -> Downloads.stop()
            "Open" -> onReady()
            "Keep" -> Unit
            "Delete" -> if (asked == "Delete ${book.id}") {
                val files = Downloads.filesOf(book)
                letGo(files.map { it.name }.toSet())
                Downloads.delete(book)
            } else {
                confirming = "Delete ${book.id}"
            }
            "Replace" -> if (asked == "Replace ${book.id}") {
                letGo(Downloads.older(book).map { it.name }.toSet())
                Downloads.deleteOlder(book)
                start(book)
            } else {
                confirming = "Replace ${book.id}"
            }
            else -> start(book) // Download, Update, Carry on, Try again
        }
        refresh()
    }

    private fun start(book: Catalog.Book) {
        askToNotify()
        Downloads.start(activity, book)
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
