import SwiftUI

/// The search field and its results; with an empty field it lists recently read articles instead.
struct SearchView: View {
    let library: Library
    @EnvironmentObject private var history: History
    @State private var query = ""
    @State private var results: [Library.Article] = []
    @State private var searched = ""          // the query `results` belongs to
    @State private var stack: [Library.Article] = []

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack(path: $stack) {
            List {
                if !library.hasIndex {
                    Text("No search index was found next to \(library.fileName). Copy its .zim.idx file into the same folder.")
                        .foregroundStyle(.secondary)
                }
                if trimmed.isEmpty {
                    Button("Random article") {
                        if let article = library.randomArticle() { stack.append(article) }
                    }
                    if !history.articles.isEmpty {
                        Section("Recently read") { rows(history.articles) }
                    }
                } else if results.isEmpty && searched == trimmed {
                    Text("No titles match.").foregroundStyle(.secondary)
                } else {
                    rows(results)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Wikipedia")
            .navigationDestination(for: Library.Article.self) { article in
                ArticleView(library: library, article: article, history: history)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: trimmed) { await search(trimmed) }
        }
    }

    @ViewBuilder
    private func rows(_ articles: [Library.Article]) -> some View {
        ForEach(articles) { article in
            NavigationLink(value: article) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.title).font(.body.weight(.medium))
                    if let foundAs = article.foundAs {
                        Text("also: \(foundAs)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Runs off the main thread. SwiftUI cancels this task when the query changes, and a result
    /// that arrives for a query no longer on screen is dropped.
    private func search(_ text: String) async {
        guard !text.isEmpty else {
            results = []
            searched = ""
            return
        }
        let library = library
        let found = await Task.detached(priority: .userInitiated) { library.search(text, limit: 40) }.value
        guard !Task.isCancelled else { return }
        results = found
        searched = text
    }
}
