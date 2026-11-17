import SwiftUI

/// An article to show and how far down it to start: where the reader left off for a recently read
/// one, the top (0) for a search result.
struct Reading: Hashable {
    let article: Library.Article
    var position: Double = 0
}

/// The search field and its results; with an empty field it lists recently read articles instead,
/// each with how far it was read.
struct SearchView: View {
    let library: Library
    @EnvironmentObject private var history: History
    @State private var query = ""
    @State private var results: [Library.Article] = []
    @State private var searched = ""          // the query `results` belongs to
    @State private var stack: [Reading] = []
    @State private var started = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack(path: $stack) {
            List {
                if let problem = library.indexProblem {
                    Text(problem).foregroundStyle(.secondary)
                }
                if trimmed.isEmpty {
                    Button("Random article") {
                        if let article = library.randomArticle() { stack.append(Reading(article: article)) }
                    }
                    if !history.articles.isEmpty {
                        Section("Recently read") { rows(history.articles, recent: true) }
                    }
                } else if results.isEmpty && searched == trimmed {
                    Text("No titles match.").foregroundStyle(.secondary)
                } else {
                    rows(results, recent: false)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Wikipedia")
            .navigationDestination(for: Reading.self) { reading in
                ArticleView(library: library, article: reading.article, position: reading.position, history: history)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: trimmed) { await search(trimmed) }
        }
        // Open where the app was left: on the article being read, as far down it as the reader was.
        .onAppear {
            guard !started else { return }
            started = true
            if history.reading, let last = history.articles.first {
                stack = [Reading(article: last, position: history.position(of: last.path))]
            }
        }
        .onChange(of: stack) { history.reading = !$0.isEmpty }
    }

    /// `recent` rows open where the reader left the article, and say how far that is.
    @ViewBuilder
    private func rows(_ articles: [Library.Article], recent: Bool) -> some View {
        ForEach(articles) { article in
            let position = recent ? history.position(of: article.path) : 0
            NavigationLink(value: Reading(article: article, position: position)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.title).font(.body.weight(.medium))
                    if let foundAs = article.foundAs {
                        Text("also: \(foundAs)").font(.footnote).foregroundStyle(.secondary)
                    } else if Int(position * 100) >= 1 {
                        Text("\(Int(position * 100))% read").font(.footnote).foregroundStyle(.secondary)
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
