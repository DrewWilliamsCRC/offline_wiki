import SwiftUI
import WikiCore

/// One article, with back/forward through the articles reached from it, a menu of its sections
/// and a text size control, and a menu to save it, find a word in it, share it or open it on
/// wikipedia.org. `position` is how far down it to start: 0 for the top, up to 1.
struct ArticleView: View {
    let article: Library.Article
    let position: Double
    @StateObject private var web: WebController
    @ObservedObject private var history: History
    /// The reader's choice, as a percent of the system's text size (Settings, Display, Text Size).
    @AppStorage("textSize") private var textSize = 100
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingSections = false

    private static let sizes = [80, 90, 100, 115, 130, 150, 175, 200]

    init(library: Library, article: Library.Article, position: Double, history: History) {
        self.article = article
        self.position = position
        _web = StateObject(wrappedValue: WebController(library: library, history: history))
        _history = ObservedObject(wrappedValue: history)
    }

    var body: some View {
        WebView(controller: web)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(web.title ?? article.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The bottom bar is full, so these go in a menu in the navigation bar.
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        // Only an article that is filed in the history can be saved, so not "Not found".
                        if let article = web.article {
                            if history.isSaved(article.path) {
                                Button { history.removeSaved(path: article.path) } label: { Label("Remove from Saved", systemImage: "bookmark.slash") }
                            } else {
                                Button { history.addSaved(article) } label: { Label("Save", systemImage: "bookmark") }
                            }
                        }
                        Button { web.find() } label: { Label("Find in Article", systemImage: "magnifyingglass") }
                        if let address = web.onlineAddress, let article = web.article {
                            ShareLink(item: address, subject: Text(article.title)) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button { web.openOnline() } label: { Label("Open on Wikipedia", systemImage: "safari") }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
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
            .sheet(item: $web.note) { note in
                NoteView(note: note) { url in
                    web.note = nil
                    web.follow(url)
                }
            }
            .sheet(isPresented: $showingSections) {
                SectionsView(sections: web.sections) { section in
                    showingSections = false
                    web.jump(to: section)
                }
            }
            .onAppear { web.open(article.path, textSize: shownSize, position: position) }
            .onChange(of: textSize) { _ in web.setTextSize(shownSize) }
            .onChange(of: dynamicTypeSize) { _ in web.setTextSize(shownSize) }
    }

    /// What the article is shown at, as a percent of WebKit's own size: the reader's choice on top
    /// of the system's text size, as the rest of the app follows it.
    private var shownSize: Int { ArticleView.shown(textSize, at: dynamicTypeSize) }

    private static func shown(_ chosen: Int, at size: DynamicTypeSize) -> Int {
        let category = UIContentSizeCategory(size)
        // Capped: at the largest accessibility sizes tables and infoboxes are the first to give way.
        return min(400, Int((Double(chosen) * systemScale(category)).rounded()))
    }

    /// How much bigger than the standard size the system's body text is: 1 at the standard size.
    private static func systemScale(_ category: UIContentSizeCategory) -> Double {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits) / 17
    }

    /// Until 0.7 the size chosen was a percent of WebKit's own, whatever the system's text size.
    /// Converted once, to the nearest step, so that what someone already reads at does not jump.
    static func adoptSystemTextSize() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "textSizeFollowsSystem") else { return }
        defaults.set(true, forKey: "textSizeFollowsSystem")
        guard let chosen = defaults.object(forKey: "textSize") as? Int else { return }
        let wanted = Double(chosen) / systemScale(UIApplication.shared.preferredContentSizeCategory)
        let nearest = sizes.min { abs(Double($0) - wanted) < abs(Double($1) - wanted) }!
        defaults.set(nearest, forKey: "textSize")
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

/// A footnote, over the article, so the reader stays where they were. Its links open as links in
/// the article do: an article here, anything else in the system browser.
struct NoteView: View {
    let note: WebController.Note
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(note.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(note.mark.isEmpty ? "Note" : "Note \(note.mark)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
        .presentationDetents([.fraction(0.35), .large])
    }
}
