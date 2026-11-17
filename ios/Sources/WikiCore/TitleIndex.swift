import Foundation

/// The purpose-built title index that sits next to a ZIM file (`<name>.zim.idx`).
///
/// This is the Swift reader for the format written by `IndexBuilder` and documented at the top of
/// `TitleIndex.kt` in reader/core. The search below follows the Kotlin one step for step, so both
/// apps return the same results in the same order for the same index.
///
/// File layout (little-endian):
///   header      96 bytes: "WRIX", version, ZIM uuid, record count N, inner-word count M, section positions
///   offsets     (N + 1) x u32: where each record starts in the blob; the last is the blob's size
///   blob        per record: u32 ZIM entry index, u32 target entry index (itself unless a redirect),
///               then the normalized title in UTF-8
///   inner       M x 5 bytes: u32 record number, u8 byte offset of a word inside that record's title;
///               sorted by the title text from that word onward
///   title ranks one byte per record, then the maximum of every 256, then of every 65536
///   inner ranks the same for the inner list (each entry carries its record's rank)
public final class TitleIndex {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)

        public var description: String {
            switch self {
            case .unreadable(let m): return m
            }
        }
    }

    /// A search result: the title that matched and the entry it leads to.
    public struct Hit: Equatable {
        public let entryIndex: Int
        public let targetIndex: Int
    }

    public let zimUuid: [UInt8]
    public let recordCount: Int
    public let innerCount: Int

    private let base: UnsafeRawPointer
    private let mappedSize: Int
    private let offsets: UnsafeRawPointer
    private let blob: UnsafeRawPointer
    private let inner: UnsafeRawPointer
    private let titleRanks: Ranks
    private let innerRanks: Ranks

    public init(url: URL) throws {
        let name = url.lastPathComponent
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Failure.unreadable("cannot open \(name): \(String(cString: strerror(errno)))") }
        defer { close(fd) } // the mapping outlives the descriptor
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= TitleIndex.headerSize else { throw Failure.unreadable("\(name) is not a title index") }
        let size = Int(info.st_size)
        guard let map = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), map != MAP_FAILED else {
            throw Failure.unreadable("cannot map \(name): \(String(cString: strerror(errno)))")
        }
        let start = UnsafeRawPointer(map)
        func u32(_ at: Int) -> UInt32 { start.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian }
        // A position or length in the header, or the file's size if it is too large to be either,
        // which the check below then refuses.
        func u64(_ at: Int) -> Int { Int(exactly: start.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian) ?? size }
        guard u32(0) == TitleIndex.magic else {
            munmap(map, size)
            throw Failure.unreadable("\(name) is not a title index")
        }
        guard u32(4) == TitleIndex.version else {
            let found = u32(4)
            munmap(map, size)
            // Which side is behind decides what to do about it.
            throw Failure.unreadable(found > TitleIndex.version
                ? "\(name) is a newer kind of index (version \(found)) than this reader knows (version \(TitleIndex.version)); install the newer reader"
                : "\(name) is an older kind of index (version \(found)) than this reader needs (version \(TitleIndex.version)); build it again")
        }
        let records = Int(u32(24))
        let inners = Int(u32(28))
        // A copy that stopped part-way has the header of a whole index and less than all of it.
        let sections = [(u64(32), 4 * (records + 1)), (u64(40), u64(48)), (u64(56), TitleIndex.innerSize * inners),
                        (u64(64), Ranks.size(records)), (u64(72), Ranks.size(inners))]
        guard sections.allSatisfy({ $0.0 <= size && $0.1 <= size - $0.0 }) else {
            munmap(map, size)
            throw Failure.unreadable("\(name) is cut short; copy it again")
        }
        base = start
        mappedSize = size
        zimUuid = Array(UnsafeRawBufferPointer(start: start + 8, count: 16))
        recordCount = records
        innerCount = inners
        offsets = start + u64(32)
        blob = start + u64(40)
        inner = start + u64(56)
        titleRanks = Ranks(data: start + u64(64), count: records)
        innerRanks = Ranks(data: start + u64(72), count: inners)
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), mappedSize) }

    private func recordStart(_ record: Int) -> Int {
        Int(offsets.loadUnaligned(fromByteOffset: record * 4, as: UInt32.self).littleEndian)
    }

    private func titleStart(_ record: Int) -> Int { recordStart(record) + TitleIndex.recordHeader }
    private func titleEnd(_ record: Int) -> Int { recordStart(record + 1) }

    private func hit(_ record: Int) -> Hit {
        let at = recordStart(record)
        return Hit(
            entryIndex: Int(blob.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian),
            targetIndex: Int(blob.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self).littleEndian)
        )
    }

    /// The normalized title stored for a record. For checking this port against the index's builder.
    public func normalizedTitle(_ record: Int) -> [UInt8] {
        Array(UnsafeRawBufferPointer(start: blob + titleStart(record), count: titleEnd(record) - titleStart(record)))
    }

    /// The ZIM entry a record was made from.
    public func entryIndex(_ record: Int) -> Int { hit(record).entryIndex }

    private func byte(_ at: Int) -> UInt8 { blob.load(fromByteOffset: at, as: UInt8.self) }

    /// Compares the text of `record` from byte `from` with `query`.
    /// Negative: the text sorts before the query. Zero: the text starts with the query. Positive: after.
    private func comparePrefix(_ record: Int, _ from: Int, _ query: [UInt8]) -> Int {
        var p = titleStart(record) + from
        let end = titleEnd(record)
        for q in query {
            if p >= end { return -1 }
            let d = Int(byte(p)) - Int(q)
            p += 1
            if d != 0 { return d }
        }
        return 0
    }

    /// First position in [0, count) whose text is not before `query`; `after` moves past matches too.
    private func bound(_ count: Int, _ query: [UInt8], after: Bool, _ compare: (Int, [UInt8]) -> Int) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let c = compare(mid, query)
            if c < 0 || (after && c == 0) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func compareTitle(_ record: Int, _ query: [UInt8]) -> Int { comparePrefix(record, 0, query) }

    private func innerRecord(_ i: Int) -> Int {
        Int(inner.loadUnaligned(fromByteOffset: i * TitleIndex.innerSize, as: UInt32.self).littleEndian)
    }

    private func compareInner(_ i: Int, _ query: [UInt8]) -> Int {
        comparePrefix(innerRecord(i), Int(inner.load(fromByteOffset: i * TitleIndex.innerSize + 4, as: UInt8.self)), query)
    }

    private func titleRange(_ q: [UInt8]) -> Range<Int> {
        bound(recordCount, q, after: false, compareTitle)..<bound(recordCount, q, after: true, compareTitle)
    }

    private func innerRange(_ q: [UInt8]) -> Range<Int> {
        bound(innerCount, q, after: false, compareInner)..<bound(innerCount, q, after: true, compareInner)
    }

    /// Up to `limit` titles for `query`, best first:
    ///  1. titles that are exactly the query;
    ///  2. titles that start with it, most popular first;
    ///  3. titles with the query starting at a later word, most popular first;
    ///  4. if that leaves the list short and there are several words, titles containing all of them.
    /// Each article appears once, under the first title that found it. `cancelled` is polled so a
    /// search made stale by the next keystroke can stop early.
    public func search(_ query: String, limit: Int, cancelled: () -> Bool = { false }) -> [Hit] {
        let normalized = SearchText.normalize(query)
        guard !normalized.isEmpty, limit > 0 else { return [] }
        let q = Array(normalized.utf8)
        var hits: [Hit] = []
        var seenTargets = Set<Int>()
        func add(_ record: Int) -> Bool {
            let h = hit(record)
            if seenTargets.insert(h.targetIndex).inserted { hits.append(h) }
            return hits.count < limit && !cancelled()
        }

        let titles = titleRange(q)
        // Exact titles sort first within the range, being the shortest strings that start with the
        // query. Several can read the same ("Par", "PAR", "Pär"); lead with the best-known few.
        var exactEnd = titles.lowerBound
        while exactEnd < titles.upperBound, exactEnd - titles.lowerBound < TitleIndex.maxExact,
              titleEnd(exactEnd) - titleStart(exactEnd) == q.count {
            exactEnd += 1
        }
        // Highest rank first; equal ranks keep index order, as the Kotlin stable sort does.
        let exact = (titles.lowerBound..<exactEnd).sorted {
            let a = titleRanks.rank($0), b = titleRanks.rank($1)
            return a != b ? a > b : $0 < $1
        }
        for r in exact.prefix(TitleIndex.leadExact) where !add(r) { return hits }
        if !titleRanks.descending(titles, budget: TitleIndex.visits, add) { return hits }

        let inners = innerRange(q)
        if !innerRanks.descending(inners, budget: TitleIndex.visits, { add(innerRecord($0)) }) { return hits }

        let words = normalized.split(separator: " ").map(String.init).filter { !SearchText.stopWords.contains($0) }
        if words.count > 1 && hits.count < TitleIndex.few { allWords(words, add) }
        return hits
    }

    /// Titles containing every word (as a word prefix), found by walking the rarest word's matches
    /// from most popular down. Stop words are left out by the caller: they are not in the inner list.
    private func allWords(_ words: [String], _ add: (Int) -> Bool) {
        let keys = words.map { Array($0.utf8) }
        var best = -1
        var bestTitles = 0..<0
        var bestInners = 0..<0
        for (n, key) in keys.enumerated() {
            let t = titleRange(key)
            let i = innerRange(key)
            if best < 0 || t.count + i.count < bestTitles.count + bestInners.count {
                best = n
                bestTitles = t
                bestInners = i
            }
        }
        let others = keys.enumerated().filter { $0.offset != best }.map(\.element)
        func consider(_ record: Int) -> Bool { !others.allSatisfy { hasWord(record, $0) } || add(record) }
        if !titleRanks.descending(bestTitles, budget: TitleIndex.visits, consider) { return }
        _ = innerRanks.descending(bestInners, budget: TitleIndex.visits) { consider(innerRecord($0)) }
    }

    /// Whether some word of the record's title starts with `word`.
    private func hasWord(_ record: Int, _ word: [UInt8]) -> Bool {
        let start = titleStart(record)
        let end = titleEnd(record)
        var p = start
        while p < end {
            if p == start || byte(p - 1) == TitleIndex.space {
                var k = 0
                while k < word.count, p + k < end, byte(p + k) == word[k] { k += 1 }
                if k == word.count { return true }
            }
            p += 1
        }
        return false
    }

    /// A record chosen at random that is an article with something to read: not another name for
    /// one, and not one of the tiny pages that only forward to a section of another article (over a
    /// million of them, which the index builder ranks below `minArticleRank`). If none turns up,
    /// any article, and failing that any record.
    public func randomArticle() -> Hit? {
        guard recordCount > 0 else { return nil }
        var other: Hit?
        for _ in 0..<TitleIndex.randomTries {
            let record = Int.random(in: 0..<recordCount)
            let h = hit(record)
            if h.entryIndex == h.targetIndex {
                if titleRanks.rank(record) >= TitleIndex.minArticleRank { return h }
                if other == nil { other = h }
            }
        }
        return other ?? hit(Int.random(in: 0..<recordCount))
    }

    /// One rank byte per position, with the maximum of every 256 and of every 65536 stored after
    /// them, so the best-ranked positions in any range can be found without reading the whole range.
    private struct Ranks {
        static let block = 256

        let data: UnsafeRawPointer
        let count: Int
        private let blocks: Int
        private let level1: Int
        private let level2: Int

        init(data: UnsafeRawPointer, count: Int) {
            self.data = data
            self.count = count
            blocks = (count + Ranks.block - 1) / Ranks.block
            level1 = count
            level2 = count + blocks
        }

        /// Bytes taken by the ranks of `count` positions together with both levels of maxima.
        static func size(_ count: Int) -> Int {
            let blocks = (count + block - 1) / block
            return count + blocks + (blocks + block - 1) / block
        }

        private func value(_ at: Int) -> Int { Int(data.load(fromByteOffset: at, as: UInt8.self)) }

        func rank(_ position: Int) -> Int { value(position) }

        // A queue entry: one position (level 0) or a block of them, keyed by its best rank.
        private struct Node {
            let rank: Int
            let start: Int
            let level: Int
            let index: Int

            /// Highest rank first, then earliest position, then the larger block.
            func precedes(_ other: Node) -> Bool {
                if rank != other.rank { return rank > other.rank }
                if start != other.start { return start < other.start }
                return level > other.level
            }
        }

        /// Calls `visit` with positions in `range` from the highest rank down, ties in position
        /// order, until it returns false or `budget` positions have been visited.
        /// Returns false if `visit` asked to stop.
        func descending(_ range: Range<Int>, budget: Int, _ visit: (Int) -> Bool) -> Bool {
            guard !range.isEmpty else { return true }
            let block = Ranks.block
            var heap: [Node] = []
            func push(_ level: Int, _ index: Int) {
                let rank = value(level == 0 ? index : level == 1 ? level1 + index : level2 + index)
                let start = level == 0 ? index : level == 1 ? index * block : index * block * block
                heap.append(Node(rank: rank, start: start, level: level, index: index))
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    if !heap[child].precedes(heap[parent]) { break }
                    heap.swapAt(child, parent)
                    child = parent
                }
            }
            func pop() -> Node? {
                guard let top = heap.first else { return nil }
                let last = heap.removeLast()
                if !heap.isEmpty {
                    heap[0] = last
                    var parent = 0
                    while true {
                        let left = 2 * parent + 1
                        let right = left + 1
                        var first = parent
                        if left < heap.count, heap[left].precedes(heap[first]) { first = left }
                        if right < heap.count, heap[right].precedes(heap[first]) { first = right }
                        if first == parent { break }
                        heap.swapAt(parent, first)
                        parent = first
                    }
                }
                return top
            }

            var i = range.lowerBound
            while i < range.upperBound {
                if i % (block * block) == 0, i + block * block <= range.upperBound {
                    push(2, i / (block * block))
                    i += block * block
                } else if i % block == 0, i + block <= range.upperBound {
                    push(1, i / block)
                    i += block
                } else {
                    push(0, i)
                    i += 1
                }
            }
            var left = budget
            while let node = pop() {
                switch node.level {
                case 0:
                    if !visit(node.index) { return false }
                    left -= 1
                    if left <= 0 { return true }
                case 1:
                    for p in (node.index * block)..<min(count, (node.index + 1) * block) { push(0, p) }
                default:
                    for b in (node.index * block)..<min(blocks, (node.index + 1) * block) { push(1, b) }
                }
            }
            return true
        }
    }

    private static let magic: UInt32 = 0x5849_5257 // "WRIX"
    public static let version: UInt32 = 2
    private static let headerSize = 96
    private static let recordHeader = 8
    private static let innerSize = 5
    private static let space = UInt8(ascii: " ")
    private static let maxExact = 64
    private static let leadExact = 3
    private static let visits = 600 // matches examined per step; many titles lead to the same article
    private static let few = 8      // below this many results, also try the words in any order
    private static let randomTries = 64

    /// The lowest rank the index builder gives an article with something to read. A page under
    /// 2 KB, which is what a forwarding page is, scores below this unless other names point at it
    /// (see IndexBuilder.rankArticles in reader/indexer).
    public static let minArticleRank = 12

    /// The index file that belongs to a ZIM file.
    public static func file(for zim: URL) -> URL { URL(fileURLWithPath: zim.path + ".idx") }
}
