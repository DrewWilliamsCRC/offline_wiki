import Foundation
import libzstd

/// Read-only access to a ZIM archive (the format Kiwix distributes Wikipedia in).
///
/// This mirrors `ZimFile.kt` in reader/core. Layout, as far as this reader needs it: an 80-byte
/// header; a list of MIME types; a "path pointer list" giving the file offset of every directory
/// entry, sorted by namespace then path; and clusters of blobs, each cluster optionally
/// zstd-compressed. All integers are little-endian.
///
/// Safe to use from several threads: every read is positional.
public final class ZimFile {
    public enum Failure: Error, CustomStringConvertible {
        case notZim(String)
        case io(String)
        case corrupt(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .notZim(let m), .io(let m), .corrupt(let m), .unsupported(let m): return m
            }
        }
    }

    /// One directory entry: either an item stored in a cluster, or a redirect to another entry.
    public struct Entry {
        public let index: Int
        public let namespace: UInt8
        public let path: String
        let rawTitle: String
        let mime: Int
        public let redirectIndex: Int
        public let cluster: Int
        public let blob: Int

        public var isRedirect: Bool { mime == ZimFile.redirect }

        /// Display title. ZIM leaves the title empty when it equals the path.
        public var title: String { rawTitle.isEmpty ? path : rawTitle }
    }

    private let fd: Int32
    public let uuid: [UInt8]
    public let entryCount: Int
    public let clusterCount: Int
    public let mimeTypes: [String]
    private let pathPtrPos: UInt64
    private let clusterPtrPos: UInt64

    public init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw Failure.io("cannot open \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        do {
            let h = try ZimFile.readFully(descriptor, 0, ZimFile.headerSize)
            guard h.u32(0) == ZimFile.magic else { throw Failure.notZim("not a ZIM file: \(url.lastPathComponent)") }
            let mimes = ZimFile.parseMimeTypes(try ZimFile.read(descriptor, h.u64(56), 8192))
            fd = descriptor
            uuid = Array(h[8..<24])
            entryCount = Int(h.u32(24))
            clusterCount = Int(h.u32(28))
            pathPtrPos = h.u64(32)
            clusterPtrPos = h.u64(48)
            mimeTypes = mimes
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit { close(fd) }

    private static func parseMimeTypes(_ bytes: [UInt8]) -> [String] {
        var out: [String] = []
        var start = 0
        while start < bytes.count, let end = bytes[start...].firstIndex(of: 0), end > start {
            out.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = end + 1
        }
        return out
    }

    // MARK: Reading

    /// Reads up to `length` bytes at `pos`; fewer only at the end of the file.
    private static func read(_ fd: Int32, _ pos: UInt64, _ length: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: length)
        var done = 0
        while done < length {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, length - done, off_t(pos) + off_t(done)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.io("read failed at \(pos): \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            done += n
        }
        if done < length { buffer.removeSubrange(done...) }
        return buffer
    }

    private static func readFully(_ fd: Int32, _ pos: UInt64, _ length: Int) throws -> [UInt8] {
        let bytes = try read(fd, pos, length)
        guard bytes.count == length else { throw Failure.io("short read at \(pos)") }
        return bytes
    }

    private func read(_ pos: UInt64, _ length: Int) throws -> [UInt8] { try ZimFile.read(fd, pos, length) }
    private func readFully(_ pos: UInt64, _ length: Int) throws -> [UInt8] { try ZimFile.readFully(fd, pos, length) }

    // MARK: Directory entries

    /// File offset of the directory entry with this index.
    public func entryOffset(_ index: Int) throws -> UInt64 {
        precondition(index >= 0 && index < entryCount, "entry index \(index) out of range")
        return try readFully(pathPtrPos + 8 * UInt64(index), 8).u64(0)
    }

    public func entry(_ index: Int) throws -> Entry {
        try parseEntry(index, direntBytes(entryOffset(index)))
    }

    /// The raw bytes of a directory entry, at least through the end of its title.
    private func direntBytes(_ offset: UInt64) throws -> [UInt8] {
        var size = 320
        while true {
            let bytes = try read(offset, size)
            if direntComplete(bytes) || bytes.count < size || size >= ZimFile.maxDirent { return bytes }
            size *= 4
        }
    }

    private func direntComplete(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 16 else { return false }
        var zeros = 0
        for i in pathStart(bytes)..<bytes.count where bytes[i] == 0 {
            zeros += 1
            if zeros == 2 { return true }
        }
        return false
    }

    private func pathStart(_ bytes: [UInt8]) -> Int { Int(bytes.u16(0)) == ZimFile.redirect ? 12 : 16 }

    private func parseEntry(_ index: Int, _ bytes: [UInt8]) throws -> Entry {
        guard bytes.count >= 16 else { throw Failure.corrupt("directory entry \(index) is cut short") }
        let mime = Int(bytes.u16(0))
        let start = pathStart(bytes)
        guard let pathEnd = bytes[start...].firstIndex(of: 0), let titleEnd = bytes[(pathEnd + 1)...].firstIndex(of: 0) else {
            throw Failure.corrupt("unterminated string in directory entry \(index)")
        }
        let isRedirect = mime == ZimFile.redirect
        return Entry(
            index: index,
            namespace: bytes[3],
            path: String(decoding: bytes[start..<pathEnd], as: UTF8.self),
            rawTitle: String(decoding: bytes[(pathEnd + 1)..<titleEnd], as: UTF8.self),
            mime: mime,
            redirectIndex: isRedirect ? Int(bytes.u32(8)) : -1,
            cluster: isRedirect ? -1 : Int(bytes.u32(8)),
            blob: isRedirect ? -1 : Int(bytes.u32(12))
        )
    }

    /// Finds an entry by namespace and exact path with a binary search of the path pointer list.
    public func find(namespace: Character, path: String) throws -> Entry? {
        let ns = namespace.asciiValue ?? 0
        let key = Array(path.utf8)
        var lo = 0
        var hi = entryCount - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let bytes = try direntBytes(entryOffset(mid))
            let c = compareKey(bytes, ns, key)
            if c == 0 { return try parseEntry(mid, bytes) }
            if c < 0 { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// Orders a directory entry against (namespace, path): negative when the entry sorts first.
    private func compareKey(_ bytes: [UInt8], _ namespace: UInt8, _ key: [UInt8]) -> Int {
        let ns = Int(bytes[3]) - Int(namespace)
        if ns != 0 { return ns }
        var i = pathStart(bytes)
        var k = 0
        while true {
            let b = i < bytes.count ? bytes[i] : 0
            i += 1
            if b == 0 { return k == key.count ? 0 : -1 }
            if k == key.count { return 1 }
            let d = Int(b) - Int(key[k])
            k += 1
            if d != 0 { return d }
        }
    }

    /// Follows redirects to the entry that holds content.
    public func resolve(_ entry: Entry) throws -> Entry {
        var e = entry
        for _ in 0..<ZimFile.maxRedirects {
            if !e.isRedirect { return e }
            e = try self.entry(e.redirectIndex)
        }
        throw Failure.corrupt("redirect loop at \(entry.path)")
    }

    public func mimeType(_ entry: Entry) -> String {
        entry.mime < mimeTypes.count ? mimeTypes[entry.mime] : "application/octet-stream"
    }

    public func isHtml(_ entry: Entry) -> Bool { !entry.isRedirect && mimeType(entry).hasPrefix("text/html") }

    // MARK: Content

    private func clusterOffset(_ cluster: Int) throws -> UInt64 {
        guard cluster >= 0 && cluster < clusterCount else { throw Failure.corrupt("cluster \(cluster) out of range") }
        return try readFully(clusterPtrPos + 8 * UInt64(cluster), 8).u64(0)
    }

    /// The content of an item. Follow redirects with `resolve` first.
    public func content(_ entry: Entry) throws -> Data {
        precondition(!entry.isRedirect, "\(entry.path) is a redirect")
        let base = try clusterOffset(entry.cluster)
        let info = try readFully(base, 1)[0]
        let width = info & ZimFile.extended != 0 ? 8 : 4
        if info & 0x0F <= ZimFile.compressionNone {
            // Stored: the offset table and the blobs are read straight from the file.
            let o = try readFully(base + 1 + UInt64(width * entry.blob), width * 2)
            let from = width == 8 ? o.u64(0) : UInt64(o.u32(0))
            let to = width == 8 ? o.u64(8) : UInt64(o.u32(4))
            guard to >= from, to - from <= UInt64(Int32.max) else { throw Failure.unsupported("\(entry.path) is too large to load") }
            return Data(try readFully(base + 1 + from, Int(to - from)))
        }
        let data = try cluster(entry.cluster)
        func offset(_ i: Int) -> Int { width == 8 ? Int(data.u64(i * 8)) : Int(data.u32(i * 4)) }
        let from = offset(entry.blob)
        let to = offset(entry.blob + 1)
        guard from <= to, to <= data.count else { throw Failure.corrupt("blob \(entry.blob) of cluster \(entry.cluster) is out of bounds") }
        return Data(data[from..<to])
    }

    // Recently used decompressed clusters. A page and the next few link taps often share one.
    private var cache: [(number: Int, bytes: [UInt8])] = []
    private var cacheBytes = 0
    private let cacheLock = NSLock()

    private func cluster(_ number: Int) throws -> [UInt8] {
        cacheLock.lock()
        if let i = cache.firstIndex(where: { $0.number == number }) {
            let hit = cache.remove(at: i)
            cache.append(hit)
            cacheLock.unlock()
            return hit.bytes
        }
        cacheLock.unlock()
        let bytes = try decompress(number)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if !cache.contains(where: { $0.number == number }) {
            cache.append((number, bytes))
            cacheBytes += bytes.count
            while cacheBytes > ZimFile.cacheLimit && cache.count > 1 {
                cacheBytes -= cache.removeFirst().bytes.count
            }
        }
        return bytes
    }

    /// A decompressed cluster is an offset table followed by the blobs. The first offset equals the
    /// table's size and the last equals the cluster's size, so the stream tells us how much to read;
    /// reading exactly that much also keeps the decoder from running into the next cluster.
    private func decompress(_ number: Int) throws -> [UInt8] {
        let base = try clusterOffset(number)
        let info = try readFully(base, 1)[0]
        guard info & 0x0F == ZimFile.compressionZstd else { throw Failure.unsupported("cluster compression type \(info & 0x0F)") }
        let width = info & ZimFile.extended != 0 ? 8 : 4
        let stream = try ZstdStream(fd: fd, position: base + 1)
        var bytes = try stream.read(width)
        let tableSize = width == 8 ? bytes.u64(0) : UInt64(bytes.u32(0))
        guard tableSize >= UInt64(width), tableSize <= ZimFile.maxCluster, tableSize % UInt64(width) == 0 else {
            throw Failure.corrupt("corrupt cluster \(number)")
        }
        bytes += try stream.read(Int(tableSize) - width)
        let last = Int(tableSize) - width
        let total = width == 8 ? bytes.u64(last) : UInt64(bytes.u32(last))
        guard total >= tableSize, total <= ZimFile.maxCluster else { throw Failure.corrupt("cluster \(number) is too large (\(total) bytes)") }
        bytes += try stream.read(Int(total - tableSize))
        return bytes
    }

    private static let magic: UInt32 = 0x044D_495A
    private static let headerSize = 80
    static let redirect = 0xFFFF
    private static let compressionNone: UInt8 = 1 // 0 and 1 both mean "stored"
    private static let compressionZstd: UInt8 = 5
    private static let extended: UInt8 = 0x10 // cluster uses 8-byte offsets
    private static let maxRedirects = 8
    private static let maxDirent = 8192
    private static let maxCluster: UInt64 = 512 * 1024 * 1024
    private static let cacheLimit = 24 * 1024 * 1024
}

/// Streaming zstd decompression of the file from a start position.
private final class ZstdStream {
    private let fd: Int32
    private var position: UInt64
    private let stream: OpaquePointer
    private let input: UnsafeMutableRawPointer
    private let capacity: Int
    private var filled = 0
    private var consumed = 0

    init(fd: Int32, position: UInt64) throws {
        guard let s = ZSTD_createDStream() else { throw ZimFile.Failure.io("could not start the decompressor") }
        self.fd = fd
        self.position = position
        stream = s
        capacity = ZSTD_DStreamInSize()
        input = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
    }

    deinit {
        ZSTD_freeDStream(stream)
        input.deallocate()
    }

    /// Exactly `count` decompressed bytes.
    func read(_ count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        guard count > 0 else { return out }
        try out.withUnsafeMutableBytes { raw in
            var output = ZSTD_outBuffer(dst: raw.baseAddress, size: count, pos: 0)
            while output.pos < count {
                if consumed == filled {
                    let n = pread(fd, input, capacity, off_t(position))
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw ZimFile.Failure.io("cluster data ended early") }
                    position += UInt64(n)
                    filled = n
                    consumed = 0
                }
                var inBuffer = ZSTD_inBuffer(src: UnsafeRawPointer(input), size: filled, pos: consumed)
                let result = ZSTD_decompressStream(stream, &output, &inBuffer)
                consumed = inBuffer.pos
                if ZSTD_isError(result) != 0 {
                    throw ZimFile.Failure.corrupt("zstd: \(String(cString: ZSTD_getErrorName(result)))")
                }
                if result == 0 && output.pos < count { throw ZimFile.Failure.corrupt("cluster data ended early") }
            }
        }
        return out
    }
}

extension Array where Element == UInt8 {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }

    func u32(_ at: Int) -> UInt32 {
        UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }

    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
}
