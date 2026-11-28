import Foundation
import SwiftUI

/// What another app, a shortcut or a link on the web can ask Wiki Reader to show, through its own
/// addresses:
///   wikireader://article/<path>            an article, by its path in the file (`Capital_city`)
///   wikireader://search?q=<words>          the search screen with those words in its field
///   wikireader://open?url=<address>        the article at a wikipedia.org address
/// What comes in is untrusted: only a path or words are taken from it, never an address to load.
enum Link: Equatable {
    case article(String)
    case search(String)
    case wikipedia(language: String, path: String)

    static let scheme = "wikireader"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Link.scheme else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch url.host?.lowercased() {
        case "article":
            let path = String(url.path.dropFirst()) // percent-decoded
            guard !path.isEmpty else { return nil }
            self = .article(path)
        case "search":
            self = .search(item("q") ?? "")
        case "open":
            guard let address = item("url").flatMap(URL.init(string:)), let page = Link.page(address) else { return nil }
            self = .wikipedia(language: page.language, path: page.path)
        default:
            return nil
        }
    }

    /// The language and article path of a wikipedia.org address, as pasted or shared:
    /// `https://en.wikipedia.org/wiki/Capital_city`, the mobile site's `en.m.wikipedia.org`, or
    /// `/w/index.php?title=...`. Nil for anything else.
    static func page(_ url: URL) -> (language: String, path: String)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), host.hasSuffix(".wikipedia.org") else { return nil }
        let labels = host.dropLast(".wikipedia.org".count).split(separator: ".")
        guard let language = labels.first, labels.count == 1 || (labels.count == 2 && labels[1] == "m"),
              language.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        var path: String
        if url.path.hasPrefix("/wiki/") {
            path = String(url.path.dropFirst("/wiki/".count)) // percent-decoded
        } else if url.path == "/w/index.php",
                  let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "title" })?.value {
            path = title
        } else {
            return nil
        }
        // Addresses spell spaces as underscores, as the paths in the file do.
        path = path.replacingOccurrences(of: " ", with: "_")
        guard !path.isEmpty else { return nil }
        return (String(language), path)
    }

    /// Reads a wikipedia.org address typed or pasted into the search field. A pasted address can
    /// carry spaces or stray characters that `URL` refuses, so it is cleaned a little first.
    static func page(typed text: String) -> (language: String, path: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().contains("wikipedia.org/") else { return nil }
        let full = trimmed.lowercased().hasPrefix("http") ? trimmed : "https://" + trimmed
        // Before iOS 17, URL(string:) refuses letters outside ASCII ("Zürich"), which an address
        // copied from a page's text can hold. They are percent-encoded here; what is encoded
        // already, and the marks an address is made of, are left as they are.
        let allowed = CharacterSet.urlFragmentAllowed.union(CharacterSet(charactersIn: "%#"))
        let spaced = full.replacingOccurrences(of: " ", with: "_")
        return URL(string: spaced.addingPercentEncoding(withAllowedCharacters: allowed) ?? spaced).flatMap(page)
    }

    /// The name of a language for the reader ("French" for `fr`), or its code if there is none.
    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

/// Requests from outside waiting for the search screen, which acts on them and clears them. One
/// that arrives before there is a Wikipedia to show waits until there is.
@MainActor
final class Requests: ObservableObject {
    @Published var pending: Link?
}
