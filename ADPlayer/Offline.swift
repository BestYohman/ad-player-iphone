import Foundation
import UIKit

/// "Download": an episode, movie or audiobook kept on the phone, so it plays with no connection at all.
/// Episodes and movies: the PC first makes one audio file (the audio description, or the soundtrack when there is
/// none), then the phone fetches it. Audiobooks: the phone fetches the book's pieces. The fetching goes on in the
/// background, even with the app closed (iOS's own downloader), and carries on when the app is opened again.
@MainActor
final class Offline: ObservableObject {
    static let shared = Offline()

    struct Part: Codable, Hashable {
        var url: String          // where the PC has it (without the address, which can change)
        var file: String         // its name in the download's folder
        var done = false
    }

    struct Saved: Codable, Identifiable, Hashable {
        var item: String                 // the Emby item, or the Audiobookshelf book
        var kind: String                 // "audio" (an episode or movie) or "book"
        var title: String
        var state = "preparing"          // preparing (the PC makes the file), downloading, done, failed
        var progress = 0
        var bytes: Int64 = 0
        var job = ""                     // the PC's job for the file (episodes and movies)
        var itemType = ""
        var hasNext = false
        var hasAD = true
        var runtime: Double = 0
        var author = ""
        var parts: [Part] = []
        var detail: Data? = nil          // books: the book as the PC described it (chapters, pieces)
        var pos: Double = 0              // where it was left, kept on the phone too
        var posAt: Double = 0
        var error = ""
        var tries = 0

        var id: String { kind + "|" + item }
        var done: Bool { state == "done" }

        var stateText: String {
            switch state {
            case "preparing": return "The PC is getting it ready" + (progress > 0 ? ", \(progress) percent" : "")
            case "downloading": return "Downloading" + (progress > 0 ? ", \(progress) percent" : "")
            case "done": return "Downloaded" + (bytes > 0 ? ", \(Offline.size(bytes))" : "")
            default: return "Didn't download" + (error.isEmpty ? "" : ": \(error)")
            }
        }

        var kindText: String {
            if kind == "book" { return author.isEmpty ? "Audiobook" : "Audiobook by \(author)" }
            return hasAD ? "With description" : "Without description"
        }
    }

    @Published private(set) var items: [Saved] = []

    var api: @MainActor () -> API? = { nil }
    var say: @MainActor (String) -> Void = { _ in }

    private var preparing = Set<String>()
    private let fetcher = Fetcher()

