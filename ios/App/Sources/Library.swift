import Foundation
import WikiCore

/// The opened Wikipedia file and, if it is there, the title index built for it.
/// Used from background queues as well as the main thread; the readers underneath allow that.
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

    let fileName: String
    private let zim: ZimFile
    private let index: TitleIndex?

    var hasIndex: Bool { index != nil }

    init(zim url: URL) throws {
        zim = try ZimFile(url: url)
        fileName = url.lastPathComponent
        // An index built for another file would mislead, so it has to carry this file's id.
        if let candidate = try? TitleIndex(url: TitleIndex.file(for: url)), candidate.zimUuid == zim.uuid {
            index = candidate
        } else {
            index = nil
        }
    }

    func search(_ query: String, limit: Int) -> [Article] {
        (index?.search(query, limit: limit) ?? []).compactMap(article)
    }

    private func article(_ hit: TitleIndex.Hit) -> Article? {
        guard let target = try? zim.entry(hit.targetIndex) else { return nil }
        if hit.entryIndex == hit.targetIndex { return Article(title: target.title, path: target.path) }
        return Article(title: target.title, path: target.path, foundAs: (try? zim.entry(hit.entryIndex))?.title)
    }

    func randomArticle() -> Article? { index?.randomArticle().flatMap(article) }

    /// Where an article path really leads once redirects are followed; nil if this copy lacks it.
    func resolvePath(_ path: String) -> String? {
        guard let entry = try? zim.find(namespace: "C", path: path) else { return nil }
        return (try? zim.resolve(entry))?.path
    }

    /// An article or one of its stylesheets, by path.
    func item(_ path: String) throws -> Item? {
        guard let entry = try zim.find(namespace: "C", path: path) else { return nil }
        let resolved = try zim.resolve(entry)
        return Item(mimeType: zim.mimeType(resolved), data: try zim.content(resolved))
    }
}
