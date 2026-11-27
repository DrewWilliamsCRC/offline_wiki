import Foundation

/// What the app can download: each Wikipedia on offer and its title index, as `./wiki.sh publish`
/// lists them in catalog.json on the repository's "downloads" release. Wikipedia itself comes from
/// Kiwix; only the index and the list are kept on GitHub. The Android app reads the same file
/// (Catalog.kt).
struct Catalog: Codable {
    /// A Wikipedia and its index; `files` in the order to download them, the small index first.
    struct Book: Codable, Identifiable, Equatable {
        let id: String
        let title: String
        let about: String
        let files: [Remote]

        var size: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    /// One file to download, with what it must come to.
    struct Remote: Codable, Equatable {
        let name: String
        let url: URL
        let size: Int64
        let sha256: String
    }

    let format: Int
    let books: [Book]

    /// The same address as in the Android app (Catalog.URL) and in wiki.sh (PUBLISH_REPO, PUBLISH_TAG).
    static let url = URL(string: "https://github.com/DrewWilliamsCRC/offline_wiki/releases/download/downloads/catalog.json")!

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func fetch() async throws -> Catalog {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Problem(message: "the server answered \(status)") }
        return try parse(data)
    }

    /// Reads catalog.json. It comes over the network, so every file's name, address, size and
    /// checksum is checked here: a name is a plain file name for this app, nothing that could lead
    /// outside its folder.
    static func parse(_ data: Data) throws -> Catalog {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            throw Problem(message: "the list of downloads could not be read")
        }
        guard catalog.format == 1 else { throw Problem(message: "the list of downloads is for a newer Wiki Reader: update the app") }
        for book in catalog.books where !book.files.contains(where: { $0.name.hasSuffix(".zim") }) {
            throw Problem(message: "the list of downloads has no Wikipedia file for \(book.title)")
        }
        for file in catalog.books.flatMap(\.files) {
            let plain = file.name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*\.zim(\.idx)?$"#, options: .regularExpression) != nil
            let checksum = file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            guard plain, file.url.scheme == "https", file.size > 0, checksum else {
                throw Problem(message: "the list of downloads names a file this app cannot take: \(file.name)")
            }
        }
        return catalog
    }
}

/// A Kiwix file name, `<book>_<flavor>_<year>-<month>.zim`, taken apart: `book` is the size it is
/// ("wikipedia_en_all_nopic", as the catalog's ids are), `date` the snapshot ("2026-09").
struct Snapshot {
    let book: String
    let date: String

    init?(_ name: String) {
        guard let match = name.wholeMatch(of: /(.+)_([0-9]{4}-(0[1-9]|1[0-2]))\.zim/) else { return nil }
        book = String(match.1)
        date = String(match.2)
    }

    /// "September 2026".
    var month: String {
        let parts = date.split(separator: "-")
        let months = ["January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"]
        return "\(months[Int(parts[1])! - 1]) \(parts[0])"
    }
}
