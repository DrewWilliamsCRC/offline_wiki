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

    init() { reload() }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func reload() {
        var folders = [LibraryStore.documents]
        // For development: point a simulator build straight at a folder of test files on the Mac.
        if let override = ProcessInfo.processInfo.environment["WIKI_DIR"] { folders.insert(URL(fileURLWithPath: override), at: 0) }
        if chosenFolder == nil { chosenFolder = restoreChosenFolder() }
        if let chosenFolder { folders.append(chosenFolder) }

        let candidates = folders.flatMap(zimFiles).sorted { a, b in
            // Prefer a file that has its index; among those, the biggest (the fullest Wikipedia).
            if a.hasIndex != b.hasIndex { return a.hasIndex }
            return a.size > b.size
        }
        guard !candidates.isEmpty else {
            state = .missing("No Wikipedia file found yet.")
            return
        }
        var problem = ""
        for candidate in candidates {
            do {
                state = .ready(try Library(zim: candidate.url))
                return
            } catch {
                problem = "\(candidate.url.lastPathComponent) could not be opened: \(error)"
            }
        }
        state = .missing(problem)
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

/// The articles read most recently, newest first, kept across launches.
@MainActor
final class History: ObservableObject {
    @Published private(set) var articles: [Library.Article] = []
    private static let key = "recent"
    private static let limit = 40

    init() {
        if let data = UserDefaults.standard.data(forKey: History.key),
           let saved = try? JSONDecoder().decode([Library.Article].self, from: data) {
            articles = saved
        }
    }

    func add(path: String, title: String) {
        let kept = articles.filter { $0.path != path }.prefix(History.limit - 1)
        articles = [Library.Article(title: title, path: path)] + kept
        if let data = try? JSONEncoder().encode(articles) { UserDefaults.standard.set(data, forKey: History.key) }
    }
}
