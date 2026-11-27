import CryptoKit
import Foundation
import UIKit

/// Downloads a book from the `Catalog` into the app's Documents folder, where `LibraryStore` looks
/// for Wikipedia. One book at a time, through a background URL session: iOS carries the transfer
/// on with the app suspended or closed, and wakes the app when a file has arrived.
///
/// A file that has arrived waits in Application Support, out of the reader's sight, until its
/// SHA-256 matches the catalog's; only then does it move into Documents. A download that stops
/// (paused, or the app swiped away) leaves resume data there too, and carries on from it the next
/// time. The Android app does the same in its own way (Downloads.kt).
///
/// A book's older snapshots in Documents (the same `<book>_<flavor>`, an earlier date) are an
/// update's to replace: once the new one is in place they are deleted. `LibraryStore` reads only
/// the newest anyway.
@MainActor
final class Downloads: NSObject, ObservableObject {
    static let shared = Downloads()

    /// The book being downloaded, or the last one; kept across launches.
    @Published private(set) var book: Catalog.Book?
    @Published private(set) var running = false
    /// What is going on, in a few words for the reader: "Downloading Wikipedia", "Paused", "Done"...
    @Published private(set) var doing = ""
    @Published private(set) var problem: String?
    /// Bytes of the book that are here, whole or on the way.
    @Published private(set) var done: Int64 = 0
    /// Goes up each time a book has arrived whole, for the screens that wait for one.
    @Published private(set) var arrivals = 0
    /// Whether the downloads screen is up. It is shown over whatever is beneath, which can change
    /// while it is up: a first Wikipedia arrives, or the open one is deleted.
    @Published var showing = false

    /// Given by iOS when it wakes the app for this session's events; called once they are handled.
    var backgroundEventsDone: (() -> Void)?

    private var session: URLSession!
    private var received: [String: Int64] = [:] // by file name: bytes so far of files under way
    private var checking: Set<String> = []

    private static let identifier = "dev.offlinewiki.reader.downloads"
    private static let bookKey = "download.book"
    private static let receivedKey = "download.received"

