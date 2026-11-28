import Foundation
import WikiCore

/// The Wikipedia file and, if it can be used, the title index built for it.
/// Used from background queues as well as the main thread; the readers underneath allow that.
///
/// The files are kept open only while the app is in front. An open file keeps its space on the
/// device even after it is deleted, so a reader that held on to Wikipedia in the background would
/// leave no room to copy a newer one in its place. `release` lets go when the app leaves the
/// screen and `hold` takes hold again when it returns; anything read in between opens the files
/// for just that read.
final class Library {
    /// An article the reader can open. `foundAs` is the other name that matched, when it was not the title.
    struct Article: Hashable, Identifiable, Codable {
        let title: String
        let path: String
        var foundAs: String?

        var id: String { path + "\u{0}" + (foundAs ?? "") }
    }

    struct Item {
        let mimeType: String
        let data: Data
    }

    /// The two files, open. They close when the last reference to this goes, so a read that is
    /// under way when the library lets go simply finishes first.
    private final class Files {
        let zim: ZimFile
        let index: TitleIndex?
        let indexProblem: String?

        init(zim url: URL) throws {
            let zim = try ZimFile(url: url)
            let indexURL = TitleIndex.file(for: url)
            var index: TitleIndex?
            var problem: String?
            if !FileManager.default.fileExists(atPath: indexURL.path) {
                problem = "No search index was found next to \(url.lastPathComponent). Copy its .zim.idx file into the same folder."
            } else {
                do {
                    let candidate = try TitleIndex(url: indexURL)
                    // An index built for another file would mislead, so it has to carry this file's id.
                    if candidate.zimUuid == zim.uuid {
                        index = candidate
                    } else {
                        problem = "Titles cannot be searched: \(indexURL.lastPathComponent) was built for a different Wikipedia file. Copy the index that belongs to this one."
                    }
                } catch {
                    problem = "Titles cannot be searched: \(error)."
                }
            }
            self.zim = zim
            self.index = index
            indexProblem = problem
        }
    }

    let url: URL
    let fileName: String
    /// Tells one state of the files from another: see `LibraryStore.stamp`.
    let stamp: String

    private let lock = NSLock()
    private var files: Files?           // kept between reads only while `held`
    private var held = true
    private var problem: String?

    init(zim url: URL, stamp: String) throws {
        self.url = url
        self.stamp = stamp
        fileName = url.lastPathComponent
        // Opened here, so that a file that cannot be opened is reported here.
        let opened = try Files(zim: url)
        files = opened
        problem = opened.indexProblem
    }

    private func open() throws -> Files {
        try lock.withLock {
            if let files { return files }
            let opened = try Files(zim: url)
            problem = opened.indexProblem
            if held { files = opened }
            return opened
        }
    }

    /// Why titles cannot be searched, in words for the reader; nil when they can.
    var indexProblem: String? { lock.withLock { problem } }

    /// Keeps the files open between reads from now on.
    func hold() { lock.withLock { held = true } }

    /// Closes the files as soon as nothing is reading them.
    func release() {
        lock.withLock {
            held = false
            files = nil
        }
    }

    func search(_ query: String, limit: Int) -> [Article] {
        guard let files = try? open(), let index = files.index else { return [] }
        return index.search(query, limit: limit).compactMap { article($0, in: files.zim) }
    }

    private func article(_ hit: TitleIndex.Hit, in zim: ZimFile) -> Article? {
        guard let target = try? zim.entry(hit.targetIndex) else { return nil }
        if hit.entryIndex == hit.targetIndex { return Article(title: target.title, path: target.path) }
        return Article(title: target.title, path: target.path, foundAs: (try? zim.entry(hit.entryIndex))?.title)
    }

    func randomArticle() -> Article? {
        guard let files = try? open(), let hit = files.index?.randomArticle() else { return nil }
        return article(hit, in: files.zim)
    }

    /// The language of this copy, from its file's name (`wikipedia_en_...`); nil if the name says none.
    var language: String? {
        let parts = fileName.split(separator: "_")
        guard parts.count >= 2, parts[0] == "wikipedia", parts[1].allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        return String(parts[1])
    }

    /// The article at `path` with redirects followed, and the other name it was asked for by, if
    /// it was one; nil if this copy lacks it. Wikipedia's addresses may start with a small letter
    /// where its titles have a capital, so that is tried too.
    func article(at path: String) -> Article? {
        guard let zim = try? open().zim else { return nil }
        let capital = path.prefix(1).uppercased() + path.dropFirst()
        for candidate in [path, capital] {
            guard let entry = try? zim.find(namespace: "C", path: candidate), let target = try? zim.resolve(entry) else { continue }
            return Article(title: target.title, path: target.path, foundAs: target.index == entry.index ? nil : entry.title)
        }
        return nil
    }

    /// Where an article path really leads once redirects are followed; nil if this copy lacks it.
    func resolvePath(_ path: String) -> String? {
        guard let zim = try? open().zim, let entry = try? zim.find(namespace: "C", path: path) else { return nil }
        return (try? zim.resolve(entry))?.path
    }

    /// An article or one of its stylesheets, by path.
    func item(_ path: String) throws -> Item? {
        let zim = try open().zim
        guard let entry = try zim.find(namespace: "C", path: path) else { return nil }
        let resolved = try zim.resolve(entry)
        return Item(mimeType: zim.mimeType(resolved), data: try zim.content(resolved))
    }
}
