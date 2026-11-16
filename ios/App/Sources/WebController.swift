import Foundation
import SwiftUI
import WebKit

/// Owns the web view that shows articles and answers every request it makes from the Wikipedia file.
///
/// Articles live at `wiki://offline/<path in the ZIM file>`, so their relative links and stylesheets
/// resolve unchanged. Nothing is fetched from the network; links that leave Wikipedia are handed to
/// the system browser.
@MainActor
final class WebController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var title: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    let webView: WKWebView
    private let library: Library
    private let history: History
    private let server: ArticleServer
    private var opened = false

    init(library: Library, history: History) {
        self.library = library
        self.history = history
        server = ArticleServer(library: library)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(server, forURLScheme: WebController.scheme)
        // Articles are static HTML; their scripts would only cost time. Our own calls still run.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Shows an article. Only the first call does anything, so that returning to the screen keeps
    /// the reader where it was.
    func open(_ path: String, textSize: Int) {
        guard !opened else { return }
        opened = true
        server.textSize = textSize
        webView.load(URLRequest(url: WebController.url(for: path)))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func setTextSize(_ percent: Int) {
        server.textSize = percent
        webView.evaluateJavaScript("document.documentElement.style.webkitTextSizeAdjust='\(percent)%'")
    }

    // MARK: Addresses

    static let scheme = "wiki"

    static func url(for path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "offline"
        components.path = "/" + path
        return components.url!
    }

    static func path(of url: URL) -> String { String(url.path.dropFirst()) }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        guard url.scheme == WebController.scheme else {
            // A link out of Wikipedia. It cannot open here; the system browser can try.
            if action.navigationType == .linkActivated { openExternally(url) }
            return .cancel
        }
        // A link may point at a redirect ("USA"). Load the real article so its own links resolve.
        let path = WebController.path(of: url)
        if let real = library.resolvePath(path), real != path {
            var target = URLComponents(url: WebController.url(for: real), resolvingAgainstBaseURL: false)!
            target.percentEncodedFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment
            webView.load(URLRequest(url: target.url!))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        title = webView.title
        guard let url = webView.url, let title = webView.title, !title.isEmpty else { return }
        let path = WebController.path(of: url)
        if !path.isEmpty, title != ArticleServer.missingTitle, !server.isForwarding(path) {
            history.add(path: path, title: title)
        }
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }
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
    private var _textSize = 100

    init(library: Library) { self.library = library }

    var textSize: Int {
        get { lock.withLock { _textSize } }
        set { lock.withLock { _textSize = newValue } }
    }

    /// Whether a path is one of Wikipedia's tiny pages that only forward to a section of another
    /// article. There are over a million; they pass through the reader but are not "read".
    func isForwarding(_ path: String) -> Bool { lock.withLock { forwarding.contains(path) } }

    fileprivate func begin(_ id: ObjectIdentifier) { lock.withLock { _ = live.insert(id) } }

    /// Whether the request was still wanted; either way it is no longer tracked.
    fileprivate func end(_ id: ObjectIdentifier) -> Bool { lock.withLock { live.remove(id) != nil } }

    fileprivate func answer(_ url: URL, mainFrame: Bool) -> (URLResponse, Data) {
        let path = WebController.path(of: url)
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
    //  - in a "no images" build every picture is a transparent placeholder, so those are dropped
    //    together with the frames and captions that would surround empty space;
    //  - a dark appearance that follows the system setting.
    private func style() -> String {
        """
        <style>
        html{-webkit-text-size-adjust:\(textSize)%}
        .mw-page-container,.mw-page-container-inner,.mw-content-container,.mw-body{max-width:none!important;margin:0!important;padding-left:0!important;padding-right:0!important}
        .mw-body{padding:0 14px 28px!important}
        .navbox,.navbox-styles,.sistersitebox,.side-box,.mw-editsection,.noprint,.mw-jump-link,.mw-footer,#footer,.ambox,.mw-indicators{display:none!important}
        img[src^="data:image/svg+xml"]{display:none!important}
        figure:has(img[src^="data:image/svg+xml"]),.thumb:has(img[src^="data:image/svg+xml"]),li.gallerybox:has(img[src^="data:image/svg+xml"]),.infobox-image:has(img[src^="data:image/svg+xml"]){display:none!important}
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
