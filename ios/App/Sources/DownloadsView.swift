import SwiftUI

/// The books in the `Catalog` (each size of Wikipedia on offer), each with how much of it is here
/// and what can be done: download it, pause, carry on, open it once it has arrived, update an older
/// snapshot of it, or delete it. The download itself runs in `Downloads`. The Android app's
/// DownloadScreen says and offers the same.
struct DownloadsView: View {
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: Catalog?
    @State private var problem: String?
    @State private var confirming: Confirming?

    /// A deletion waiting for the reader to say yes.
    private struct Confirming: Identifiable {
        let book: Catalog.Book
        let replace: Bool // delete the older snapshot, then download; otherwise delete the book
        var id: String { book.id }
    }

    /// What an entry says and offers at the moment.
    private struct Look {
        var state: String
        var first: String?
        var second: String?
    }

    var body: some View {
        List {
            Section {
                Text("Each one is Wikipedia, from Kiwix, and the index that makes its titles searchable. Downloads use Wi-Fi only, and carry on in the background.")
                    .foregroundStyle(.secondary)
            }
            if let catalog {
                ForEach(catalog.books) { book in
                    Section { entry(book) }
                }
            } else if let problem {
                Section {
                    Text("The list of downloads could not be fetched: \(problem.hasSuffix(".") ? problem : problem + ".")")
                    Button("Try again") { Task { await load() } }
                }
            } else {
                Text("Looking for what can be downloaded…").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task { await load() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { asked in
            Button(asked.replace ? "Replace" : "Delete", role: .destructive) { carryOut(asked) }
            Button("Keep", role: .cancel) {}
        } message: { asked in
            Text(confirmMessage(asked))
        }
    }

    private func load() async {
        problem = nil
        do {
            catalog = try await Catalog.fetch()
        } catch {
            problem = error.localizedDescription
        }
    }

    @ViewBuilder
    private func entry(_ book: Catalog.Book) -> some View {
        let look = look(book)
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title).font(.headline)
            Text("\(book.about) \(Downloads.gb(book.size))").font(.subheadline).foregroundStyle(.secondary)
            Text(look.state).font(.subheadline)
        }
        .padding(.vertical, 2)
        if let first = look.first {
            Button(first, role: first == "Delete" ? .destructive : nil) { act(first, book) }
                .accessibilityIdentifier("action-\(book.id)")
        }
        if let second = look.second {
            Button(second, role: second == "Delete" ? .destructive : nil) { act(second, book) }
                .accessibilityIdentifier("second-\(book.id)")
        }
    }

    private func look(_ book: Catalog.Book) -> Look {
        let mine = downloads.book?.id == book.id
        let snapshot = Downloads.snapshot(of: book)?.month ?? "the catalog's"
        let older = downloads.older(book).first.flatMap { Snapshot($0.lastPathComponent)?.month }
        let have = downloads.have(book)
        let amount = "\(Downloads.gb(have)) of \(Downloads.gb(book.size))"
        if mine && downloads.running {
            let progress = "\(Downloads.gb(downloads.done)) of \(Downloads.gb(book.size))"
            return Look(state: downloads.doing.hasSuffix("%") ? downloads.doing : "\(downloads.doing): \(progress)", first: "Pause")
        }
        if downloads.complete(book) {
            // Open is for one that has just arrived and is not the one open already.
            if mine && downloads.doing == "Done" && !isOpen(book) {
                return Look(state: "Downloaded. It is ready to read.", first: "Open")
            }
            return Look(state: "On this device: \(snapshot).", first: downloads.running ? nil : "Delete")
        }
        if mine, let problem = downloads.problem {
            return Look(state: problem, first: "Try again", second: older != nil ? "Delete" : nil)
        }
        if downloads.running { // one download at a time
            return Look(state: have > 0 ? "Paused: \(amount) is here." : older.map { "On this device: \($0)." } ?? "Not on this device.")
        }
        if have > 0 { return Look(state: "Paused: \(amount) is here.", first: "Carry on", second: "Delete") }
        if let older {
            let replace = !downloads.roomFor(book) && downloads.roomIfReplaced(book)
            return Look(state: "On this device: \(older). A newer copy, from \(snapshot), can be downloaded.",
                        first: replace ? "Replace" : "Update", second: "Delete")
        }
        return Look(state: "Not on this device.", first: "Download")
    }

    private func isOpen(_ book: Catalog.Book) -> Bool {
        guard case .ready(let library) = store.state else { return false }
        return book.files.contains { $0.name == library.fileName }
    }

    private func act(_ action: String, _ book: Catalog.Book) {
        switch action {
        case "Pause": downloads.pause()
        case "Open":
            store.reload()
            dismiss()
        case "Delete": confirming = Confirming(book: book, replace: false)
        case "Replace": confirming = Confirming(book: book, replace: true)
        default: downloads.start(book) // Download, Update, Carry on, Try again
        }
    }

    private var confirmTitle: String {
        confirming?.replace == true ? "Replace the older copy?" : "Delete this Wikipedia?"
    }

    private func confirmMessage(_ asked: Confirming) -> String {
        if asked.replace {
            let older = downloads.older(asked.book).first.flatMap { Snapshot($0.lastPathComponent)?.month } ?? "older"
            return "There is not room for both copies, so the \(older) one is deleted first: until the download finishes there is no copy of it to read."
        }
        return "\(asked.book.title) is deleted from this device. It can be downloaded again."
    }

    /// Lets go of the files first if they are the ones open: a deleted file that is still open keeps its space.
    private func carryOut(_ asked: Confirming) {
        if asked.replace {
            store.letGo(of: Set(downloads.older(asked.book).flatMap { [$0.lastPathComponent, $0.lastPathComponent + ".idx"] }))
            downloads.deleteOlder(asked.book)
            store.reload()
            downloads.start(asked.book)
        } else {
            store.letGo(of: Set(downloads.files(of: asked.book).map(\.lastPathComponent)))
            downloads.delete(asked.book)
            store.reload()
        }
    }
}
