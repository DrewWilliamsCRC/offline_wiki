package dev.offlinewiki.reader

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import wikireader.core.ArticleSections
import java.io.ByteArrayInputStream

/**
 * Shows one article in a WebView fed straight from the Wikipedia file, with controls suited to
 * e-ink: whole-page turns instead of smooth scrolling, text size buttons, a list of the article's
 * sections to jump to, and no animation.
 */
class ReaderScreen(
    private val activity: Activity,
    private val library: Library,
    private val history: History,
    private val onBack: () -> Unit,
    private val onSearch: () -> Unit,
) {
    private val prefs = activity.getSharedPreferences("reader", Context.MODE_PRIVATE)
    private var zoom = prefs.getInt(ZOOM_KEY, DEFAULT_ZOOM).coerceIn(ZOOMS.indices)

    /** Whether an article has been opened, so there is something to come back to. */
    var hasPage = false
        private set

    private val position = TextView(activity).apply {
        gravity = Gravity.CENTER
        setTextColor(Color.BLACK)
        Ui.fitOneLine(this, 15)
    }

    // Paths of tiny pages that only forward to a section of another article. Wikipedia has over a
    // million of them; they pass through the reader but do not belong in the reading history.
    private val forwarding = java.util.Collections.synchronizedSet(HashSet<String>())

    // Stylesheets are shared by every article; keeping them saves a dozen lookups per page.
    private val shared = object : LinkedHashMap<String, Library.Item>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Library.Item>): Boolean = size > 48
    }

    // The section headings of the articles shown lately, read from each one's HTML as it is served.
    private val outlines = object : LinkedHashMap<String, List<ArticleSections.Section>>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, List<ArticleSections.Section>>): Boolean = size > 8
    }

    private var sections: List<ArticleSections.Section> = emptyList()

    // An article being reopened where the reader left it: its path and how far down that was.
    // Set from open() until the page has loaded, been laid out and been scrolled there.
    private var returning: Pair<String, Float>? = null
    private val saveSoon = Runnable { history.save() }
    private var closed = false

    // The first row is the top of the article; the sections follow, indented by their level.
    private val sectionRows = object : BaseAdapter() {
        override fun getCount(): Int = sections.size + 1
        override fun getItem(position: Int): Any? = sections.getOrNull(position - 1)
        override fun getItemId(position: Int): Long = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val row = (convertView as? TextView) ?: TextView(activity).apply {
                setTextColor(Color.BLACK)
                minimumHeight = Ui.dp(activity, 52)
                gravity = Gravity.CENTER_VERTICAL
            }
            val section = sections.getOrNull(position - 1)
            val depth = ((section?.level ?: 2) - 2).coerceIn(0, 3)
            row.text = section?.title ?: TOP
            row.typeface = if (depth == 0) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
            row.textSize = if (depth == 0) 20f else 18f
            row.setPadding(Ui.dp(activity, 14 + 22 * depth), Ui.dp(activity, 8), Ui.dp(activity, 14), Ui.dp(activity, 8))
            return row
        }
    }

    private val sectionList = ListView(activity).apply {
        adapter = sectionRows
        divider = ColorDrawable(Color.BLACK)
        dividerHeight = Ui.dp(activity, 1)
        selector = ColorDrawable(Color.TRANSPARENT)
        overScrollMode = View.OVER_SCROLL_NEVER
        isVerticalFadingEdgeEnabled = false
        isVerticalScrollBarEnabled = false // it is grey and fades out, both of which e-ink shows badly
        setOnItemClickListener { _, _, position, _ -> jumpTo(sections.getOrNull(position - 1)) }
    }

    private val sectionsNote = TextView(activity).apply {
        textSize = 15f
        setTextColor(Color.BLACK)
        setPadding(Ui.dp(activity, 14), Ui.dp(activity, 8), Ui.dp(activity, 14), Ui.dp(activity, 8))
    }

    // Lies over the article while open, so the article keeps its size and place underneath.
    private val sectionsPanel = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(Color.WHITE)
        visibility = View.GONE
        addView(sectionsNote)
        addView(Ui.rule(activity), ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(activity, 1))
        addView(sectionList, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
    }

    private val web = WebView(activity).apply {
        setBackgroundColor(Color.WHITE)
        overScrollMode = View.OVER_SCROLL_NEVER
        isVerticalScrollBarEnabled = false
        isHorizontalScrollBarEnabled = false
        settings.javaScriptEnabled = false // articles are static HTML; scripts would only cost time
        settings.textZoom = ZOOMS[zoom]
        settings.useWideViewPort = true
        settings.builtInZoomControls = true
        settings.displayZoomControls = false
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        webViewClient = Client()
        setOnScrollChangeListener { _, _, _, _, _ ->
            showPosition()
            notePosition()
        }
    }

    val view: LinearLayout = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(Color.WHITE)
        val content = FrameLayout(activity).apply {
            addView(web, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            addView(sectionsPanel, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }
        addView(content, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        addView(Ui.rule(activity), ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(activity, 1))
        val bar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            // Rows line children up by text baseline unless told not to, which shifts any button
            // whose text is a different size from its neighbours'.
            isBaselineAligned = false
            fun add(v: View, weight: Float) = addView(v, LinearLayout.LayoutParams(0, Ui.dp(activity, 52), weight))
            add(Ui.button(activity, "Back", fit = true) { onBack() }, 1.2f)
            add(Ui.button(activity, "Search", fit = true) { hideSections(); onSearch() }, 1.5f)
            add(Ui.button(activity, "Sections", fit = true) { toggleSections() }, 1.9f)
            add(Ui.button(activity, "A−", fit = true) { changeZoom(-1) }, 0.9f)
            add(Ui.button(activity, "A+", fit = true) { changeZoom(1) }, 0.9f)
            add(position, 0.9f)
            add(Ui.button(activity, "▲", fit = true) { turnPage(-1) }, 1f)
            add(Ui.button(activity, "▼", fit = true) { turnPage(1) }, 1f)
        }
        addView(bar)
    }

    /** Shows an article, [position] of the way down it: 0 for its top, up to 1 for its end. */
    fun open(path: String, position: Float = 0f) {
        hasPage = true
        hideSections()
        returning = if (position > 0f) path to position else null
        web.loadUrl(urlFor(path))
    }

    /** Keeps how far the article has been read; for when the app is about to leave the screen. */
    fun pause() {
        web.removeCallbacks(saveSoon)
        history.save()
    }

    /** Frees the web view; for when the screen is being replaced. */
    fun close() {
        pause()
        closed = true
        web.destroy()
    }

    /**
     * Closes the list of sections if it is open; otherwise goes back one step, which is the place
     * a jump to a section was made from, or the previous article. False if there is nothing to go
     * back to.
     */
    fun back(): Boolean {
        if (sectionsShowing()) {
            hideSections()
            return true
        }
        if (!web.canGoBack()) return false
        web.goBack()
        return true
    }

    /** Moves one screen down (1) or up (-1), keeping a line of overlap so the eye can find its place. */
    fun turnPage(direction: Int) {
        if (sectionsShowing()) return turnSectionsPage(direction)
        returning = null // the reader has taken over
        val step = web.height - Ui.dp(activity, 32)
        web.scrollTo(0, (web.scrollY + direction * step).coerceIn(0, maxScroll()))
    }

    /** Pages the list by whole rows: the last row showing becomes the first, or the reverse. */
    private fun turnSectionsPage(direction: Int) {
        val first = sectionList.firstVisiblePosition
        val last = sectionList.lastVisiblePosition
        if (first < 0 || last <= first) return
        sectionList.setSelection(if (direction > 0) last else (first - (last - first)).coerceAtLeast(0))
    }

    private fun sectionsShowing(): Boolean = sectionsPanel.visibility == View.VISIBLE

    private fun hideSections() {
        sectionsPanel.visibility = View.GONE
    }

    private fun toggleSections() {
        if (sectionsShowing()) return hideSections()
        val path = currentPath() ?: return
        val found = synchronized(outlines) { outlines[path] }
            ?: runCatching { item(path)?.bytes?.let(ArticleSections::parse) }.getOrNull().orEmpty()
        if (found.isEmpty()) {
            Toast.makeText(activity, "This article has no sections.", Toast.LENGTH_SHORT).show()
            return
        }
        sections = found
        sectionRows.notifyDataSetChanged()
        sectionList.setSelection(0)
        sectionsNote.text = web.title?.takeIf { it.isNotBlank() }?.let { "Sections of $it" } ?: "Sections"
        sectionsPanel.visibility = View.VISIBLE
    }

    /**
     * Shows a section, or the top of the article for null. With scripts off, the way to reach a
     * heading is the page's own address with the heading's id after "#": the WebView scrolls there
     * without reloading and, as with a footnote link, Back returns to where the reader was.
     */
    private fun jumpTo(section: ArticleSections.Section?) {
        hideSections()
        returning = null
        if (section == null) return web.scrollTo(0, 0)
        val page = web.url?.substringBefore('#') ?: return
        web.loadUrl(page + "#" + Uri.encode(section.id))
    }

    private fun currentPath(): String? = web.url?.let { pathOf(Uri.parse(it)) }?.takeIf { it.isNotEmpty() }

    private fun maxScroll(): Int =
        ((web.contentHeight * activity.resources.displayMetrics.density).toInt() - web.height).coerceAtLeast(0)

    private fun showPosition() {
        val max = maxScroll()
        position.text = if (max == 0) "" else "${(web.scrollY.toLong() * 100 / max).coerceIn(0, 100)}%"
    }

    private fun changeZoom(delta: Int) {
        zoom = (zoom + delta).coerceIn(ZOOMS.indices)
        web.settings.textZoom = ZOOMS[zoom]
        prefs.edit().putInt(ZOOM_KEY, zoom).apply()
        web.postDelayed(::notePosition, 600) // the article is a different length now
    }

    /** Remembers how far down the article on screen the reader is, for reopening it there. */
    private fun notePosition() {
        if (closed || returning != null) return // still on its way to where it was; the top is not where the reader is
        val path = currentPath() ?: return
        val max = maxScroll()
        history.setPosition(path, if (max == 0) 0f else (web.scrollY.toFloat() / max).coerceIn(0f, 1f))
        web.removeCallbacks(saveSoon)
        web.postDelayed(saveSoon, 1500)
    }

    /**
     * Scrolls a reopened article to where the reader was. That can only be done once its length is
     * known, and a page is laid out a moment after it finishes loading, a long one in several
     * steps. So this looks again every [SETTLE_MILLIS]: it scrolls once the length has stopped
     * changing, scrolls again if it changes after all, and is done when it has held for
     * [SETTLE_CHECKS] looks. A reader who moves the page meanwhile is left where they went.
     */
    private fun settle(path: String, fraction: Float, lastHeight: Int, steady: Int, placed: Int, looks: Int) {
        if (closed || returning?.first != path) return // another article was opened from the list meanwhile
        if (currentPath() != path) { // the reader followed a link before this one had settled
            returning = null
            return
        }
        if (placed >= 0 && web.scrollY != placed) { // moved by hand
            returning = null
            return notePosition()
        }
        val height = web.contentHeight
        val still = if (height > 0 && height == lastHeight) steady + 1 else 0
        var at = placed
        if (still == 1 || (looks >= SETTLE_LOOKS && placed < 0)) {
            at = (fraction * maxScroll()).toInt()
            web.scrollTo(0, at)
        }
        if (still >= SETTLE_CHECKS || looks >= SETTLE_LOOKS) {
            returning = null
            showPosition()
            return notePosition()
        }
        web.postDelayed({ settle(path, fraction, height, still, at, looks + 1) }, SETTLE_MILLIS)
    }

    private fun urlFor(path: String): String =
        Uri.Builder().scheme("https").authority(HOST).path("/$path").build().toString()

    private fun pathOf(url: Uri): String = url.path.orEmpty().removePrefix("/")

    private inner class Client : WebViewClient() {
        /** Link taps. Articles open here; anything on the real internet cannot, and says so. */
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url
            if (url.host != HOST) {
                Toast.makeText(activity, "That link leaves Wikipedia and needs the internet.", Toast.LENGTH_SHORT).show()
                return true
            }
            // A link may point at a redirect ("USA"). Load the real article so its own links resolve.
            val path = pathOf(url)
            val real = runCatching { library.resolvePath(path) }.getOrNull()
            if (real != null && real != path) {
                view.loadUrl(urlFor(real) + url.encodedFragment?.let { "#$it" }.orEmpty())
                return true
            }
            return false
        }

        /** Every request is answered from the Wikipedia file; nothing ever goes to the network. */
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
            val url = request.url
            if (url.host != HOST) return response("text/plain", ByteArray(0), 404)
            val path = pathOf(url)
            return runCatching { serve(path, request.isForMainFrame) }.getOrElse {
                if (request.isForMainFrame) page("This article could not be read", it.message ?: it.toString(), 500)
                else response("text/plain", ByteArray(0), 500)
            }
        }

        override fun onPageFinished(view: WebView, url: String) {
            // The page's height is only known once it has been laid out, a moment after this.
            view.postDelayed(::showPosition, 400)
            val path = pathOf(Uri.parse(url))
            val title = view.title
            if (path.isNotEmpty() && !title.isNullOrBlank() && title != MISSING_TITLE && path !in forwarding) history.add(path, title)
            val back = returning
            if (back != null && back.first == path) {
                settle(path, back.second, lastHeight = -1, steady = 0, placed = -1, looks = 0)
            } else {
                returning = null
                notePosition()
            }
        }
    }

    private fun serve(path: String, mainFrame: Boolean): WebResourceResponse {
        val item = item(path)
            ?: return if (mainFrame) page(MISSING_TITLE, "\"$path\" is not in this copy of Wikipedia.", 404)
            else response("text/plain", ByteArray(0), 404)
        val type = item.mimeType.substringBefore(';').trim()
        if (mainFrame && item.bytes.size < 2048 && String(item.bytes).contains("http-equiv=\"refresh\"")) forwarding += path
        val article = mainFrame && type == "text/html"
        if (article) ArticleSections.parse(item.bytes).let { synchronized(outlines) { outlines[path] = it } }
        val bytes = if (article) withStyle(item.bytes) else item.bytes
        return response(type, bytes, 200, item.mimeType.substringAfter("charset=", "utf-8").substringBefore(';').trim())
    }

    private fun item(path: String): Library.Item? {
        val isShared = path.startsWith("_")
        if (isShared) synchronized(shared) { shared[path] }?.let { return it }
        val item = library.item(path) ?: return null
        if (isShared && item.bytes.size <= 512 * 1024) synchronized(shared) { shared[path] = item }
        return item
    }

    private fun response(type: String, bytes: ByteArray, status: Int, charset: String = "utf-8"): WebResourceResponse =
        WebResourceResponse(type, charset, status, if (status == 200) "OK" else "Error", emptyMap(), ByteArrayInputStream(bytes))

    private fun page(title: String, message: String, status: Int): WebResourceResponse = response(
        "text/html",
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>$title</title>$STYLE</head><body><h1>$title</h1><p>${escape(message)}</p></body></html>"
            .toByteArray(),
        status,
    )

    private fun escape(text: String): String = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    /** Adds the e-ink stylesheet to an article, just before its head closes. */
    private fun withStyle(html: ByteArray): ByteArray {
        val at = indexOf(html, HEAD_END).takeIf { it >= 0 } ?: 0
        return html.copyOfRange(0, at) + STYLE_BYTES + html.copyOfRange(at, html.size)
    }

    private fun indexOf(data: ByteArray, wanted: ByteArray): Int {
        val limit = minOf(data.size, 256 * 1024) - wanted.size
        outer@ for (i in 0..limit) {
            for (k in wanted.indices) if (data[i + k] != wanted[k]) continue@outer
            return i
        }
        return -1
    }

    private companion object {
        const val HOST = "wiki.offline"
        const val ZOOM_KEY = "zoom"
        const val DEFAULT_ZOOM = 2
        const val MISSING_TITLE = "Not found"
        const val TOP = "(Top)"
        const val SETTLE_MILLIS = 150L
        const val SETTLE_CHECKS = 6  // looks in a row with the same length before the page counts as laid out
        const val SETTLE_LOOKS = 60  // looks before giving up waiting for that: nine seconds
        val ZOOMS = intArrayOf(85, 100, 115, 130, 150, 175, 200, 230)
        val HEAD_END = "</head>".toByteArray()

        // Wikipedia's own stylesheet does the layout; this only adapts it to a small e-ink screen:
        //  - pure black on pure white (greys dither badly), links underlined instead of blue;
        //  - nothing animated, no side margins, navigation boxes and maintenance banners removed;
        //  - "no images" builds either swap each picture for a transparent placeholder or remove
        //    it and leave its frame and caption behind, so any picture frame without a real
        //    picture in it is dropped whole;
        //  - so is a location map without its picture (its place-name labels would otherwise land
        //    on the rows around it), with the infobox row holding it and that row's caption above.
        //    A row counts only if the map sits in its cell directly or under at most three plain
        //    divs; "any row containing a map" would also catch a row holding a nested infobox;
        //  - and so is a settlement infobox's flag, seal or coat of arms without its picture, which
        //    would leave just its caption, with their whole row when nothing else is in it. A row
        //    that also holds a table (Melbourne's neighbouring places) stays;
        //  - a jump to a section puts its heading at the top of the screen. Wikipedia's skin leaves
        //    75px above it for a sticky header that is not here.
        const val STYLE = """<style>
html,body{background:#fff!important}
body,body *{color:#000!important;background-color:transparent!important;background-image:none!important;animation:none!important;transition:none!important;text-shadow:none!important;box-shadow:none!important;scroll-behavior:auto!important}
a,a:visited{text-decoration:underline!important}
.mw-page-container,.mw-page-container-inner,.mw-content-container,.mw-body{max-width:none!important;margin:0!important;padding-left:0!important;padding-right:0!important}
.mw-body{padding:0 12px 24px!important}
.navbox,.navbox-styles,.sistersitebox,.side-box,.mw-editsection,.noprint,.mw-jump-link,.mw-footer,#footer,.ambox,.mw-indicators{display:none!important}
img[src^="data:image/svg+xml"]{display:none!important}
:is(figure,.thumb,.tmulti,li.gallerybox,.infobox-image):not(:has(img:not([src^="data:image/svg+xml"]))){display:none!important}
.locmap:not(:has(img:not([src^="data:image/svg+xml"]))){display:none!important}
.infobox tr:has(>td>.locmap,>td>div>.locmap,>td>div>div>.locmap,>td>div>div>div>.locmap):not(:has(img:not([src^="data:image/svg+xml"]))){display:none!important}
.infobox tr:has(>td:only-child>.infobox-caption:only-child):has(+tr>td>.locmap,+tr>td>div>.locmap,+tr>td>div>div>.locmap,+tr>td>div>div>div>.locmap):not(:has(+tr img:not([src^="data:image/svg+xml"]))){display:none!important}
.ib-settlement-cols-cell:not(:has(img:not([src^="data:image/svg+xml"]))){display:none!important}
.infobox tr:has(>td.maptable):not(:has(img:not([src^="data:image/svg+xml"]),table)){display:none!important}
.mw-heading :is(h1,h2,h3,h4,h5,h6){scroll-margin-top:8px!important}
table{max-width:100%!important}
th{font-weight:bold!important}
pre{white-space:pre-wrap!important}
</style>"""
        val STYLE_BYTES = STYLE.toByteArray()
    }
}
