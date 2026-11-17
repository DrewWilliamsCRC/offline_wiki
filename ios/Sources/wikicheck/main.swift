import Foundation
import WikiCore

// Compares the Swift port with the Kotlin implementation in reader/. `search`, `cat` and `sections`
// print in the same form as the Kotlin indexer's commands, so their outputs can be diffed directly.

let usage = """
    usage:
      search <file.zim> <words>     what the app would list for a query
      cat <file.zim> <path>         an item's content (follows redirects)
      sections <file.zim> <path>    an article's section headings: level, id and title, tab-separated
      normalize <file.zim> [step]   re-derive the index's normalized titles; every <step>th record
      bench <file.zim> <words>      time a search over 200 runs
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail(usage) }
let zimURL = URL(fileURLWithPath: args[1])

do {
    let zim = try ZimFile(url: zimURL)
    func index() throws -> TitleIndex {
        let index = try TitleIndex(url: TitleIndex.file(for: zimURL))
        guard index.zimUuid == zim.uuid else { fail("the index was built for a different file") }
        return index
    }

    switch args[0] {
    case "search":
        let index = try index()
        for hit in index.search(args.dropFirst(2).joined(separator: " "), limit: 20) {
            let title = try zim.entry(hit.entryIndex).title
            print(hit.entryIndex == hit.targetIndex ? title : "\(title)  ->  \(try zim.entry(hit.targetIndex).title)")
        }

    case "cat":
        guard args.count >= 3, let entry = try zim.find(namespace: "C", path: args[2]) else { fail("not found") }
        FileHandle.standardOutput.write(try zim.content(zim.resolve(entry)))

    case "sections":
        guard args.count >= 3, let entry = try zim.find(namespace: "C", path: args[2]) else { fail("not found") }
        for section in ArticleSections.parse(try zim.content(zim.resolve(entry))) {
            print("\(section.level)\t\(section.id)\t\(section.title)")
        }

    case "normalize":
        let index = try index()
        let step = args.count >= 3 ? max(1, Int(args[2]) ?? 1) : 1
        var checked = 0
        var different = 0
        for record in stride(from: 0, to: index.recordCount, by: step) {
            let title = try zim.entry(index.entryIndex(record)).title
            let mine = Array(SearchText.normalize(title).utf8)
            let theirs = index.normalizedTitle(record)
            checked += 1
            if mine != theirs {
                different += 1
                if different <= 20 {
                    print("differs: \(title.debugDescription)  swift=\(String(decoding: mine, as: UTF8.self).debugDescription)  index=\(String(decoding: theirs, as: UTF8.self).debugDescription)")
                }
            }
        }
        print("\(checked) titles checked, \(different) normalized differently")

    case "bench":
        let index = try index()
        let query = args.dropFirst(2).joined(separator: " ")
        var count = 0
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 { count = index.search(query, limit: 40).count }
        let micros = (DispatchTime.now().uptimeNanoseconds - started) / 200 / 1000
        print("\(count) results, \(micros) µs per search")

    default:
        fail(usage)
    }
} catch {
    fail("error: \(error)")
}
