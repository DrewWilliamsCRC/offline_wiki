import Foundation
import SwiftUI

/// Finds and opens the Wikipedia file, and remembers a folder the user pointed the app at.
///
/// Files are looked for in the app's own Documents folder (filled over USB from the Finder, or in
/// the Files app under "On My iPhone") and in one chosen folder, which may be on an external drive.
@MainActor
final class LibraryStore: ObservableObject {
    enum State {
        case missing(String)
        case ready(Library)
    }

    @Published private(set) var state: State = .missing("")
    private var chosenFolder: URL? // kept so its security scope stays open while files are in use

    private var library: Library? {
        if case .ready(let library) = state { return library }
        return nil
    }

    init() { reload() }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Looks for the Wikipedia file again and takes hold of it. Called at launch and whenever the
    /// app comes to the front, since that is when files have been added, replaced or removed. If
    /// they are the ones already in use, nothing changes and the reader stays where it was.
    func reload() {
        LibraryStore.keepOutOfBackups(in: LibraryStore.documents)
        var folders = [LibraryStore.documents]
        // For development: point a simulator build straight at a folder of test files on the Mac.
        if let override = ProcessInfo.processInfo.environment["WIKI_DIR"] { folders.insert(URL(fileURLWithPath: override), at: 0) }
        if chosenFolder == nil { chosenFolder = restoreChosenFolder() }
        if let chosenFolder { folders.append(chosenFolder) }

        // Prefer files that have their index. Of each book only its newest snapshot counts, so that
        // an older copy left beside an update is not read instead, even when it is bigger. Of what
        // is left, the biggest first: the fullest Wikipedia.
        let all = folders.flatMap(zimFiles)
        let indexed = all.contains(where: \.hasIndex) ? all.filter(\.hasIndex) : all
        let newest = Dictionary(grouping: indexed) { Snapshot($0.url.lastPathComponent)?.book ?? $0.url.lastPathComponent }
            .values.compactMap { $0.max { (Snapshot($0.url.lastPathComponent)?.date ?? "") < (Snapshot($1.url.lastPathComponent)?.date ?? "") } }
        let candidates = newest.sorted { $0.size > $1.size }
        if let library, let first = candidates.first, library.stamp == LibraryStore.stamp(of: first.url) {
            library.hold()
            return
        }
        library?.release()
        guard !candidates.isEmpty else {
            state = .missing("No Wikipedia file found yet.")
            return
        }
        var problem = ""
        for candidate in candidates {
            do {
                state = .ready(try Library(zim: candidate.url, stamp: LibraryStore.stamp(of: candidate.url)))
                return
            } catch {
                problem = "\(candidate.url.lastPathComponent) could not be opened: \(error)"
            }
        }
        state = .missing(problem)
    }

    /// Marks Wikipedia and its index in `folder` as not to be backed up. iOS backs up Documents to
    /// iCloud and to a computer by default, and a 53 GB file that can be downloaded again would use
    /// the reader's iCloud storage, or make the backup fail for want of it. Done each time the files
    /// are looked for, so that files dragged in from the Finder, or replaced, are marked too. A
    /// folder the reader chose is theirs, and left alone. The mark is an extended attribute: it
    /// changes neither the size nor the date that `stamp` reads.
    nonisolated static func keepOutOfBackups(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".zim") || name.hasSuffix(".zim.idx") {
            keepOutOfBackups(folder.appendingPathComponent(name))
        }
    }

    nonisolated static func keepOutOfBackups(_ url: URL) {
        var url = url
        guard (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Lets go of the files while the app is out of sight, so that they can be replaced: a
    /// deleted file that is still open goes on taking up its space.
    func suspend() { library?.release() }

    /// Before files are deleted from the downloads screen: closes the Wikipedia open now if it is
    /// among them. `reload` afterwards opens whatever is left.
    func letGo(of names: Set<String>) {
        guard let library, names.contains(library.fileName) || names.contains(library.fileName + ".idx") else { return }
        library.release()
        state = .missing("")
    }

    private func zimFiles(in folder: URL) -> [(url: URL, size: Int, hasIndex: Bool)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return contents.filter { $0.pathExtension == "zim" }.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let hasIndex = FileManager.default.fileExists(atPath: url.path + ".idx")
            return (url, size, hasIndex)
        }
    }

    /// Tells one state of the files from another: which file, and the size and date of it and of
    /// its index.
    private static func stamp(of zim: URL) -> String {
        [zim.path, zim.path + ".idx"].map { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(path):\(size):\(date)"
        }.joined(separator: "|")
    }

    // MARK: A folder outside the app

    private static let bookmarkKey = "chosenFolder"

    /// Called with the folder picked in the system file browser.
    func choose(folder: URL) {
        chosenFolder?.stopAccessingSecurityScopedResource()
        _ = folder.startAccessingSecurityScopedResource()
        chosenFolder = folder
        if let bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: LibraryStore.bookmarkKey)
        }
        reload()
    }

    private func restoreChosenFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: LibraryStore.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}

