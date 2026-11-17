import Foundation
import SwiftUI
import WebKit
import WikiCore

/// Owns the web view that shows articles and answers every request it makes from the Wikipedia file.
///
/// Articles live at `wiki://offline/<path in the ZIM file>`, so their relative links and stylesheets
/// resolve unchanged. Nothing is fetched from the network; links that leave Wikipedia are handed to
/// the system browser.
@MainActor
final class WebController: NSObject, ObservableObject, WKNavigationDelegate, UIScrollViewDelegate {
    @Published private(set) var title: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The headings of the article on screen, for the sections menu; empty while a page loads.
    @Published private(set) var sections: [ArticleSections.Section] = []

    let webView: WKWebView
    private let library: Library
    private let history: History
    private let server: ArticleServer
    private var opened = false
    private var finished = false   // whether the page on screen has finished loading
    private var titleObservation: NSKeyValueObservation?
    /// An article being reopened where the reader left it: its path and how far down that was.
    /// Set from `open` until the page has loaded and been scrolled there.
    private var returning: (path: String, position: Double)?

    init(library: Library, history: History) {
        self.library = library
        self.history = history
        server = ArticleServer(library: library)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(server, forURLScheme: WikiAddress.scheme)
        // Articles are static HTML; their scripts would only cost time. Our own calls still run.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.delegate = self
        // The title is watched rather than read when a page finishes: now and then the web view
        // says a page has finished a moment before it knows the page's title.
        titleObservation = webView.observe(\.title) { [weak self] _, _ in
            Task { @MainActor in self?.titleChanged() }
        }
    }

