import SwiftUI
import WikiCore

/// One article, with back/forward through the articles reached from it, a menu of its sections
/// and a text size control.
struct ArticleView: View {
    let article: Library.Article
    @StateObject private var web: WebController
    @AppStorage("textSize") private var textSize = 100
    @State private var showingSections = false

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
                    Button { showingSections = true } label: { Label("Sections", systemImage: "list.bullet") }
                        .disabled(web.sections.isEmpty)
                    Spacer()
                    Button { step(-1) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                        .disabled(textSize <= ArticleView.sizes.first!)
                    Button { step(1) } label: { Label("Larger text", systemImage: "textformat.size.larger") }
                        .disabled(textSize >= ArticleView.sizes.last!)
                }
            }
            .sheet(isPresented: $showingSections) {
                SectionsView(sections: web.sections) { section in
                    showingSections = false
                    web.jump(to: section)
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

/// An article's sections as a list to jump from: the top of the article first, then every heading,
/// indented by its level.
struct SectionsView: View {
    let sections: [ArticleSections.Section]
    let choose: (ArticleSections.Section?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button { choose(nil) } label: { Text("(Top)").fontWeight(.semibold) }
                // Numbered rather than keyed by heading id: nothing promises that ids never repeat.
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Button { choose(section) } label: {
                        Text(section.title)
                            .fontWeight(section.level == 2 ? .semibold : .regular)
                            .padding(.leading, CGFloat(min(section.level - 2, 3)) * 18)
                    }
                }
            }
            .listStyle(.plain)
            .foregroundStyle(.primary)
            .navigationTitle("Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
