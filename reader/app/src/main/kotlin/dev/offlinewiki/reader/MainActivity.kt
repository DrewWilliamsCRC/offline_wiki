package dev.offlinewiki.reader

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/** The app's only window: a search screen and a reader screen, one shown at a time. */
class MainActivity : Activity() {
    private lateinit var root: FrameLayout
    private var search: SearchScreen? = null
    private var reader: ReaderScreen? = null
    private var library: Library? = null
    private var holding = false // whether this window is keeping the library's files open
    private var history: History? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        root = FrameLayout(this).apply { setBackgroundColor(Color.WHITE) }
        setContentView(root)
    }

    override fun onStart() {
        super.onStart()
        hold()
    }

    override fun onResume() {
        super.onResume()
        // Checked on every return to the app: the user may just have granted access in Settings,
        // or copied a newer Wikipedia or its index over.
        if (search == null || Library.changed(this)) start()
    }

    override fun onPause() {
        super.onPause()
        reader?.pause()
    }

    /**
     * Out of sight, the app lets go of the Wikipedia file, so that it can be replaced over USB:
     * a deleted file that is still open goes on taking up its space.
     */
    override fun onStop() {
        super.onStop()
        release()
        // The index is memory-mapped, and a mapping is only undone once its buffer is collected.
        Runtime.getRuntime().gc()
    }

    override fun onDestroy() {
        leave()
        super.onDestroy()
    }

    private fun hold() {
        if (!holding) library?.let {
            it.hold()
            holding = true
        }
    }

    private fun release() {
        if (holding) library?.release()
        holding = false
    }

    private fun start() {
        leave()
        if (!Environment.isExternalStorageManager()) {
            message(
                "Wiki Reader needs permission to read the Wikipedia file in your Download folder.\n\n" +
                    "Tap the button, switch on \"Allow access to manage all files\", then come back.",
                "Allow file access",
                ::askForFileAccess,
            )
            return
        }
        val library = try {
            Library.open(this)
        } catch (e: Exception) {
            message("The Wikipedia file could not be opened.\n\n${e.message ?: e}", "Try again", ::start)
            return
        }
        if (library == null) {
            message("No Wikipedia file found.\n\nCopy a .zim file and its .idx index into the Download folder.", "Look again", ::start)
            return
        }
        val history = History(this)
        val readerScreen = ReaderScreen(this, library, history, onBack = ::goBack, onSearch = ::showSearch)
        val searchScreen = SearchScreen(this, library, history) { path, position ->
            readerScreen.open(path, position)
            show(readerScreen.view)
        }
        this.library = library
        holding = true // Library.open hands it over held
        this.history = history
        reader = readerScreen
        search = searchScreen
        root.addView(readerScreen.view, MATCH, MATCH)
        root.addView(searchScreen.view, MATCH, MATCH)
        // Open where the app was left: on the article being read, as far down it as the reader was.
        val last = history.list().firstOrNull()
        if (history.reading && last != null) {
            readerScreen.open(last.path, last.position)
            show(readerScreen.view)
        } else {
            showSearch()
        }
    }

    /** Lets go of the screens and the library, before others replace them or a notice does. */
    private fun leave() {
        root.removeAllViews() // a web view has to be out of the window before it is freed
        search?.close()
        reader?.close()
        release()
        search = null
        reader = null
        library = null
        history = null
    }

    private fun askForFileAccess() {
        try {
            startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
        } catch (e: ActivityNotFoundException) {
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    private fun showSearch() {
        val screen = search ?: return
        show(screen.view)
        screen.show()
    }

    private fun show(view: View) {
        search?.view?.visibility = if (view === search?.view) View.VISIBLE else View.GONE
        reader?.view?.visibility = if (view === reader?.view) View.VISIBLE else View.GONE
        history?.reading = view === reader?.view
    }

    private fun readerShowing(): Boolean = reader?.view?.visibility == View.VISIBLE

    /** Back: previous article, then the search screen; from search, back to the article being read. */
    private fun goBack() {
        val readerScreen = reader
        when {
            readerScreen == null -> finish()
            readerShowing() -> if (!readerScreen.back()) showSearch()
            readerScreen.hasPage -> show(readerScreen.view)
            else -> finish()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() = goBack()

    /** Page-turn buttons, volume keys and keyboard arrows all turn the page while reading. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val direction = when (event.keyCode) {
            KeyEvent.KEYCODE_PAGE_DOWN, KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_DPAD_RIGHT -> 1
            KeyEvent.KEYCODE_PAGE_UP, KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_LEFT -> -1
            else -> 0
        }
        if (direction == 0 || !readerShowing()) return super.dispatchKeyEvent(event)
        if (event.action == KeyEvent.ACTION_DOWN) reader?.turnPage(direction)
        return true
    }

    /** A full-screen notice with one button, for the states where there is nothing to read yet. */
    private fun message(text: String, action: String, onAction: () -> Unit) {
        leave()
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(Ui.dp(context, 28), Ui.dp(context, 28), Ui.dp(context, 28), Ui.dp(context, 28))
            addView(TextView(context).apply {
                this.text = text
                textSize = 20f
                setTextColor(Color.BLACK)
            })
            addView(
                Ui.button(context, action, onClick = onAction),
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    topMargin = Ui.dp(context, 24)
                },
            )
        }, MATCH, MATCH)
    }

    private companion object {
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    }
}
