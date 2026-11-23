import Foundation
import UIKit
import Network

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
        var bytes: Int64 = 0     // its size, as the PC said (0: not known)

        enum CodingKeys: String, CodingKey { case url, file, done, bytes }
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

        enum CodingKeys: String, CodingKey {
            case item, kind, title, state, progress, bytes, job, itemType, hasNext, hasAD, runtime, author, parts, detail,
                 pos, posAt, error, tries
        }

        var id: String { kind + "|" + item }
        var done: Bool { state == "done" }

        var stateText: String {
            switch state {
            case "preparing": return "The PC is getting it ready" + (progress > 0 ? ", \(progress) percent" : "")
            case "downloading":
                return (Offline.waitingForWiFi ? "Waiting for Wi-Fi" : "Downloading") + (progress > 0 ? ", \(progress) percent" : "")
            case "done": return "Downloaded" + (bytes > 0 ? ", \(Offline.size(bytes))" : "")
            default: return "Didn't download" + (error.isEmpty ? "" : ": \(error)")
            }
        }

        var kindText: String {
            if kind == "book" { return author.isEmpty ? "Audiobook" : "Audiobook by \(author)" }
            return hasAD ? "With description" : "Without description"
        }
    }

    /// One entry of the saved list: one that can't be read is left out, not the whole list.
    private struct Loose: Decodable {
        let saved: Saved?
        init(from decoder: Decoder) throws { saved = try? Saved(from: decoder) }
    }

    @Published private(set) var items: [Saved] = []
    /// "Download on Wi-Fi only" (on unless turned off): with mobile data, downloads wait.
    @Published var wifiOnly: Bool {
        didSet {
            guard wifiOnly != oldValue else { return }
            UserDefaults.standard.set(wifiOnly, forKey: "dlWifiOnly")
            fetcher.setWifiOnly(wifiOnly)
            updateWait()
        }
    }
    /// Downloads are waiting: Wi-Fi only is on and the phone is on mobile data.
    @Published private(set) var wifiWait = false
    nonisolated(unsafe) static var waitingForWiFi = false

    var api: @MainActor () -> API? = { nil }
    var say: @MainActor (String) -> Void = { _ in }

    private var preparing = Set<String>()
    private let fetcher = Fetcher()
    private let monitor = NWPathMonitor()
    private var onExpensive = false
    /// False while the list couldn't be read (the phone still locked): it isn't written over then.
    private var canSave = false

    // MARK: where things are kept

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let f = base.appendingPathComponent("offline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: f.path) {
            try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            var g = f
            try? g.setResourceValues(v)
        }
        return f
    }

    /// A download's folder: always worked out again from the app's own folder (it can move when the app is
    /// installed again), never kept as a full path.
    nonisolated static func dir(_ kind: String, _ item: String) -> URL {
        folder.appendingPathComponent(dirName(kind, item), isDirectory: true)
    }

    nonisolated static func dirName(_ kind: String, _ item: String) -> String {
        kind + "_" + item.replacingOccurrences(of: "/", with: "_")
    }

    private static var store: URL { folder.appendingPathComponent("downloads.json") }
    private static var backup: URL { folder.appendingPathComponent("downloads.json.bak") }
    private static var broken: URL { folder.appendingPathComponent("downloads.json.bad") }

    /// For the cover: no sign-in, no cookies.
    nonisolated static let plain: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        API.noCookies(c)
        return URLSession(configuration: c)
    }()

    nonisolated static func size(_ b: Int64) -> String {
        if b >= 1_000_000_000 { return String(format: "%.2f GB", Double(b) / 1e9) }
        if b >= 10_000_000 { return "\(b / 1_000_000) MB" }
        if b >= 1_000_000 { return String(format: "%.1f MB", Double(b) / 1e6) }
        return "\(max(1, b / 1000)) KB"
    }

    nonisolated static func fileSize(_ f: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private init() {
        _wifiOnly = Published(initialValue: UserDefaults.standard.object(forKey: "dlWifiOnly") as? Bool ?? true)
        let tidy = load()
        fetcher.finished = { [weak self] key, index, outcome in
            Task { @MainActor in self?.partFinished(key, index, outcome) }
        }
        fetcher.progress = { [weak self] key, index, got, total in
            Task { @MainActor in self?.partProgress(key, index, got: got, total: total) }
        }
        fetcher.start(wifiOnly: wifiOnly)
        if tidy { tidyFolders() }
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.status == .satisfied && path.isExpensive
            Task { @MainActor in self?.networkChanged(expensive: expensive) }
        }
        monitor.start(queue: DispatchQueue(label: "offline.network"))
    }

    /// Reads the list. True when it was read whole (so folders not in it can be tidied away).
    @discardableResult
    private func load() -> Bool {
        let fm = FileManager.default
        let main = Offline.store, bak = Offline.backup
        if !fm.fileExists(atPath: main.path) && !fm.fileExists(atPath: bak.path) { canSave = true; return true }
        for f in [main, bak] where fm.fileExists(atPath: f.path) {
            let data: Data
            do { data = try Data(contentsOf: f) } catch {
                if f == main { return false }        // can't be read right now: left as it is, and not written over
                continue
            }
            guard let list = try? JSONDecoder().decode([Loose].self, from: data) else {
                if f == main {                       // spoiled: kept aside, then the copy from before is tried
                    try? fm.removeItem(at: Offline.broken)
                    try? fm.copyItem(at: main, to: Offline.broken)
                }
                continue
            }
            let read = list.compactMap { $0.saved }
            items = read + items.filter { have in !read.contains { $0.id == have.id } }
            canSave = true
            let whole = f == main && read.count == list.count
            if f == main {
                // a copy of the list as it was read, in case the next one is spoiled
                try? fm.removeItem(at: bak)
                try? fm.copyItem(at: main, to: bak)
            } else {
                save()
            }
            return whole
        }
        // neither could be read as a list (the spoiled one is kept as downloads.json.bad): it starts again
        canSave = true
        return false
    }

    private func save() {
        guard canSave else { return }
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: Offline.store, options: .atomic) }
    }

    /// Download folders that aren't in the list any more (left behind): removed.
    private func tidyFolders() {
        let keep = Set(items.map { Offline.dirName($0.kind, $0.item) })
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: Offline.folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for f in all where (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if !keep.contains(f.lastPathComponent) { try? fm.removeItem(at: f) }
        }
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

    // MARK: Wi-Fi only, and room on the phone

    private func networkChanged(expensive: Bool) {
        onExpensive = expensive
        updateWait()
    }

    private func updateWait() {
        let w = wifiOnly && onExpensive
        Offline.waitingForWiFi = w
        if w != wifiWait { wifiWait = w }
    }

    /// Not enough room on the phone for this many bytes? Then what to say.
    private func noRoom(_ need: Int64) -> String? {
        #if os(tvOS)
        return nil                                   // (the Apple TV app doesn't download)
        #else
        guard need > 0,
              let free = (try? Offline.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage, free > 0 else { return nil }
        return free < need + 50_000_000 ? "not enough space on the phone (needs \(Offline.size(need)))" : nil
        #endif
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
        var askedAgain = false
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
                    let need = Int64(d.bytes ?? 0)
                    if let room = noRoom(need) {
                        // (the PC keeps its copy until it's removed here)
                        update(key) { $0.state = "failed"; $0.error = room; $0.job = d.id }
                        say("\(now.title) didn't download: \(room).")
                        return
                    }
                    let ext = url.hasSuffix(".mp4") ? "mp4" : "m4a"
                    update(key) {
                        $0.state = "downloading"; $0.progress = 0; $0.job = d.id
                        $0.parts = [Part(url: url, file: "audio.\(ext)", bytes: need)]
                        if let r = d.runtimeTicks { $0.runtime = r / 10_000_000 }
                        if need > 0 { $0.bytes = need }
                    }
                    startParts(key)
                    return
                }
                update(key) { $0.progress = Int(d.progress ?? 0); $0.job = d.id }
                try await Task.sleep(nanoseconds: 3_000_000_000)
                do {
                    d = try await api.get("api/play/download/job/\(d.id)", as: DownloadJob.self)
                } catch APIError.server(_) where !askedAgain {
                    // the PC forgot it (it restarted): ask once more
                    askedAgain = true
                    d = try await api.post("api/play/download/prepare", ["item": s.item, "kind": "audio"], as: DownloadJob.self)
                }
            }
        } catch is CancellationError {
            return
        } catch APIError.server(let message) {
            update(key) { $0.state = "failed"; $0.error = message }
            say("\(s.title) didn't download: \(message)")
        } catch {
            // no connection right now: it carries on when the connection is back, or the app is next open
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
                        if let res = try? await Offline.plain.data(from: u), (res.1 as? HTTPURLResponse)?.statusCode == 200 {
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

    /// Hands the parts not on the phone yet to iOS's downloader (a part already on its way isn't started twice).
    private func startParts(_ key: String) {
        guard let s = items.first(where: { $0.id == key }), s.state == "downloading", let api = api() else { return }
        let d = Offline.dir(s.kind, s.item)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (i, p) in s.parts.enumerated() where !p.done {
            guard let u = api.media(p.url) else { continue }
            fetcher.fetch(u, tag: "\(key)#\(i)", to: Offline.dirName(s.kind, s.item) + "/" + p.file)
        }
        checkDone(key)
    }

    private func partProgress(_ key: String, _ index: Int, got: Int64, total: Int64) {
        guard let s = items.first(where: { $0.id == key }), s.state == "downloading" else { return }
        let n = max(1, s.parts.count)
        let doneParts = s.parts.filter { $0.done }.count
        let part = total > 0 ? Double(got) / Double(total) : 0
        let pct = min(99, Int((Double(doneParts) + part) / Double(n) * 100))
        if pct != s.progress, let i = items.firstIndex(where: { $0.id == key }) { items[i].progress = pct }   // saved with the next change
    }

    private func partFinished(_ key: String, _ index: Int, _ outcome: Fetcher.Outcome) {
        guard let s = items.first(where: { $0.id == key }), s.state == "downloading", index < s.parts.count else { return }
        switch outcome {
        case .ok:
            // the size the PC said (a Wi-Fi sign-in page answering instead isn't kept as the audio)
            let f = Offline.dir(s.kind, s.item).appendingPathComponent(s.parts[index].file)
            let want = s.parts[index].bytes
            if want > 0 && Offline.fileSize(f) != want {
                try? FileManager.default.removeItem(at: f)
                stopped(key, "it didn't come through whole")
                return
            }
            update(key) { $0.parts[index].done = true; $0.tries = 0; $0.error = "" }
            checkDone(key)
        case .again:
            startParts(key)
        case .missing:
            if s.kind == "audio" && s.tries < 3 {
                // the PC tidied its copy away: it's asked to make it again
                fetcher.cancel(prefix: key + "#")
                try? FileManager.default.removeItem(at: Offline.dir(s.kind, s.item))
                update(key) { $0.state = "preparing"; $0.parts = []; $0.job = ""; $0.progress = 0; $0.tries += 1 }
                Task { await prepare(key) }
            } else {
                let why = "the PC doesn't have that file any more"
                update(key) { $0.state = "failed"; $0.error = why }
                say("\(s.title) didn't download: \(why).")
            }
        case .stopped(let why):
            stopped(key, why)
        }
    }

    /// Stopped part way (no connection, the PC was off...): tried again a few times, then when the app is next open.
    private func stopped(_ key: String, _ why: String?) {
        update(key) { $0.tries += 1 }
        if (items.first { $0.id == key }?.tries ?? 0) <= 5 {
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self.startParts(key)
            }
        } else if why != nil {
            update(key) { $0.error = "it keeps stopping - it tries again when the app is next open" }
        }
    }

    private func checkDone(_ key: String) {
        guard let s = items.first(where: { $0.id == key }), s.state == "downloading", !s.parts.isEmpty else { return }
        let d = Offline.dir(s.kind, s.item)
        let all = s.parts.allSatisfy { p in p.done && FileManager.default.fileExists(atPath: d.appendingPathComponent(p.file).path) }
        guard all else { return }
        let bytes = s.parts.reduce(Int64(0)) { sum, p in sum + max(0, Offline.fileSize(d.appendingPathComponent(p.file))) }
        update(key) { $0.state = "done"; $0.progress = 100; $0.bytes = bytes; $0.error = ""; $0.tries = 0 }
        say("\(s.title) is downloaded.")
        if !s.job.isEmpty { tellPC(s.job, "done") }             // the PC deletes its copy now
    }

    /// When the app opens (or the connection is back): carry on with any that weren't finished.
    func resume() {
        if !canSave { load() }                                  // couldn't be read before (the phone was locked)
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
            // the PC is asked again (its copy may have been tidied away meanwhile)
            fetcher.cancel(prefix: s.id + "#")
            update(s.id) { $0.state = "preparing"; $0.parts = []; $0.progress = 0; $0.error = ""; $0.tries = 0 }
            Task { await prepare(s.id) }
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

    /// Tells the PC this phone doesn't want its copy any more (it has it, or stopped). It's kept first, so with no
    /// connection (or the app only woken by iOS to finish a download) it's told later.
    private func tellPC(_ job: String, _ what: String) {
        guard !job.isEmpty else { return }
        Offline.keepStop(job, what, true)
        guard let api = api() else { return }
        Task {
            if (try? await api.post("api/play/download/\(what)", ["id": job], as: MessageResponse.self)) != nil {
                Offline.keepStop(job, what, false)
            }
        }
    }

    /// The ones the PC hasn't been told about yet: "done|<job>" or "cancel|<job>" (just "<job>": cancel, from before).
    private static func keepStop(_ job: String, _ what: String, _ keep: Bool) {
        var left = UserDefaults.standard.stringArray(forKey: "offlineStops") ?? []
        left.removeAll { $0 == job || $0.hasSuffix("|" + job) }
        if keep { left.append(what + "|" + job) }
        UserDefaults.standard.set(left, forKey: "offlineStops")
    }

    private func flushStops() {
        guard api() != nil else { return }
        for entry in UserDefaults.standard.stringArray(forKey: "offlineStops") ?? [] {
            let p = entry.components(separatedBy: "|")
            if p.count == 2 { tellPC(p[1], p[0] == "done" ? "done" : "cancel") } else { tellPC(entry, "cancel") }
        }
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

// A field missing from the saved list (an older or newer app wrote it) takes its default, not the whole list.
extension Offline.Part {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        file = try c.decode(String.self, forKey: .file)
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
        bytes = (try? c.decodeIfPresent(Int64.self, forKey: .bytes)) ?? 0
    }
}

extension Offline.Saved {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(String.self, forKey: .item)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "audio"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "preparing"
        progress = (try? c.decodeIfPresent(Int.self, forKey: .progress)) ?? 0
        bytes = (try? c.decodeIfPresent(Int64.self, forKey: .bytes)) ?? 0
        job = (try? c.decodeIfPresent(String.self, forKey: .job)) ?? ""
        itemType = (try? c.decodeIfPresent(String.self, forKey: .itemType)) ?? ""
        hasNext = (try? c.decodeIfPresent(Bool.self, forKey: .hasNext)) ?? false
        hasAD = (try? c.decodeIfPresent(Bool.self, forKey: .hasAD)) ?? true
        runtime = (try? c.decodeIfPresent(Double.self, forKey: .runtime)) ?? 0
        author = (try? c.decodeIfPresent(String.self, forKey: .author)) ?? ""
        parts = (try? c.decodeIfPresent([Offline.Part].self, forKey: .parts)) ?? []
        detail = try? c.decodeIfPresent(Data.self, forKey: .detail)
        pos = (try? c.decodeIfPresent(Double.self, forKey: .pos)) ?? 0
        posAt = (try? c.decodeIfPresent(Double.self, forKey: .posAt)) ?? 0
        error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? ""
        tries = (try? c.decodeIfPresent(Int.self, forKey: .tries)) ?? 0
    }
}

/// iOS's background downloader: the files keep coming with the app in the background or closed.
/// Two of them: one that waits for Wi-Fi ("Download on Wi-Fi only"), and one that uses mobile data too (a background
/// downloader's settings can't change once made, so a download moves from one to the other, carrying on).
final class Fetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "com.home.adplayer.downloads"
    static let wifiIdentifier = "com.home.adplayer.downloads.wifi"
    /// Set by the app when iOS wakes it for finished downloads (one for each downloader); called once handled.
    nonisolated(unsafe) static var backgroundDone: [String: () -> Void] = [:]

    enum Outcome {
        case ok
        case stopped(String?)     // tried again in a while
        case again                // started again now (moved to the other downloader)
        case missing              // the PC doesn't have the file (404)
    }

    var finished: (String, Int, Outcome) -> Void = { _, _, _ in }
    var progress: (String, Int, Int64, Int64) -> Void = { _, _, _, _ in }

    private var anyNet: URLSession!
    private var wifiNet: URLSession!
    private let queue = DispatchQueue(label: "fetcher")
    private let lock = NSLock()
    // (only on queue) the part each download task is fetching: tag -> task; and those asked for before the
    // downloads from before were known
    private var active: [String: String] = [:]
    private var ready = false
    private var listsLeft = 2
    private var waiting: [(URL, String, String)] = []
    // (under lock)
    private var wifiOnly = true
    private var dropped = Set<String>()      // tasks stopped for good (the download was removed)
    private var moving = Set<String>()       // tasks stopped to move to the other downloader
    private var lastTick = [String: Date]()

    private static func config(_ id: String, wifiOnly: Bool) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.background(withIdentifier: id)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.allowsCellularAccess = !wifiOnly
        c.allowsExpensiveNetworkAccess = !wifiOnly
        c.allowsConstrainedNetworkAccess = true
        c.timeoutIntervalForResource = 7 * 24 * 3600
        API.noCookies(c)
        return c
    }

    func start(wifiOnly: Bool) {
        lock.lock(); self.wifiOnly = wifiOnly; lock.unlock()
        anyNet = URLSession(configuration: Fetcher.config(Fetcher.identifier, wifiOnly: false), delegate: self, delegateQueue: nil)
        wifiNet = URLSession(configuration: Fetcher.config(Fetcher.wifiIdentifier, wifiOnly: true), delegate: self, delegateQueue: nil)
        // what's on its way from before is known before anything new starts
        for s in [anyNet!, wifiNet!] {
            s.getAllTasks { tasks in
                let found = tasks.filter { $0.state == .running || $0.state == .suspended }
                    .compactMap { t in self.parse(t).map { ($0.tag, self.name(t, in: s)) } }
                self.queue.async {
                    for (tag, n) in found where self.active[tag] == nil { self.active[tag] = n }
                    self.listsLeft -= 1
                    guard self.listsLeft == 0 else { return }
                    self.ready = true
                    let asked = self.waiting
                    self.waiting = []
                    for (u, tag, dest) in asked { self.fetchNow(u, tag: tag, to: dest) }
                    self.moveTasks()
                }
            }
        }
    }

    private var current: URLSession {
        lock.lock(); defer { lock.unlock() }
        return wifiOnly ? wifiNet : anyNet
    }

    private func name(_ t: URLSessionTask, in s: URLSession) -> String {
        "\(s.configuration.identifier ?? "")#\(t.taskIdentifier)"
    }

    /// "Download on Wi-Fi only" turned on or off: what's on its way moves to the other downloader.
    func setWifiOnly(_ on: Bool) {
        lock.lock(); wifiOnly = on; lock.unlock()
        queue.async { self.moveTasks() }
    }

    private func moveTasks() {
        lock.lock(); let other: URLSession = wifiOnly ? anyNet : wifiNet; lock.unlock()
        other.getAllTasks { tasks in
            for t in tasks where t.state == .running || t.state == .suspended {
                guard let d = t as? URLSessionDownloadTask, let p = self.parse(t) else { continue }
                let n = self.name(t, in: other)
                self.lock.lock(); self.moving.insert(n); self.lock.unlock()
                let was = t.originalRequest?.url
                d.cancel(byProducingResumeData: { data in
                    if let data = data { self.keepResume(data, for: p.dest, url: was) }
                    self.queue.async { if self.active[p.tag] == n { self.active[p.tag] = nil } }
                    self.finished(p.key, p.index, .again)
                })
            }
        }
    }

    /// Starts fetching url into dest (a path in the downloads folder), carrying on from where it stopped when it
    /// can. Nothing happens if that part is already on its way.
    func fetch(_ url: URL, tag: String, to dest: String) {
        queue.async { self.fetchNow(url, tag: tag, to: dest) }
    }

    /// (on queue: one at a time, so a part is never fetched twice at once)
    private func fetchNow(_ url: URL, tag: String, to dest: String) {
        if !ready {
            if !waiting.contains(where: { $0.1 == tag }) { waiting.append((url, tag, dest)) }
            return
        }
        if active[tag] != nil { return }
        let session = current
        let file = Fetcher.resolve(dest)
        var task: URLSessionDownloadTask?
        if let data = takeResume(file, url: url) { task = session.downloadTask(withResumeData: data) }
        if task == nil {
            var r = URLRequest(url: url)
            r.httpShouldHandleCookies = false
            if !API.token.isEmpty { r.setValue(API.token, forHTTPHeaderField: "X-ADP-Token") }
            task = session.downloadTask(with: r)
        }
        guard let t = task else { return }
        t.taskDescription = tag + "|>" + dest
        active[tag] = name(t, in: session)
        t.resume()
    }

    func cancel(prefix: String) {
        queue.async {
            for tag in self.active.keys where tag.hasPrefix(prefix) { self.active[tag] = nil }
            self.waiting.removeAll { $0.1.hasPrefix(prefix) }
        }
        for s in [anyNet!, wifiNet!] {
            s.getAllTasks { tasks in
                for t in tasks where (t.taskDescription ?? "").hasPrefix(prefix) {
                    self.lock.lock(); self.dropped.insert(self.name(t, in: s)); self.lock.unlock()
                    t.cancel()
                }
            }
        }
    }

    // MARK: carrying on where it stopped

    /// A path kept in the task (in the downloads folder) -> where it is now. (Full paths: from before 1.9.)
    nonisolated static func resolve(_ dest: String) -> URL {
        dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : Offline.folder.appendingPathComponent(dest)
    }

    /// Keeps what iOS gives to carry on a download that stopped (beside the file; only while the download is kept).
    private func keepResume(_ data: Data, for dest: String, url: URL?) {
        let f = Fetcher.resolve(dest)
        guard FileManager.default.fileExists(atPath: f.deletingLastPathComponent().path) else { return }
        try? data.write(to: URL(fileURLWithPath: f.path + ".resume"), options: .atomic)
        try? (url?.absoluteString ?? "").write(to: URL(fileURLWithPath: f.path + ".resumeurl"), atomically: true, encoding: .utf8)
    }

    /// Used once: if carrying on doesn't work, the part starts again next time. Only for the same address
    /// (at home and away it's fetched from different addresses).
    private func takeResume(_ file: URL, url: URL) -> Data? {
        let r = URL(fileURLWithPath: file.path + ".resume"), u = URL(fileURLWithPath: file.path + ".resumeurl")
        defer { try? FileManager.default.removeItem(at: r); try? FileManager.default.removeItem(at: u) }
        guard let data = try? Data(contentsOf: r), !data.isEmpty,
              (try? String(contentsOf: u, encoding: .utf8)) == url.absoluteString else { return nil }
        return data
    }

    private func parse(_ task: URLSessionTask) -> (tag: String, key: String, index: Int, dest: String)? {
        guard let d = task.taskDescription else { return nil }
        let a = d.components(separatedBy: "|>")
        guard a.count == 2 else { return nil }
        let b = a[0].components(separatedBy: "#")
        guard b.count == 2, let i = Int(b[1]) else { return nil }
        return (a[0], b[0], i, a[1])
    }

    private func ended(_ task: URLSessionTask, _ session: URLSession, _ tag: String) {
        let n = name(task, in: session)
        queue.async { if self.active[tag] == n { self.active[tag] = nil } }
    }

    // MARK: what iOS's downloader says

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let p = parse(downloadTask) else { return }
        ended(downloadTask, session, p.tag)
        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 404 { finished(p.key, p.index, .missing); return }
        guard status == 200 || status == 206 else {
            finished(p.key, p.index, .stopped("the PC answered \(status)"))
            return
        }
        if (http?.mimeType ?? "").lowercased().hasPrefix("text/html") {
            finished(p.key, p.index, .stopped("a web page came instead - does this Wi-Fi need signing in to?"))
            return
        }
        // the whole file: its size, as the answer said
        var want = http?.expectedContentLength ?? -1
        if status == 206, let range = http?.value(forHTTPHeaderField: "Content-Range"),
           let total = Int64(range.components(separatedBy: "/").last ?? "") { want = total }
        let got = Offline.fileSize(location)
        if want > 0 && got != want {
            finished(p.key, p.index, .stopped("it didn't come through whole"))
            return
        }
        let dest = Fetcher.resolve(p.dest)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        finished(p.key, p.index, ok ? .ok : .stopped("couldn't keep the file"))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let p = parse(downloadTask) else { return }
        let n = name(downloadTask, in: session)
        lock.lock()
        let last = lastTick[n] ?? .distantPast
        let due = Date().timeIntervalSince(last) > 1
        if due { lastTick[n] = Date() }
        lock.unlock()
        if due { progress(p.key, p.index, totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = parse(task) else { return }
        let n = name(task, in: session)
        lock.lock()
        let gone = dropped.remove(n) != nil
        let moved = moving.remove(n) != nil
        lastTick[n] = nil
        lock.unlock()
        ended(task, session, p.tag)
        guard let error = error, !gone, !moved else { return }
        // stopped part way (the connection went, or the app was swiped closed): carried on from there next time
        let ns = error as NSError
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            keepResume(data, for: p.dest, url: task.originalRequest?.url)
        }
        finished(p.key, p.index, .stopped(error.localizedDescription))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let id = session.configuration.identifier ?? ""
        DispatchQueue.main.async {
            Fetcher.backgroundDone.removeValue(forKey: id)?()
        }
    }
}