/// The articles read most recently, newest first, with how far down each one the reader was, and
/// whether an article was on screen when the app was last seen; and the articles the reader saved
/// to come back to. Kept across launches, so the app can open where it was left.
@MainActor
final class History: ObservableObject {
    @Published private(set) var articles: [Library.Article] = []
    /// Saved by the reader, newest first. Unlike the recent ones they stay until removed, and so does
    /// how far each was read, after the article has left the recent ones.
    @Published private(set) var saved: [Library.Article] = []
    /// By path: 0 at an article's top, 1 at its end. Not published: it changes with every scroll.
    private var positions: [String: Double] = [:]
    private var saving: DispatchWorkItem?
    private static let key = "recent"
    private static let positionsKey = "positions"
    private static let readingKey = "reading"
    private static let limit = 40

    /// The saved list, in a file of its own rather than with the settings: it has no limit.
    private static var savedFile: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("saved.json")
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: History.key),
           let list = try? JSONDecoder().decode([Library.Article].self, from: data) {
            articles = list
        }
        if let data = try? Data(contentsOf: History.savedFile),
           let list = try? JSONDecoder().decode([Library.Article].self, from: data) {
            saved = list
        }
        if let kept = UserDefaults.standard.dictionary(forKey: History.positionsKey) as? [String: Double] {
            positions = kept
        }
    }

    /// Puts an article at the top of the list. One that was there keeps how far it was read.
    func add(path: String, title: String) {
        if let first = articles.first, first.path == path, first.title == title { return }
        let kept = articles.filter { $0.path != path }.prefix(History.limit - 1)
        articles = [Library.Article(title: title, path: path)] + kept
        storeRecent()
    }

    /// Takes an article off the recently read list, and forgets how far it was read unless it is saved.
    func forget(path: String) {
        articles.removeAll { $0.path == path }
        storeRecent()
        save()
    }

    /// Empties the recently read list. Saved articles keep their places.
    func forgetAll() {
        articles = []
        storeRecent()
        save()
    }

    func isSaved(_ path: String) -> Bool { saved.contains { $0.path == path } }

    /// Puts an article at the top of the saved list.
    func addSaved(_ article: Library.Article) {
        saved = [Library.Article(title: article.title, path: article.path)] + saved.filter { $0.path != article.path }
        storeSaved()
    }

    /// Takes an article off the saved list, and forgets how far it was read unless it is a recent one.
    func removeSaved(path: String) {
        saved.removeAll { $0.path == path }
        storeSaved()
        save()
    }

    func position(of path: String) -> Double { positions[path] ?? 0 }

    /// Notes how far an article in either list has been read. Kept a moment later, or at `save`.
    func setPosition(_ position: Double, of path: String) {
        guard positions[path] != position, articles.contains(where: { $0.path == path }) || isSaved(path) else { return }
        positions[path] = position
        saving?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Keeps the reading places, of the articles in either list only.
    func save() {
        saving?.cancel()
        saving = nil
        let listed = Set(articles.map(\.path)).union(saved.map(\.path))
        positions = positions.filter { listed.contains($0.key) }
        UserDefaults.standard.set(positions, forKey: History.positionsKey)
    }

    private func storeRecent() {
        if let data = try? JSONEncoder().encode(articles) { UserDefaults.standard.set(data, forKey: History.key) }
    }

    private func storeSaved() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: History.savedFile, options: .atomic) }
    }

    /// Whether an article, rather than the search screen, was showing when the app was last seen.
    var reading: Bool {
        get { UserDefaults.standard.bool(forKey: History.readingKey) }
        set { if newValue != reading { UserDefaults.standard.set(newValue, forKey: History.readingKey) } }
    }
}
