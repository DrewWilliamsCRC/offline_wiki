import SwiftUI

/// The books in the `Catalog`, each with how much of it is here and a button to download it,
/// carry on, pause, or open it once it has arrived. The download itself runs in `Downloads`.
struct DownloadsView: View {
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: Catalog?
    @State private var problem: String?

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
        let (state, action) = describe(book)
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title).font(.headline)
            Text("\(book.about) \(Downloads.gb(book.size))").font(.subheadline).foregroundStyle(.secondary)
            Text(state).font(.subheadline)
        }
        .padding(.vertical, 2)
        if let action {
            Button(action) { act(action, book) }
                .accessibilityIdentifier("action-\(book.id)")
        }
    }

    /// What to say about `book`, and the button to offer, if any.
    private func describe(_ book: Catalog.Book) -> (String, String?) {
        let mine = downloads.book?.id == book.id
        let amount = "\(Downloads.gb(downloads.done)) of \(Downloads.gb(book.size))"
        if mine && downloads.running {
            return (downloads.doing.hasSuffix("%") ? downloads.doing : "\(downloads.doing): \(amount)", "Pause")
        }
        if downloads.complete(book) {
            // Open is for one that has just arrived and is not the one open already.
            let fresh = mine && downloads.doing == "Done" && !isOpen(book)
            return fresh ? ("Downloaded. It is ready to read.", "Open") : ("On this device.", nil)
        }
        if mine, let problem = downloads.problem { return (problem, "Try again") }
        let have = downloads.have(book)
        let paused = have > 0 ? "Paused: \(Downloads.gb(have)) of \(Downloads.gb(book.size)) is here." : "Not on this device."
        if downloads.running { return (paused, nil) } // one download at a time
        return (paused, have > 0 ? "Carry on" : "Download")
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
        default: downloads.start(book)
        }
    }
}