    // MARK: where things are kept

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var f = base.appendingPathComponent("offline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: f.path) {
            try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? f.setResourceValues(v)
        }
        return f
    }

    nonisolated static func dir(_ kind: String, _ item: String) -> URL {
        folder.appendingPathComponent(kind + "_" + item.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    private static var store: URL { folder.appendingPathComponent("downloads.json") }

    nonisolated static func size(_ b: Int64) -> String {
        if b >= 1_000_000_000 { return String(format: "%.2f GB", Double(b) / 1e9) }
        if b >= 10_000_000 { return "\(b / 1_000_000) MB" }
        if b >= 1_000_000 { return String(format: "%.1f MB", Double(b) / 1e6) }
        return "\(max(1, b / 1000)) KB"
    }

    private init() {
        if let d = try? Data(contentsOf: Offline.store), let list = try? JSONDecoder().decode([Saved].self, from: d) { items = list }
        fetcher.finished = { [weak self] key, index, ok, error in
            Task { @MainActor in self?.partFinished(key, index, ok: ok, error: error) }
        }
        fetcher.progress = { [weak self] key, index, got, total in
            Task { @MainActor in self?.partProgress(key, index, got: got, total: total) }
        }
        fetcher.start()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: Offline.store, options: .atomic) }
    }

    private func update(_ key: String, _ change: (inout Saved) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == key }) else { return }
        change(&items[i])
        save()
    }

    func find(_ item: String, _ kind: String) -> Saved? { items.first { $0.item == item && $0.kind == kind } }

    /// A finished download of this item (episode / movie: "audio", or "book").
    func ready(_ item: String, _ kind: String) -> Saved? {
        guard let s = find(item, kind), s.done else { return nil }
        let d = Offline.dir(kind, item)
        return s.parts.allSatisfy({ FileManager.default.fileExists(atPath: d.appendingPathComponent($0.file).path) }) ? s : nil
    }

    func file(_ s: Saved, _ index: Int) -> URL? {
        guard index >= 0, index < s.parts.count else { return nil }
        let f = Offline.dir(s.kind, s.item).appendingPathComponent(s.parts[index].file)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// Remembers where it was left on the phone (for playing with no connection).
    func notePos(_ item: String, _ pos: Double) {
        guard let i = items.firstIndex(where: { $0.item == item && $0.done }), abs(items[i].pos - pos) > 5 else { return }
        items[i].pos = pos
        items[i].posAt = Date().timeIntervalSince1970
        save()
    }

    // MARK: starting a download

    /// An episode or movie: its audio (the audio description, or the soundtrack when there is none).
    func download(_ it: Item) {
        if let have = find(it.id, "audio"), have.state != "failed" {
            say("\(it.label) is already \(have.done ? "downloaded" : "downloading")."); return
        }
        removeQuietly("audio|" + it.id)
        items.append(Saved(item: it.id, kind: "audio", title: it.label, itemType: it.type ?? "", hasNext: it.type == "Episode",
                           hasAD: it.hasAD != false, pos: (it.resumeTicks ?? 0) / 10_000_000))
        save()
        say("Getting \(it.label) ready to download. It carries on by itself - see Downloads.")
        Task { await prepare("audio|" + it.id) }
    }

    private func prepare(_ key: String) async {
        guard !preparing.contains(key), let s = items.first(where: { $0.id == key }) else { return }
        preparing.insert(key)
        defer { preparing.remove(key) }
        guard let api = api() else { return }
        do {
            var d = try await api.post("api/play/download/prepare", ["item": s.item, "kind": "audio"], as: DownloadJob.self)
            while true {
                guard let now = items.first(where: { $0.id == key }) else {           // removed meanwhile: the PC stops too
                    tellPC(d.id, "cancel"); return
                }
                if d.state == "failed" {
                    let why = d.error ?? "the PC couldn't make the file"
                    update(key) { $0.state = "failed"; $0.error = why }
                    say("\(now.title) didn't download: \(why).")
                    return
                }
                if d.state == "ready", let url = d.url {
                    let ext = url.hasSuffix(".mp4") ? "mp4" : "m4a"
                    update(key) {
                        $0.state = "downloading"; $0.progress = 0; $0.job = d.id
                        $0.parts = [Part(url: url, file: "audio.\(ext)")]
                        if let r = d.runtimeTicks { $0.runtime = r / 10_000_000 }
                        if let b = d.bytes { $0.bytes = Int64(b) }
                    }
                    startParts(key)
                    return
                }
                update(key) { $0.progress = Int(d.progress ?? 0); $0.job = d.id }
                try await Task.sleep(nanoseconds: 3_000_000_000)
                d = try await api.get("api/play/download/job/\(d.id)", as: DownloadJob.self)
            }
        } catch is CancellationError {
            return
        } catch APIError.server(let message) {
            update(key) { $0.state = "failed"; $0.error = message }
            say("\(s.title) didn't download: \(message)")
        } catch {
            // no connection right now: it carries on when the app is next open
        }
    }

    /// An audiobook: its pieces.
    func downloadBook(id: String, label: String) {
        if let have = find(id, "book"), have.state != "failed" {
            say("\(label) is already \(have.done ? "downloaded" : "downloading")."); return
        }
        guard let api = api() else { return }
        say("Getting \(label) ready to download.")
        Task {
            do {
                let b = try await api.get("api/play/books/book", ["id": id], as: BookDetail.self)
                let raw = try? JSONEncoder().encode(b)
                let pieces: [(String, Double)] = (b.segs?.isEmpty == false) ? b.segs!.map { ($0.url, $0.start) }
                                                                           : b.tracks.map { ($0.url, $0.start) }
                guard !pieces.isEmpty else { say("That book has no audio."); return }
                let parts = pieces.enumerated().map { (i, p) -> Part in
                    let ext = String((p.0.split(separator: "?").first ?? "").split(separator: ".").last ?? "mp3").prefix(4)
                    return Part(url: p.0, file: "\(i).\(ext)")
                }
                removeQuietly("book|" + id)
                items.append(Saved(item: id, kind: "book", title: b.title, state: "downloading", author: b.author ?? "",
                                   parts: parts, detail: raw, pos: b.finished ? 0 : b.position, posAt: Date().timeIntervalSince1970))
                save()
                if let c = b.cover, let u = api.media(c) {
                    Task.detached {
                        if let res = try? await URLSession.shared.data(from: u), (res.1 as? HTTPURLResponse)?.statusCode == 200 {
                            try? FileManager.default.createDirectory(at: Offline.dir("book", id), withIntermediateDirectories: true)
                            try? res.0.write(to: Offline.dir("book", id).appendingPathComponent("cover.jpg"))
                        }
                    }
                }
                startParts("book|" + id)
                say("Downloading \(b.title). It carries on by itself - see Downloads.")
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    /// Hands the parts not on the phone yet to iOS's downloader.
    private func startParts(_ key: String) {
        guard let s = items.first(where: { $0.id == key }), s.state == "downloading", let api = api() else { return }
        let d = Offline.dir(s.kind, s.item)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        fetcher.running { running in
            Task { @MainActor in
                for (i, p) in s.parts.enumerated() where !p.done {
                    let tag = "\(key)#\(i)"
                    if running.contains(tag) { continue }
                    guard let u = api.media(p.url) else { continue }
                    self.fetcher.fetch(u, tag: tag, to: d.appendingPathComponent(p.file))
                }
                self.checkDone(key)
            }
        }
    }

    private func partProgress(_ key: String, _ index: Int, got: Int64, total: Int64) {
        guard let s = items.first(where: { $0.id == key }), s.state == "downloading" else { return }
        let n = max(1, s.parts.count)
        let doneParts = s.parts.filter { $0.done }.count
        let part = total > 0 ? Double(got) / Double(total) : 0
        let pct = min(99, Int((Double(doneParts) + part) / Double(n) * 100))
        if pct != s.progress, let i = items.firstIndex(where: { $0.id == key }) { items[i].progress = pct }   // saved with the next change
    }

    private func partFinished(_ key: String, _ index: Int, ok: Bool, error: String?) {
        guard let s = items.first(where: { $0.id == key }), s.state == "downloading", index < s.parts.count else { return }
        if ok {
            update(key) { $0.parts[index].done = true; $0.tries = 0 }
            checkDone(key)
            return
        }
        // stopped part way (no connection, the PC was off...): tried again a few times, then when the app is next open
        update(key) { $0.tries += 1 }
        if (items.first { $0.id == key }?.tries ?? 0) <= 5 {
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self.startParts(key)
            }
        } else if error != nil {
            update(key) { $0.error = "it keeps stopping - it tries again when the app is next open" }
        }
    }

    private func checkDone(_ key: String) {
        guard let s = items.first(where: { $0.id == key }), s.state == "downloading", !s.parts.isEmpty else { return }
        let d = Offline.dir(s.kind, s.item)
        let all = s.parts.allSatisfy { p in p.done && FileManager.default.fileExists(atPath: d.appendingPathComponent(p.file).path) }
        guard all else { return }
        let bytes = s.parts.reduce(Int64(0)) { sum, p in
            sum + (((try? FileManager.default.attributesOfItem(atPath: d.appendingPathComponent(p.file).path))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        update(key) { $0.state = "done"; $0.progress = 100; $0.bytes = bytes; $0.error = ""; $0.tries = 0 }
        say("\(s.title) is downloaded.")
        if !s.job.isEmpty { tellPC(s.job, "done") }             // the PC deletes its copy now
    }

    /// When the app opens (or the connection is back): carry on with any that weren't finished.
    func resume() {
        flushStops()
        for s in items {
            if s.state == "preparing" { Task { await prepare(s.id) } }
            else if s.state == "downloading" {
                update(s.id) { $0.tries = 0 }
                startParts(s.id)
            }
        }
    }

    // MARK: removing

    func retry(_ s: Saved) {
        if s.kind == "book" {
            removeQuietly(s.id)
            downloadBook(id: s.item, label: s.title)
        } else {
            update(s.id) { $0.state = s.parts.isEmpty ? "preparing" : "downloading"; $0.error = ""; $0.tries = 0 }
            if s.parts.isEmpty { Task { await prepare(s.id) } } else { startParts(s.id) }
            say("Trying \(s.title) again.")
        }
    }

    func remove(_ s: Saved) {
        removeQuietly(s.id)
        say("Removed the download of \(s.title).")
    }

    private func removeQuietly(_ key: String) {
        guard let s = items.first(where: { $0.id == key }) else { return }
        // still on its way (the PC making it, or the phone fetching it): the PC stops too and clears its copy
        if !s.done && !s.job.isEmpty { tellPC(s.job, "cancel") }
        fetcher.cancel(prefix: key + "#")
        try? FileManager.default.removeItem(at: Offline.dir(s.kind, s.item))
        items.removeAll { $0.id == key }
        save()
    }

    /// Tells the PC this phone doesn't want its copy any more (it has it, or stopped). With no connection, told later.
    private func tellPC(_ job: String, _ what: String) {
        guard let api = api() else { return }
        Task {
            let ok = (try? await api.post("api/play/download/\(what)", ["id": job], as: MessageResponse.self)) != nil
            var left = UserDefaults.standard.stringArray(forKey: "offlineStops") ?? []
            left.removeAll { $0 == job }
            if !ok { left.append(job) }
            UserDefaults.standard.set(left, forKey: "offlineStops")
        }
    }

    private func flushStops() {
        for job in UserDefaults.standard.stringArray(forKey: "offlineStops") ?? [] { tellPC(job, "cancel") }
    }
}

struct DownloadJob: Decodable {
    let id: String
    let state: String?
    let progress: Double?
    let error: String?
    let url: String?
    let bytes: Double?
    let runtimeTicks: Double?

    enum CodingKeys: String, CodingKey {
        case id, state, progress, error, url, bytes
        case runtimeTicks = "runtime_ticks"
    }
}

/// iOS's background downloader: the files keep coming with the app in the background or closed.
final class Fetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "com.home.adplayer.downloads"
    /// Set by the app when iOS wakes it for finished downloads; called once they've been handled.
    nonisolated(unsafe) static var backgroundDone: (() -> Void)?

    var finished: (String, Int, Bool, String?) -> Void = { _, _, _, _ in }
    var progress: (String, Int, Int64, Int64) -> Void = { _, _, _, _ in }

    private var session: URLSession!
    private var lastTick = [Int: Date]()
    private let lock = NSLock()

    func start() {
        let c = URLSessionConfiguration.background(withIdentifier: Fetcher.identifier)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.allowsCellularAccess = true
        c.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    /// The tags of the downloads on their way now.
    func running(_ done: @escaping (Set<String>) -> Void) {
        session.getAllTasks { tasks in
            done(Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap { $0.taskDescription?.components(separatedBy: "|>").first }))
        }
    }

    func fetch(_ url: URL, tag: String, to dest: URL) {
        var r = URLRequest(url: url)
        if !API.token.isEmpty { r.setValue(API.token, forHTTPHeaderField: "X-ADP-Token") }
        let t = session.downloadTask(with: r)
        t.taskDescription = tag + "|>" + dest.path
        t.resume()
    }

    func cancel(prefix: String) {
        session.getAllTasks { tasks in
            for t in tasks where (t.taskDescription ?? "").hasPrefix(prefix) { t.cancel() }
        }
    }

    private func parse(_ task: URLSessionTask) -> (key: String, index: Int, dest: String)? {
        guard let d = task.taskDescription else { return nil }
        let a = d.components(separatedBy: "|>")
        guard a.count == 2 else { return nil }
        let b = a[0].components(separatedBy: "#")
        guard b.count == 2, let i = Int(b[1]) else { return nil }
        return (b[0], i, a[1])
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let p = parse(downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finished(p.key, p.index, false, "the PC answered \(status)")
            return
        }
        let dest = URL(fileURLWithPath: p.dest)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        finished(p.key, p.index, ok, ok ? nil : "couldn't keep the file")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let p = parse(downloadTask) else { return }
        lock.lock()
        let last = lastTick[downloadTask.taskIdentifier] ?? .distantPast
        let due = Date().timeIntervalSince(last) > 1
        if due { lastTick[downloadTask.taskIdentifier] = Date() }
        lock.unlock()
        if due { progress(p.key, p.index, totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let p = parse(task) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        finished(p.key, p.index, false, error.localizedDescription)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            Fetcher.backgroundDone?()
            Fetcher.backgroundDone = nil
        }
    }
}
