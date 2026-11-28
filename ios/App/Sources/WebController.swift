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
    /// The article on screen, as filed in the reading history: nil while a page loads, and for the
    /// "Not found" page and the tiny pages that only forward to another article.
    @Published private(set) var article: Library.Article?
    /// A footnote to show over the article, after a tap on its mark; nil when none is up.
    @Published var note: Note?

    /// A footnote's mark ("12") and its text, with the links in it.
    struct Note: Identifiable {
        let id: String // the note's element id in the page: cite_note-12
        let mark: String
        let text: AttributedString
    }

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
        // On an iPad WebKit otherwise shows pages as a desktop browser would, where the text size
        // the reader chooses (-webkit-text-size-adjust, see ArticleServer.style) has no effect.
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // The system's own find bar: "Find in Article" opens it.
        webView.isFindInteractionEnabled = true
        webView.uiDelegate = self // a long press on a link: see the extension at the end
        // A tap on a footnote mark ([12]) shows the note in a sheet over the article rather than
        // jumping to the list of references, so the reader stays where they were. It has to be
        // stopped before it becomes a navigation: WebKit scrolls to a fragment in the same page
        // even when the navigation delegate cancels it. Our own script, in a world of its own
        // (articles' scripts do not run), catches the click and passes the note's id on.
        let notes = WKUserScript(source: """
            document.addEventListener('click', (event) => {
                const link = event.target.closest && event.target.closest('a[href^="#cite_note"]');
                if (!link) return;
                event.preventDefault();
                window.webkit.messageHandlers.note.postMessage(decodeURIComponent(link.getAttribute('href').slice(1)));
            }, true);
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        webView.configuration.userContentController.addUserScript(notes)
        webView.configuration.userContentController.add(NoteTaps(self), contentWorld: .defaultClient, name: "note")
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

    /// Opens the system's find bar over the article.
    func find() { webView.findInteraction?.presentFindNavigator(showingReplace: false) }

    /// The article on screen at its own address on wikipedia.org, for sharing it or reading it
    /// online: the path in the file is the title as Wikipedia spells it in its addresses, and the
    /// file's name says the language (`wikipedia_en_...`). Nil when there is no article, or the
    /// file's name says no language.
    var onlineAddress: URL? { article.flatMap { onlineAddress(of: $0.path) } }

    /// The article at `path` at its own address on wikipedia.org; nil if the file's name says no
    /// language.
    func onlineAddress(of path: String) -> URL? {
        guard let language = library.language else { return nil }
        var address = URLComponents()
        address.scheme = "https"
        address.host = "\(language).wikipedia.org"
        // The path is percent-encoded here, "?" and "#" included, which a title may hold.
        address.percentEncodedPath = "/wiki/" + (path.addingPercentEncoding(withAllowedCharacters: WebController.pathCharacters) ?? path)
        return address.url
    }

    /// What may stand unencoded in a path on wikipedia.org: letters, digits and a few marks, not "/".
    private static let pathCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~!$&'()*+,;=:@"))

    /// Opens the article on screen on wikipedia.org, in the system browser.
    func openOnline() {
        if let address = onlineAddress { openExternally(address) }
    }

    func setTextSize(_ percent: Int) {
        server.textSize = percent
        webView.evaluateJavaScript("document.documentElement.style.webkitTextSizeAdjust='\(percent)%'")
    }

    /// Follows a link from outside the page, such as one in a footnote's sheet: an article here, or
    /// anything else in the system browser.
    func follow(_ url: URL) {
        if url.scheme == WikiAddress.scheme { webView.load(URLRequest(url: url)) } else { openExternally(url) }
    }

    /// Reads the footnote with element id `id` from the page and puts it up as `note`; if that
    /// fails, jumps to it as before. The note's own text and links are taken, not its back-link (^)
    /// or its styles.
    fileprivate func showNote(_ id: String) {
        let script = """
            const item = document.getElementById(id);
            if (!item) return null;
            const mark = document.querySelector('a[href="#' + CSS.escape(id) + '"]');
            const parts = [];
            const walk = (node) => {
                for (const child of node.childNodes) {
                    if (child.nodeType === Node.TEXT_NODE) {
                        parts.push([child.textContent, '']);
                    } else if (child.nodeType === Node.ELEMENT_NODE) {
                        if (['STYLE', 'LINK', 'SCRIPT'].includes(child.tagName) || child.classList.contains('mw-cite-backlink')) continue;
                        if (child.tagName === 'A') parts.push([child.textContent, child.href]); else walk(child);
                    }
                }
            };
            walk(item.querySelector('.reference-text') || item);
            return { mark: mark ? mark.textContent : '', parts: parts };
            """
        // The id is passed as an argument, so nothing in it can be read as script.
        webView.callAsyncJavaScript(script, arguments: ["id": id], in: nil, in: .page) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard case .success(let value) = result, let found = value as? [String: Any],
                      let parts = found["parts"] as? [[String]], !parts.isEmpty else {
                    if let here = self.webView.url, var jump = URLComponents(url: here, resolvingAgainstBaseURL: false) {
                        jump.fragment = id
                        if let target = jump.url { self.webView.load(URLRequest(url: target)) }
                    }
                    return
                }
                var text = AttributedString()
                for part in parts where part.count == 2 {
                    var piece = AttributedString(part[0].replacing(/\s+/, with: " "))
                    if !part[1].isEmpty, let link = URL(string: part[1]) { piece.link = link }
                    text += piece
                }
                let mark = (found["mark"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                self.note = Note(id: id, mark: mark, text: WebController.trimmed(text))
            }
        }
    }

    /// `text` without the spaces at its ends.
    private static func trimmed(_ text: AttributedString) -> AttributedString {
        var text = text
        while let first = text.characters.first, first.isWhitespace { text.removeSubrange(text.startIndex..<text.index(afterCharacter: text.startIndex)) }
        while let last = text.characters.last, last.isWhitespace { text.removeSubrange(text.index(beforeCharacter: text.endIndex)..<text.endIndex) }
        return text
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
        article = nil
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
            article = Library.Article(title: title, path: path)
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

    /// The opening paragraph of the article at `path`, as plain text, for a link's preview; nil if
    /// there is none. One of the tiny pages that only forward to a section of another article is
    /// followed, once. Footnote marks ([1]) and inline styles are left out; superscripts such as
    /// the 2 of km² stay.
    func summary(of path: String, forwarded: Bool = false) -> String? {
        if !forwarded, let target = forwardTarget(of: path) { return summary(of: target, forwarded: true) }
        guard let item = try? library.item(path), item.mimeType.hasPrefix("text/html") else { return nil }
        let html = String(decoding: item.data.prefix(512 * 1024), as: UTF8.self)
        for match in html.matches(of: /<p\b[^>]*>(.*?)<\/p>/.dotMatchesNewlines()) {
            let marked = String(match.1)
                .replacing(/<style\b.*?<\/style>|<sup\b[^>]*class="[^"]*reference[^"]*"[^>]*>.*?<\/sup>/.dotMatchesNewlines(), with: "")
                .replacing(/<[^>]+>/, with: "")
            let text = ArticleServer.decodeEntities(marked)
                .replacingOccurrences(of: "\u{24D8}", with: "") // ⓘ, the mark of a pronunciation's sound file
                .replacing(/\s+/, with: " ")
                .trimmingCharacters(in: .whitespaces)
            // Empty paragraphs and stray coordinates come before the first real one.
            guard text.count > 40 else { continue }
            return text.count > 600 ? String(text.prefix(600)) + "…" : text
        }
        return nil
    }

    /// Where one of the tiny pages that only forward to a section of another article leads: that
    /// article's path, without the section. Nil for any other page.
    func forwardTarget(of path: String) -> String? {
        guard let item = try? library.item(path), item.data.count < 2048 else { return nil }
        // content="0;URL='./A_Song_for_You#Herbie_Hancock_featuring_Christina_Aguilera'"
        let html = String(decoding: item.data, as: UTF8.self)
        guard let match = html.firstMatch(of: /http-equiv="refresh"[^>]*?content="[^"]*?[Uu][Rr][Ll]='?(?:\.\/)?([^"'#]+)/) else { return nil }
        return String(match.1).removingPercentEncoding ?? String(match.1)
    }

    /// Decodes the character references HTML text may hold: numeric ones, and the few named ones
    /// that turn up in articles. Others are left as they are.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}",
                     "ndash": "–", "mdash": "—", "minus": "−", "thinsp": "\u{2009}", "hairsp": "\u{200a}"]
        return text.replacing(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/) { match in
            let name = String(match.1)
            if name.hasPrefix("#") {
                let number = name.dropFirst().lowercased().hasPrefix("x")
                    ? UInt32(name.dropFirst(2), radix: 16) : UInt32(name.dropFirst())
                return number.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.0)
            }
            return named[name] ?? String(match.0)
        }
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
    //  - on a wide screen (an iPad's, or a phone's turned sideways) the text keeps to a centred
    //    column of 40em, about 80 characters, rather than lines too long to follow. Tables and the
    //    floats beside the text (infoboxes) keep the full width. The rules apply only when the
    //    article is wider than that column (a container query), so a narrow screen, or text made
    //    large, keeps the layout and side margins it had. What lies outside the article's text
    //    (the title bar, the categories, the licence line) gets a width rather than a limit: on a
    //    wide screen the skin lays the page out as a grid, where auto margins would shrink the
    //    title bar to its title;
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
        .mw-parser-output{container-type:inline-size}
        @container (min-width:42em){
        :is(.mw-parser-output,section)>:not(section,table,figure,.thumb,.gallery,style,link,meta,[style*=margin],:has(table)){max-width:40em;margin-left:auto!important;margin-right:auto!important}
        :is(.mw-parser-output,section)>:is(ul,ol):not(.gallery){margin-left:max(1.6em,calc((100% - 40em)/2))!important}
        :is(.mw-parser-output,section)>table.wikitable:not([style*=float]){margin-left:auto!important;margin-right:auto!important}
        }
        .mw-body-header,.catlinks,.zim-footer{width:40em;max-width:100%;box-sizing:border-box;margin-left:auto!important;margin-right:auto!important}
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

/// Passes taps on footnote marks from the page's script to the controller. A go-between, because
/// the web view keeps its message handlers for as long as it lives, and the controller owns the
/// web view.
private final class NoteTaps: NSObject, WKScriptMessageHandler {
    weak var controller: WebController?

    init(_ controller: WebController) { self.controller = controller }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let id = message.body as? String, id.hasPrefix("cite_note") else { return }
        Task { @MainActor in self.controller?.showNote(id) } // assumeIsolated would need iOS 17
    }
}

// MARK: A long press on a link

/// A long press on a link shows where it leads before the reader goes there: the article's title
/// and opening paragraph, with Open, Save, Share and Copy Title. A link out of Wikipedia gets
/// Open in Browser and Copy Link; a link within the page (a footnote, a section) gets nothing, as
/// WebKit's own preview would try to load it from the web.
extension WebController: WKUIDelegate {
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else { return completionHandler(nil) }
        guard url.scheme == WikiAddress.scheme else {
            return completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "Open in Browser", image: UIImage(systemName: "safari")) { _ in self?.openExternally(url) },
                    UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.url = url },
                ])
            })
        }
        let path = WikiAddress.path(of: url)
        if let here = webView.url, WikiAddress.path(of: here) == path {
            return completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: nil))
        }
        // Read off the main thread: a 1 MB article takes a moment to decompress.
        let (library, server) = (self.library, self.server)
        server.queue.async {
            var article = library.article(at: path)
            // A page that only forwards to a section of another article stands for that article,
            // so that Save and Share give the article, as the article menu does.
            if let target = article.flatMap({ server.forwardTarget(of: $0.path) }), let real = library.article(at: target) {
                article = real
            }
            let summary = article.flatMap { server.summary(of: $0.path) }
            Task { @MainActor [weak self] in
                completionHandler(self?.linkMenu(url, path: path, article: article, summary: summary))
            }
        }
    }

    /// Tapping the preview opens the link, as tapping the link would have.
    func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating) {
        guard let url = elementInfo.linkURL, url.scheme == WikiAddress.scheme else { return }
        animator.addCompletion { [weak self] in self?.webView.load(URLRequest(url: url)) }
    }

    private func linkMenu(_ url: URL, path: String, article: Library.Article?, summary: String?) -> UIContextMenuConfiguration {
        let title = article?.title ?? path.replacingOccurrences(of: "_", with: " ")
        let text = article == nil ? "This article is not in this copy of Wikipedia." : summary
        return UIContextMenuConfiguration(identifier: nil, previewProvider: {
            let preview = UIHostingController(rootView: LinkPreview(title: title, summary: text))
            preview.preferredContentSize = preview.sizeThatFits(in: CGSize(width: LinkPreview.width, height: 640))
            return preview
        }) { [weak self] _ in
            guard let self, let article else { return nil }
            var actions = [
                UIAction(title: "Open", image: UIImage(systemName: "arrow.right.circle")) { [weak self] _ in
                    self?.webView.load(URLRequest(url: url))
                },
            ]
            if self.history.isSaved(article.path) {
                actions.append(UIAction(title: "Remove from Saved", image: UIImage(systemName: "bookmark.slash")) { [weak self] _ in
                    self?.history.removeSaved(path: article.path)
                })
            } else {
                actions.append(UIAction(title: "Save", image: UIImage(systemName: "bookmark")) { [weak self] _ in
                    self?.history.addSaved(article)
                })
            }
            if let address = self.onlineAddress(of: article.path) {
                actions.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.share(address)
                })
            }
            actions.append(UIAction(title: "Copy Title", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = article.title
            })
            return UIMenu(children: actions)
        }
    }

    /// The system's share sheet, over whatever is on screen.
    private func share(_ address: URL) {
        guard var top = webView.window?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [address], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = webView // an iPad shows it as a popover
        top.present(sheet, animated: true)
    }
}

/// What a long press on a link shows of the article it leads to.
struct LinkPreview: View {
    static let width: CGFloat = 360
    let title: String
    let summary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let summary { Text(summary).font(.subheadline) }
        }
        .padding(16)
        .frame(width: LinkPreview.width, alignment: .leading)
    }
}
