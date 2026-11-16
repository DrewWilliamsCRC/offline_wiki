package dev.offlinewiki.reader

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.io.ByteArrayInputStream

/**
 * Shows one article in a WebView fed straight from the Wikipedia file, with controls suited to
 * e-ink: whole-page turns instead of smooth scrolling, text size buttons, and no animation.
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
        setOnScrollChangeListener { _, _, _, _, _ -> showPosition() }
    }

    val view: LinearLayout = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(Color.WHITE)
        addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        addView(Ui.rule(activity), ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(activity, 1))
        val bar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            // Rows line children up by text baseline unless told not to, which shifts any button
            // whose text is a different size from its neighbours'.
            isBaselineAligned = false
            fun add(v: View, weight: Float) = addView(v, LinearLayout.LayoutParams(0, Ui.dp(activity, 52), weight))
            add(Ui.button(activity, "Back", fit = true) { onBack() }, 1.3f)
            add(Ui.button(activity, "Search", fit = true) { onSearch() }, 1.8f)
            add(Ui.button(activity, "A−", fit = true) { changeZoom(-1) }, 1f)
            add(Ui.button(activity, "A+", fit = true) { changeZoom(1) }, 1f)
            add(position, 1f)
            add(Ui.button(activity, "▲", fit = true) { turnPage(-1) }, 1.1f)
            add(Ui.button(activity, "▼", fit = true) { turnPage(1) }, 1.1f)
        }
        addView(bar)
    }

    fun open(path: String) {
        hasPage = true
        web.loadUrl(urlFor(path))
    }

    /** Goes to the previous article; false if there is none. */
    fun back(): Boolean {
        if (!web.canGoBack()) return false
        web.goBack()
        return true
    }

    /** Moves one screen down (1) or up (-1), keeping a line of overlap so the eye can find its place. */
    fun turnPage(direction: Int) {
        val step = web.height - Ui.dp(activity, 32)
        web.scrollTo(0, (web.scrollY + direction * step).coerceIn(0, maxScroll()))
    }

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
        }
    }

    private fun serve(path: String, mainFrame: Boolean): WebResourceResponse {
        val item = item(path)
            ?: return if (mainFrame) page(MISSING_TITLE, "\"$path\" is not in this copy of Wikipedia.", 404)
            else response("text/plain", ByteArray(0), 404)
        val type = item.mimeType.substringBefore(';').trim()
        if (mainFrame && item.bytes.size < 2048 && String(item.bytes).contains("http-equiv=\"refresh\"")) forwarding += path
        val bytes = if (mainFrame && type == "text/html") withStyle(item.bytes) else item.bytes
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
        val ZOOMS = intArrayOf(85, 100, 115, 130, 150, 175, 200, 230)
        val HEAD_END = "</head>".toByteArray()

        // Wikipedia's own stylesheet does the layout; this only adapts it to a small e-ink screen:
        //  - pure black on pure white (greys dither badly), links underlined instead of blue;
        //  - nothing animated, no side margins, navigation boxes and maintenance banners removed;
        //  - "no images" builds either swap each picture for a transparent placeholder or remove
        //    it and leave its frame and caption behind, so any picture frame without a real
        //    picture in it is dropped whole.
        const val STYLE = """<style>
html,body{background:#fff!important}
body,body *{color:#000!important;background-color:transparent!important;background-image:none!important;animation:none!important;transition:none!important;text-shadow:none!important;box-shadow:none!important;scroll-behavior:auto!important}
a,a:visited{text-decoration:underline!important}
.mw-page-container,.mw-page-container-inner,.mw-content-container,.mw-body{max-width:none!important;margin:0!important;padding-left:0!important;padding-right:0!important}
.mw-body{padding:0 12px 24px!important}
.navbox,.navbox-styles,.sistersitebox,.side-box,.mw-editsection,.noprint,.mw-jump-link,.mw-footer,#footer,.ambox,.mw-indicators{display:none!important}
img[src^="data:image/svg+xml"]{display:none!important}
:is(figure,.thumb,.tmulti,li.gallerybox,.infobox-image):not(:has(img:not([src^="data:image/svg+xml"]))){display:none!important}
table{max-width:100%!important}
th{font-weight:bold!important}
pre{white-space:pre-wrap!important}
</style>"""
        val STYLE_BYTES = STYLE.toByteArray()
    }
}