    override private init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Downloads.identifier)
        configuration.allowsCellularAccess = false // tens of gigabytes: Wi-Fi only
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        if let data = UserDefaults.standard.data(forKey: Downloads.bookKey) {
            book = try? JSONDecoder().decode(Catalog.Book.self, from: data)
        }
        received = (UserDefaults.standard.dictionary(forKey: Downloads.receivedKey) as? [String: Int64]) ?? [:]
        // Pick up what was going on before the app was last closed: transfers iOS carried on,
        // and files that arrived but were not yet checked.
        session.getAllTasks { tasks in
            let names = tasks.filter { $0.state == .running }.compactMap(\.taskDescription)
            Task { @MainActor in
                self.running = !names.isEmpty
                if self.running { self.doing = "Downloading" }
                self.checkArrived()
                self.update()
            }
        }
    }

    // MARK: Where files are

    private static var documents: URL { LibraryStore.documents }

    /// Out of the reader's sight: files that have arrived but are not checked yet, and resume data.
    nonisolated private static var waiting: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Application Support is backed up too; tens of gigabytes on their way must not be.
        LibraryStore.keepOutOfBackups(folder)
        return folder
    }

    nonisolated private static func arrived(_ name: String) -> URL { waiting.appendingPathComponent(name + ".part") }
    nonisolated private static func resumeData(_ name: String) -> URL { waiting.appendingPathComponent(name + ".resume") }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private static func isHere(_ file: Catalog.Remote) -> Bool {
        size(of: documents.appendingPathComponent(file.name)) == file.size
    }

    static func zim(of book: Catalog.Book) -> Catalog.Remote { book.files.last { $0.name.hasSuffix(".zim") }! }

    static func snapshot(of book: Catalog.Book) -> Snapshot? { Snapshot(zim(of: book).name) }

    /// Wikipedia files of `book` in Documents that are older snapshots than the catalog's, newest first.
    func older(_ book: Catalog.Book) -> [URL] {
        guard let date = Downloads.snapshot(of: book)?.date else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Downloads.documents.path)) ?? []
        return names.filter { name in
            guard let snapshot = Snapshot(name) else { return false }
            return snapshot.book == book.id && snapshot.date < date
        }.sorted(by: >).map { Downloads.documents.appendingPathComponent($0) }
    }

    /// A Wikipedia file with its index.
    private static func withIndex(_ zim: URL) -> [URL] { [zim, URL(fileURLWithPath: zim.path + ".idx")] }

    /// Every file `delete` would remove for `book`: all its snapshots, with their indexes.
    func files(of book: Catalog.Book) -> [URL] {
        older(book).flatMap(Downloads.withIndex) + book.files.map { Downloads.documents.appendingPathComponent($0.name) }
    }

    /// Deletes `book`'s older snapshots: to make room for the new one, or once it is in place.
    func deleteOlder(_ book: Catalog.Book) {
        for url in older(book).flatMap(Downloads.withIndex) { try? FileManager.default.removeItem(at: url) }
    }

    /// Deletes all of `book` that is here, and anything of it on the way.
    func delete(_ book: Catalog.Book) {
        if self.book?.id == book.id {
            stopTransfers()
            running = false
            doing = ""
            problem = nil
            received = [:]
            save()
        }
        for url in files(of: book) { try? FileManager.default.removeItem(at: url) }
        for file in book.files {
            try? FileManager.default.removeItem(at: Downloads.arrived(file.name))
            try? FileManager.default.removeItem(at: Downloads.resumeData(file.name))
        }
    }

    private func olderSize(_ book: Catalog.Book) -> Int64 {
        older(book).flatMap(Downloads.withIndex).reduce(0) { $0 + max(0, Downloads.size(of: $1)) }
    }

    private static var free: Int64 {
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    /// Whether `book` can be downloaded beside what is here, leaving a margin free.
    func roomFor(_ book: Catalog.Book) -> Bool { Downloads.free >= book.size - have(book) + Downloads.margin }

    /// Whether `book` would fit if its older snapshots were deleted first.
    func roomIfReplaced(_ book: Catalog.Book) -> Bool {
        Downloads.free + olderSize(book) >= book.size - have(book) + Downloads.margin
    }

    private static let margin: Int64 = 100_000_000 // left free, so the device is not filled to the brim

    /// Whether all of `book` is in Documents, each file at its full size.
    func complete(_ book: Catalog.Book) -> Bool { book.files.allSatisfy(Downloads.isHere) }

    /// How many of `book`'s bytes are here, whole or on the way.
    func have(_ book: Catalog.Book) -> Int64 {
        book.files.reduce(0) { sum, file in
            if Downloads.isHere(file) || Downloads.size(of: Downloads.arrived(file.name)) == file.size { return sum + file.size }
            return sum + min(received[file.name] ?? 0, file.size)
        }
    }

    // MARK: Starting and stopping

    /// Starts downloading `book`, or carries on with it, unless another download is running.
    func start(_ book: Catalog.Book) {
        guard !running else { return }
        problem = nil
        if self.book?.id != book.id { received = [:] }
        self.book = book
        if let data = try? JSONEncoder().encode(book) { UserDefaults.standard.set(data, forKey: Downloads.bookKey) }

        let needed = book.size - have(book) + Downloads.margin
        let free = Downloads.free
        if free < needed {
            fail("There is not enough room: this needs \(Downloads.gb(needed)) more, and \(Downloads.gb(free)) is free.")
            return
        }
        running = true
        doing = "Starting"
        // A transfer iOS is still carrying on is left to finish, not started a second time.
        session.getAllTasks { tasks in
            let busy = Set(tasks.filter { $0.state == .running }.compactMap(\.taskDescription))
            Task { @MainActor in self.begin(book, busy: busy) }
        }
    }

    private func begin(_ book: Catalog.Book, busy: Set<String>) {
        guard running, self.book?.id == book.id else { return }
        for file in book.files where !busy.contains(file.name) && !Downloads.isHere(file)
            && Downloads.size(of: Downloads.arrived(file.name)) != file.size {
            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: Downloads.resumeData(file.name)) {
                task = session.downloadTask(withResumeData: data)
                try? FileManager.default.removeItem(at: Downloads.resumeData(file.name))
            } else {
                received[file.name] = 0
                task = session.downloadTask(with: file.url)
            }
            task.taskDescription = file.name
            task.countOfBytesClientExpectsToReceive = file.size
            task.resume()
        }
        checkArrived()
        update()
    }

    /// Stops the download; what has arrived is kept, to carry on from.
    func pause() {
        stopTransfers()
        running = false
        doing = "Paused"
        save()
    }

    /// One file going wrong stops the book: the next start begins from a known place.
    private func fail(_ message: String) {
        stopTransfers()
        problem = message
        running = false
        doing = "Stopped"
        save()
    }

    /// Cancels the session's transfers, keeping resume data for each.
    private func stopTransfers() {
        session.getAllTasks { tasks in
            for case let task as URLSessionDownloadTask in tasks {
                task.cancel { data in
                    if let data, let name = task.taskDescription { try? data.write(to: Downloads.resumeData(name)) }
                }
            }
        }
    }

    private func save() { UserDefaults.standard.set(received, forKey: Downloads.receivedKey) }

    /// Works out `done`, and whether the book is now complete.
    private func update() {
        guard let book else { return }
        done = have(book)
        if complete(book), doing != "Done" {
            deleteOlder(book) // an update: the new snapshot is in place and checked
            running = false
            doing = "Done"
            received = [:]
            save()
            // Forgotten at the next launch: by then there is nothing to say about it.
            UserDefaults.standard.removeObject(forKey: Downloads.bookKey)
            arrivals += 1
        }
    }

    // MARK: Checking what has arrived

    /// Checks each file of the book that has arrived and is not being checked yet; a whole one
    /// moves into Documents.
    private func checkArrived() {
        guard let book else { return }
        for file in book.files where !checking.contains(file.name) && FileManager.default.fileExists(atPath: Downloads.arrived(file.name).path) {
            checking.insert(file.name)
            let what = file.name.hasSuffix(".idx") ? "the index" : "Wikipedia"
            Task {
                let result = await Downloads.check(file) { fraction in
                    Task { @MainActor in self.doing = "Checking \(what): \(Int(fraction * 100))%" }
                }
                checking.remove(file.name)
                switch result {
                case .success:
                    // On the disk before it takes its name: a device that loses power just after
                    // must not be left with an empty file that looks finished.
                    if let handle = try? FileHandle(forUpdating: Downloads.arrived(file.name)) {
                        try? handle.synchronize()
                        try? handle.close()
                    }
                    let target = Downloads.documents.appendingPathComponent(file.name)
                    try? FileManager.default.removeItem(at: target)
                    do {
                        try FileManager.default.moveItem(at: Downloads.arrived(file.name), to: target)
                        LibraryStore.keepOutOfBackups(target) // a moved file may not keep its folder's mark
                    } catch {
                        fail("\(file.name) could not be put in place: \(error.localizedDescription)")
                    }
                    if running, doing.hasPrefix("Checking") { doing = "Downloading" }
                case .failure(let error):
                    try? FileManager.default.removeItem(at: Downloads.arrived(file.name))
                    fail(error.localizedDescription)
                }
                update()
            }
        }
    }

    /// Reads a file that has arrived and compares its SHA-256 with the catalog's, away from the
    /// main thread. Tens of gigabytes take a minute or so.
    nonisolated private static func check(_ file: Catalog.Remote, progress: @escaping (Double) -> Void) async -> Result<Void, Error> {
        await Task.detached(priority: .utility) {
            let url = arrived(file.name)
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hasher = SHA256()
                var read: Int64 = 0
                var shown: Int64 = 0
                while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                    read += Int64(chunk.count)
                    if read - shown >= 512 << 20 {
                        shown = read
                        progress(Double(read) / Double(file.size))
                    }
                }
                let sum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard read == file.size, sum == file.sha256 else {
                    throw Catalog.Problem(message: "\(file.name) arrived damaged and was deleted. Try again.")
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
    }

    static func gb(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}

extension Downloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Passed on each time another 4 MB has come: often enough to see it move, seldom enough not
        // to redraw for every packet.
        guard let name = downloadTask.taskDescription,
              totalBytesWritten >> 22 != (totalBytesWritten - bytesWritten) >> 22 else { return }
        Task { @MainActor in
            self.received[name] = totalBytesWritten
            if !self.doing.hasPrefix("Checking") {
                self.doing = name.hasSuffix(".idx") ? "Downloading the index" : "Downloading Wikipedia"
            }
            if totalBytesWritten >> 28 != (totalBytesWritten - bytesWritten) >> 28 { self.save() } // every 256 MB
            self.update()
        }
    }

    /// The file is iOS's until this returns, so it is moved out of the way here, before anything else.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            Task { @MainActor in self.fail("\(name): the server answered \(status)") }
            return
        }
        let target = Downloads.arrived(name)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            Task { @MainActor in self.fail("\(name) could not be kept: \(error.localizedDescription)") }
            return
        }
        Task { @MainActor in
            self.received[name] = nil
            self.checkArrived()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, let name = task.taskDescription else { return }
        // Kept, so that the next start carries on from here instead of from the beginning.
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: Downloads.resumeData(name))
        }
        session.getAllTasks { tasks in
            let others = tasks.contains { $0.state == .running && $0 !== task }
            Task { @MainActor in
                self.save()
                if error.code == NSURLErrorCancelled {
                    // Paused here, or the app was swiped away, which stops its transfers.
                    if !others, self.doing != "Stopped" {
                        self.running = false
                        if self.doing != "Done" { self.doing = "Paused" }
                    }
                } else {
                    self.fail(error.localizedDescription)
                }
                self.update()
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundEventsDone?()
            self.backgroundEventsDone = nil
        }
    }
}

/// Hands iOS's wake-up for finished transfers to `Downloads`, whose session has to exist by then.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = Downloads.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in Downloads.shared.backgroundEventsDone = completionHandler }
    }
}