    /// Shows an article, `position` of the way down it: 0 for its top, up to 1 for its end. Only
    /// the first call does anything, so that returning to the screen keeps the reader where it was.
    func open(_ path: String, textSize: Int, position: Double = 0) {
        guard !opened else { return }
        opened = true
        server.textSize = textSize
        returning = position > 0 ? (path, position) : nil
        webView.load(URLRequest(url: WikiAddress.url(for: path)))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func setTextSize(_ percent: Int) {
        server.textSize = percent
        webView.evaluateJavaScript("document.documentElement.style.webkitTextSizeAdjust='\(percent)%'")
    }

    /// Scrolls to a section's heading, or to the top of the article for nil. This is a scroll, not
    /// a link: it adds no step to back/forward, which stay "previous article" and "next article".
    func jump(to section: ArticleSections.Section?) {
        guard let section else {
            webView.evaluateJavaScript("window.scrollTo(0, 0)")
            return
        }
        // The id is passed as an argument, so nothing in it can be read as script.
        webView.callAsyncJavaScript(
            "document.getElementById(id)?.scrollIntoView()", arguments: ["id": section.id], in: nil, in: .page
        ) { _ in }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        guard url.scheme == WikiAddress.scheme else {
            // A link out of Wikipedia. It cannot open here; the system browser can try.
            if action.navigationType == .linkActivated { openExternally(url) }
            return .cancel
        }
        // A link may point at a redirect ("USA"). Load the real article so its own links resolve.
        let path = WikiAddress.path(of: url)
        if let real = library.resolvePath(path), real != path {
            var target = URLComponents(url: WikiAddress.url(for: real), resolvingAgainstBaseURL: false)!
            target.percentEncodedFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment
            webView.load(URLRequest(url: target.url!))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        sections = []
        finished = false // the title stays the last page's until this one's arrives
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        finished = true
        showSections()
        titleChanged()
        guard let url = webView.url else { return }
        let path = WikiAddress.path(of: url)
        guard let back = returning, back.path == path else {
            returning = nil
            return notePosition()
        }
        // The page is laid out by now, so its length is known. The height of the screen is passed
        // in, measured as notePosition measures it, so that the page lands exactly where it was.
        // (Both are arguments, like the id of a section, so nothing is read as script.)
        let view = webView.scrollView
        let visible = (view.bounds.height - view.adjustedContentInset.top - view.adjustedContentInset.bottom) / max(view.zoomScale, 0.01)
        webView.callAsyncJavaScript(
            "window.scrollTo(0, f * Math.max(0, document.documentElement.scrollHeight - v))",
            arguments: ["f": back.position, "v": Double(visible)], in: nil, in: .page
        ) { [weak self] _ in
            Task { @MainActor in
                self?.returning = nil
                self?.notePosition()
            }
        }
    }

    /// Shows the page's title once there is one and, if the page has finished loading, puts the
    /// article in the reading history. Called when either happens, whichever comes last.
    private func titleChanged() {
        guard let title = webView.title, !title.isEmpty else { return }
        self.title = title
        guard finished, let url = webView.url else { return }
        let path = WikiAddress.path(of: url)
        if !path.isEmpty, title != ArticleServer.missingTitle, !server.isForwarding(path) {
            history.add(path: path, title: title)
        }
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) { notePosition() }

    /// Remembers how far down the article on screen the reader is, for reopening it there.
    private func notePosition() {
        // Not while a page is on its way to where it was: its top is not where the reader is.
        guard returning == nil, let url = webView.url else { return }
        let view = webView.scrollView
        let top = -view.adjustedContentInset.top
        let bottom = view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
        let fraction = bottom > top ? min(max((view.contentOffset.y - top) / (bottom - top), 0), 1) : 0
        history.setPosition(Double(fraction), of: WikiAddress.path(of: url))
    }

    /// Publishes the sections of the page now showing. They were read when the page was served;
    /// a page restored from far back in the history is read again, which is why this leaves the
    /// main thread.
    private func showSections() {
        guard let url = webView.url else { return }
        let path = WikiAddress.path(of: url)
        let server = self.server
        server.queue.async {
            let found = server.sections(of: path)
            Task { @MainActor [weak self] in
                guard let self, let now = self.webView.url, WikiAddress.path(of: now) == path else { return }
                self.sections = found
            }
        }
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }
}

/// How articles are addressed inside the web view: `wiki://offline/<path in the ZIM file>`.
/// Used from the main thread and from the queue that serves requests.
enum WikiAddress {
    static let scheme = "wiki"

    static func url(for path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "offline"
        components.path = "/" + path
        return components.url!
    }

    static func path(of url: URL) -> String { String(url.path.dropFirst()) }
}

/// Answers the web view's requests from the Wikipedia file, off the main thread.
///
/// The class itself is not tied to the main thread: the web view calls `start` and `stop` there
/// (see the extension), the reading happens on `queue`, and shared state is behind `lock`.
final class ArticleServer: NSObject {
    static let missingTitle = "Not found"

    private let library: Library
    fileprivate let queue = DispatchQueue(label: "article-server", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var live = Set<ObjectIdentifier>()     // requests the web view still wants answered
    private var forwarding = Set<String>()
    private var shared: [String: Library.Item] = [:]
    private var outlines: [String: [ArticleSections.Section]] = [:]   // by path, for the pages served lately
    private var outlineOrder: [String] = []
    private var _textSize = 100

    init(library: Library) { self.library = library }

    var textSize: Int {
        get { lock.withLock { _textSize } }
        set { lock.withLock { _textSize = newValue } }
    }

    /// Whether a path is one of Wikipedia's tiny pages that only forward to a section of another
    /// article. There are over a million; they pass through the reader but are not "read".
    func isForwarding(_ path: String) -> Bool { lock.withLock { forwarding.contains(path) } }

    /// An article's section headings: those read when it was served, or read now if that was too
    /// long ago to have been kept.
    func sections(of path: String) -> [ArticleSections.Section] {
        if let kept = lock.withLock({ outlines[path] }) { return kept }
        guard let item = try? library.item(path) else { return [] }
        return remember(ArticleSections.parse(item.data), for: path)
    }

    @discardableResult
    private func remember(_ sections: [ArticleSections.Section], for path: String) -> [ArticleSections.Section] {
        lock.withLock {
            if outlines.updateValue(sections, forKey: path) == nil { outlineOrder.append(path) }
            while outlineOrder.count > 16 { outlines[outlineOrder.removeFirst()] = nil }
        }
        return sections
    }

    fileprivate func begin(_ id: ObjectIdentifier) { lock.withLock { _ = live.insert(id) } }

    /// Whether the request was still wanted; either way it is no longer tracked.
    fileprivate func end(_ id: ObjectIdentifier) -> Bool { lock.withLock { live.remove(id) != nil } }

    fileprivate func answer(_ url: URL, mainFrame: Bool) -> (URLResponse, Data) {
        let path = WikiAddress.path(of: url)
        do {
            guard let item = try item(path) else {
                return mainFrame
                    ? page(url, ArticleServer.missingTitle, "\"\(path)\" is not in this copy of Wikipedia.", 404)
                    : respond(url, "text/plain", Data(), 404)
            }
            let type = item.mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "application/octet-stream"
            guard mainFrame, type == "text/html" else { return respond(url, item.mimeType, item.data, 200) }
            if item.data.count < 2048, String(decoding: item.data, as: UTF8.self).contains("http-equiv=\"refresh\"") {
                lock.withLock { _ = forwarding.insert(path) }
            }
            remember(ArticleSections.parse(item.data), for: path)
            return respond(url, "text/html; charset=utf-8", withStyle(item.data), 200)
        } catch {
            return mainFrame
                ? page(url, "This article could not be read", "\(error)", 500)
                : respond(url, "text/plain", Data(), 500)
        }
    }

    // Stylesheets are shared by every article; keeping them saves a dozen lookups per page.
    private func item(_ path: String) throws -> Library.Item? {
        let isShared = path.hasPrefix("_")
        if isShared, let kept = lock.withLock({ shared[path] }) { return kept }
        guard let item = try library.item(path) else { return nil }
        if isShared, item.data.count <= 512 * 1024 { lock.withLock { shared[path] = item } }
        return item
    }

    private func respond(_ url: URL, _ contentType: String, _ body: Data, _ status: Int) -> (URLResponse, Data) {
        let headers = ["Content-Type": contentType, "Content-Length": String(body.count)]
        return (HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, body)
    }

    private func page(_ url: URL, _ title: String, _ message: String, _ status: Int) -> (URLResponse, Data) {
        let safe = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>\(title)</title>\(style())</head><body><div class=\"mw-body\"><h1>\(title)</h1><p>\(safe)</p></div></body></html>"
        return respond(url, "text/html; charset=utf-8", Data(html.utf8), status)
    }

    /// Adds our stylesheet to an article, just before its head closes.
    private func withStyle(_ html: Data) -> Data {
        let marker = Data("</head>".utf8)
        let at = html.range(of: marker, in: 0..<min(html.count, 256 * 1024))?.lowerBound ?? 0
        var out = Data(capacity: html.count + 2048)
        out.append(html[0..<at])
        out.append(Data(style().utf8))
        out.append(html[at...])
        return out
    }

    // Wikipedia's own stylesheet does the layout; this adapts it to a phone:
    //  - the chosen text size, and no side margins or navigation clutter;
    //  - "no images" builds either swap each picture for a transparent placeholder or remove it
    //    and leave its frame and caption behind, so any picture frame without a real picture in
    //    it is dropped whole;
    //  - so is a location map without its picture (its place-name labels would otherwise land on
    //    the rows around it), with the infobox row holding it and that row's caption above. A row
    //    counts only if the map sits in its cell directly or under at most three plain divs; "any
    //    row containing a map" would also catch a row holding a nested infobox;
    //  - and so is a settlement infobox's flag, seal or coat of arms without its picture, which
    //    would leave just its caption, with their whole row when nothing else is in it. A row that
    //    also holds a table (Melbourne's neighbouring places) stays;
    //  - a jump to a section puts its heading at the top of the screen. Wikipedia's skin leaves 75px
    //    above it for a sticky header that is not here;
    //  - a dark appearance that follows the system setting.
    private func style() -> String {
        """
        <style>
        html{-webkit-text-size-adjust:\(textSize)%}
        .mw-page-container,.mw-page-container-inner,.mw-content-container,.mw-body{max-width:none!important;margin:0!important;padding-left:0!important;padding-right:0!important}
        .mw-body{padding:0 14px 28px!important}
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
        pre{white-space:pre-wrap!important}
        @media (prefers-color-scheme: dark){
        html,body{background:#000!important}
        body,body *{color:#e6e6e6!important;background-color:transparent!important;background-image:none!important;border-color:#555!important}
        a,a:visited{color:#7ab8ff!important}
        }
        </style>
        """
    }
}

extension ArticleServer: WKURLSchemeHandler {
    @MainActor
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        begin(id)
        guard let url = task.request.url else { return finish(task, id, nil, nil) }
        let mainFrame = task.request.mainDocumentURL == url
        queue.async { [self] in
            let (response, body) = answer(url, mainFrame: mainFrame)
            // A task must not be touched once the web view has stopped it. Stopping happens on the
            // main thread, so answering there too leaves no gap between the check and the answer.
            Task { @MainActor in self.finish(task, id, response, body) }
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        _ = end(ObjectIdentifier(task))
    }

    @MainActor
    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ response: URLResponse?, _ body: Data?) {
        guard end(id) else { return }
        guard let response, let body else { return task.didFailWithError(URLError(.badURL)) }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}

struct WebView: UIViewRepresentable {
    let controller: WebController

    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
