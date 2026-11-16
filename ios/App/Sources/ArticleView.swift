import SwiftUI

/// One article, with back/forward through the articles reached from it and a text size control.
struct ArticleView: View {
    let article: Library.Article
    @StateObject private var web: WebController
    @AppStorage("textSize") private var textSize = 100

    private static let sizes = [80, 90, 100, 115, 130, 150, 175, 200]

    init(library: Library, article: Library.Article, history: History) {
        self.article = article
        _web = StateObject(wrappedValue: WebController(library: library, history: history))
    }

    var body: some View {
        WebView(controller: web)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(web.title ?? article.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { web.goBack() } label: { Label("Previous article", systemImage: "chevron.backward") }
                        .disabled(!web.canGoBack)
                    Button { web.goForward() } label: { Label("Next article", systemImage: "chevron.forward") }
                        .disabled(!web.canGoForward)
                    Spacer()
                    Button { step(-1) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                        .disabled(textSize <= ArticleView.sizes.first!)
                    Button { step(1) } label: { Label("Larger text", systemImage: "textformat.size.larger") }
                        .disabled(textSize >= ArticleView.sizes.last!)
                }
            }
            .onAppear { web.open(article.path, textSize: textSize) }
            .onChange(of: textSize) { web.setTextSize($0) }
    }

    private func step(_ direction: Int) {
        let sizes = ArticleView.sizes
        let current = sizes.firstIndex(where: { $0 >= textSize }) ?? sizes.count - 1
        textSize = sizes[min(max(current + direction, 0), sizes.count - 1)]
    }
}
