import SwiftUI

/// An article to show and how far down it to start: where the reader left off for a recently read
/// one, the top (0) for a search result.
struct Reading: Hashable {
    let article: Library.Article
    var position: Double = 0
}

/// The search field and its results. With an empty field it lists instead the articles the reader
/// saved and those read recently, each with how far it was read; a row is removed by swiping it,
/// and the recent ones can be cleared all at once.
struct SearchView: View {
    let library: Library
    @EnvironmentObject private var history: History
    @State private var query = ""
    @State private var results: [Library.Article] = []
    @State private var searched = ""          // the query `results` belongs to
    @State private var stack: [Reading] = []
    @State private var started = false
    @State private var confirmingClear = false
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var requests: Requests
    /// Said in place of "No titles match." when the search was a wikipedia.org address.
    @State private var note: String?

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
                    if !history.saved.isEmpty {
                        Section("Saved") {
                            rows(history.saved, withPlace: true) { history.removeSaved(path: $0.path) }
                        }
                    }
                    if !history.articles.isEmpty {
                        Section {
                            rows(history.articles, withPlace: true) { history.forget(path: $0.path) }
                        } header: {
                            HStack {
                                Text("Recently read")
                                Spacer()
                                Button("Clear") { confirmingClear = true }
                            }
                        }
                    }
                } else if results.isEmpty && searched == trimmed {
                    Text(note ?? "No titles match.").foregroundStyle(.secondary)
                } else {
                    rows(results, withPlace: false)
                }
            }
            .listStyle(.plain)
            .confirmationDialog("Clear the list of recently read articles?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear the List", role: .destructive) { history.forgetAll() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Saved articles stay saved, with how far each was read.")
            }
            .safeAreaInset(edge: .bottom) { age }
            .navigationTitle("Wikipedia")
            .navigationDestination(for: Reading.self) { reading in
                ArticleView(library: library, article: reading.article, position: reading.position, history: history)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: trimmed) { await search(trimmed) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { downloads.showing = true } label: { Label("Downloads", systemImage: "arrow.down.circle") }
                }
            }
        }
        // Open where the app was left: on the article being read, as far down it as the reader was.
        .onAppear {
            if !started {
                started = true
                if history.reading, let last = history.articles.first {
                    stack = [Reading(article: last, position: history.position(of: last.path))]
                }
            }
            takeRequest() // one that came before there was a Wikipedia to show
        }
        .onChange(of: stack) { history.reading = !$0.isEmpty }
        .onChange(of: requests.pending) { _ in takeRequest() }
    }

    private func takeRequest() {
        guard let link = requests.pending else { return }
        requests.pending = nil
        act(on: link)
    }

    /// Shows what was asked for from outside the app, in place of whatever was on screen.
    private func act(on link: Link) {
        switch link {
        case .article(let path):
            // An article this copy lacks still opens, to the page that says so.
            stack = [Reading(article: library.article(at: path) ?? Library.Article(title: path, path: path))]
        case .search(let words):
            stack = []
            query = words
        case .wikipedia(let language, let path):
            if let mine = library.language, mine != language {
                stack = []
                query = "https://\(language).wikipedia.org/wiki/\(path)" // the search says why it cannot open
            } else {
                act(on: .article(path))
            }
        }
    }

    /// When this copy of Wikipedia was made, from its file's name: no network is needed to say so,
    /// and the app looks for newer ones only when asked, on the downloads screen. Past six months
    /// it says a newer copy may be out, and leads there. With more than one copy on the device it
    /// also says which this is, and leads to where another can be chosen. Nothing for a file named
    /// otherwise.
    @ViewBuilder
    private var age: some View {
        if trimmed.isEmpty, let snapshot = Snapshot(library.fileName) {
            let several = store.books.count > 1
            let which = several ? Snapshot.kind(of: snapshot.book).map { ": \($0)" } ?? "" : ""
            Group {
                if SearchView.monthsOld(snapshot) > 6 {
                    Button("Wikipedia as of \(snapshot.month)\(which). A newer copy may be out: see Downloads.") { downloads.showing = true }
                } else if several {
                    Button("Wikipedia as of \(snapshot.month)\(which). Another copy can be chosen in Downloads.") { downloads.showing = true }
                } else {
                    Text("Wikipedia as of \(snapshot.month)").foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(.bar)
        }
    }

    private static func monthsOld(_ snapshot: Snapshot) -> Int {
        let parts = snapshot.date.split(separator: "-").compactMap { Int($0) }
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        guard parts.count == 2, let year = now.year, let month = now.month else { return 0 }
        return (year * 12 + month) - (parts[0] * 12 + parts[1])
    }

    /// `withPlace` rows open where the reader left the article, and say how far that is. Rows with
    /// `remove` can be swiped away.
    @ViewBuilder
    private func rows(_ articles: [Library.Article], withPlace: Bool, remove: ((Library.Article) -> Void)? = nil) -> some View {
        ForEach(articles) { article in
            let position = withPlace ? history.position(of: article.path) : 0
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
            .swipeActions {
                if let remove {
                    Button(role: .destructive) { remove(article) } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
    }

    /// Runs off the main thread. SwiftUI cancels this task when the query changes, and a result
    /// that arrives for a query no longer on screen is dropped.
    private func search(_ text: String) async {
        note = nil
        guard !text.isEmpty else {
            results = []
            searched = ""
            return
        }
        let library = library
        // A wikipedia.org address leads to its article, if this copy has it and is in its language.
        if let page = Link.page(typed: text) {
            let found = await Task.detached(priority: .userInitiated) { library.article(at: page.path) }.value
            guard !Task.isCancelled else { return }
            if let mine = library.language, mine != page.language {
                note = "That address is for the \(Link.languageName(page.language)) Wikipedia; this copy is the \(Link.languageName(mine)) one."
                results = []
            } else {
                note = found == nil ? "That article is not in this copy of Wikipedia." : nil
                results = found.map { [$0] } ?? []
            }
            searched = text
            return
        }
        let found = await Task.detached(priority: .userInitiated) { library.search(text, limit: 40) }.value
        guard !Task.isCancelled else { return }
        results = found
        searched = text
    }
}
