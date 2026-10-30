import Foundation
import AVFoundation
import MediaPlayer

/// "Listen on this phone": plays just the audio description track, using Apple's own player.
/// It starts streaming from the PC straight away, and meanwhile downloads the whole track to the phone;
/// once that's done it plays from the phone itself, so a weak signal or a change of network doesn't matter.
/// If the connection drops before that, it tries again by itself from the same place.
/// Keeps playing with the screen locked, and works with the lock screen, Control Center, headphones and AirPlay.
@MainActor
final class PhonePlayer: ObservableObject {
    @Published private(set) var active = false        // something is loaded: getting ready, playing or paused
    @Published private(set) var preparing = false
    @Published private(set) var progress = 0
    @Published private(set) var title = ""
    @Published private(set) var paused = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var hasNext = false
    @Published private(set) var hasAD = true
    @Published private(set) var reconnecting = false

    var api: @MainActor () -> API? = { nil }
    var say: @MainActor (String) -> Void = { _ in }
    var onEnded: @MainActor () -> Void = {}
    /// Set while playing together: the end of an episode goes to the shared clock instead of straight to the next one.
    var togetherEnded: (@MainActor () -> Void)?

    private var player: AVPlayer?
    private var itemID: String?
    private var jobID: String?
    private var mediaPath: String?                    // the stream on the PC
    private var localFile: URL?                       // the whole track, once it's on the phone
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var lastSave = Date.distantPast
    private var startTask: Task<Void, Never>?
    private var wholeTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = 0
    private var didStart = false
    private var retries = 0
    private var together = false
    private var pendingStart: Double = 0

    init() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            // after a phone call or Siri: carry on if iOS says to
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) else { return }
            Task { @MainActor in
                guard let self = self, self.active, !self.together else { return }
                self.player?.play()
            }
        }
    }

    var statusText: String {
        if !active { return "Nothing is playing on this phone." }
        if preparing {
            return progress > 0 ? "Getting the audio of \(title) ready… \(progress) percent." : "Getting the audio of \(title) ready…"
        }
        if reconnecting { return "The connection dropped - carrying on as soon as it's back. \(title)." }
        let start = "\(paused ? "Paused" : "Playing") on this phone: \(title)."
        return duration > 0 ? start + " \(Speak.position(position)) of \(Speak.duration(duration))." : start
    }

    /// Ready to play (for playing together).
    var ready: Bool { active && didStart && !preparing && player != nil }

    /// Waiting for more of the audio to arrive.
    var buffering: Bool {
        guard let p = player, didStart else { return false }
        return p.timeControlStatus == .waitingToPlayAtSpecifiedRate || reconnecting
    }

    var currentItemID: String? { itemID }

    func currentTime() -> Double {
        let t = player?.currentTime().seconds ?? position
        return t.isFinite ? t : position
    }

    // MARK: starting

    /// together: the place to get ready at, without playing (the shared clock says when).
    func start(_ item: Item, resume: Bool, together startAt: Double? = nil) {
        stop(saving: true, quiet: true, notify: false)
        guard let api = api() else { return }
        generation += 1
        let gen = generation
        together = startAt != nil
        configureAudioSession()
        active = true
        preparing = true
        progress = 0
        title = item.label
        paused = startAt != nil
        position = 0
        duration = 0
        hasNext = item.type == "Episode"
        hasAD = true
        itemID = item.id
        if !together { say("Getting the audio of \(item.label) ready.") }

        startTask = Task { [weak self] in
            do {
                var job = try await api.post("api/play/listen/prepare",
                                             ["item": item.id, "fmt": "hls", "any": startAt != nil ? "1" : "0"], as: ListenJob.self)
                guard let self = self, gen == self.generation else { return }
                let resumeAt = startAt ?? (resume ? (job.resumeTicks ?? 0) / 10_000_000 : 0)
                self.title = job.title ?? item.label
                self.duration = (job.runtimeTicks ?? 0) / 10_000_000
                self.hasNext = job.hasNext ?? self.hasNext
                self.hasAD = job.hasAD ?? true
                self.jobID = job.id
                // The PC makes the audio in small pieces; playing can start once the first ones exist
                // (or, when carrying on part way through, once it has got past that point).
                while true {
                    if job.state == "failed" { throw APIError.server(job.error ?? "Couldn't get the audio ready.") }
                    let farEnough = resumeAt <= 5 || (job.encodedSeconds ?? 0) >= resumeAt + 15
                    // playing together: the whole audio comes onto the phone first (so the network can't make
                    // anyone wait later); on her own it starts as soon as the first part is made
                    if startAt != nil {
                        if job.state == "ready" && job.fullURL != nil { break }
                    } else if job.url != nil && (job.state == "ready" || ((job.playable ?? false) && farEnough)) { break }
                    self.progress = Int(job.progress ?? 0)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard gen == self.generation else { return }
                    job = try await api.get("api/play/listen/job/\(job.id)", as: ListenJob.self)
                    guard gen == self.generation else { return }
                }
                if startAt != nil, let full = job.fullURL, let fullURL = api.media(full) {
                    self.progress = 100
                    var file: URL?
                    for _ in 0..<20 {
                        file = await Downloads.get(fullURL, name: "\(job.id).m4a")
                        if file != nil || gen != self.generation { break }
                        try await Task.sleep(nanoseconds: 3_000_000_000)    // the connection dropped: try again
                    }
                    guard gen == self.generation else { return }
                    if let f = file {
                        self.localFile = f
                        self.mediaPath = job.url
                        self.begin(url: f, at: startAt ?? 0, gen: gen, play: false, announce: false)
                        return
                    }
                }
                guard let path = job.url, let url = api.media(path) else { throw APIError.server("Couldn't get the audio ready.") }
                self.mediaPath = path
                let at = startAt ?? (resumeAt > 5 ? resumeAt : 0)
                self.begin(url: url, at: at, gen: gen, play: startAt == nil, announce: startAt == nil)
                self.fetchWhole(gen: gen)
            } catch is CancellationError {
                return
            } catch {
                guard let self = self, gen == self.generation else { return }
                let message = error.localizedDescription
                self.stop(saving: false, quiet: true, notify: true)
                self.say(message)
            }
        }
    }

    private func begin(url: URL, at start: Double, gen: Int, play: Bool, announce: Bool) {
        pendingStart = start
        let item = AVPlayerItem(url: url)
        // Ask for about 10 minutes loaded ahead, so skipping and a weak signal don't stop it.
        item.preferredForwardBufferDuration = 600
        item.audioTimePitchAlgorithm = .timeDomain
        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        player = p
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            Task { @MainActor in self?.itemStatusChanged(status, gen: gen, start: start, play: play, announce: announce) }
        }
        controlObservation = p.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let status = observed.timeControlStatus
            Task { @MainActor in self?.controlChanged(status) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finished() }
        }
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lostConnection(gen: gen) }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, gen: Int, start: Double, play: Bool, announce: Bool) {
        guard gen == generation, let p = player else { return }
        if status == .failed {
            if retries < 60 && localFile == nil { lostConnection(gen: gen); return }
            stop(saving: false, quiet: true, notify: true)
            say("This phone couldn't play the audio.")
            return
        }
        guard status == .readyToPlay, !didStart else { return }
        p.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, gen == self.generation else { return }
                self.didStart = true
                self.preparing = false
                if self.reconnecting { self.say("Back again.") }
                self.reconnecting = false
                self.retries = 0
                self.position = start
                if play { self.player?.play() }
                self.updateNowPlaying()
                if announce {
                    let from = start > 0 ? " from \(Speak.position(start))" : ""
                    self.say("Playing \(self.title) on this phone\(from)" + (self.hasAD ? ", with audio description." : "."))
                }
            }
        }
    }

    private func controlChanged(_ status: AVPlayer.TimeControlStatus) {
        paused = status == .paused
        updateNowPlaying()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, didStart else { return }
        position = seconds
        if player?.timeControlStatus == .playing && Date().timeIntervalSince(lastSave) > 30 { save(finished: false) }
    }

    // MARK: staying up when the connection drops

    /// Builds the player again at the same place, from the phone's own copy if there is one, else from the PC.
    private func reload(play: Bool) {
        guard active, let api = api() else { return }
        let at = didStart ? currentTime() : pendingStart
        let url: URL?
        if let f = localFile { url = f } else if let path = mediaPath { url = api.media(path) } else { url = nil }
        guard let url = url else { return }
        generation += 1
        let gen = generation
        tearDown()
        position = at
        begin(url: url, at: at, gen: gen, play: play, announce: false)
    }

    private func lostConnection(gen: Int) {
        guard gen == generation, active, retryTask == nil else { return }
        let wasPlaying = !paused || (player?.rate ?? 0) != 0
        retries += 1
        if !reconnecting && !together { say("The connection dropped - carrying on as soon as it's back.") }
        reconnecting = true
        let wait = UInt64(min(10, retries)) * 1_000_000_000
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard let self = self else { return }
            self.retryTask = nil
            guard self.active, self.reconnecting else { return }
            self.reload(play: wasPlaying && !self.together)
        }
    }

    /// The phone found a network again: don't wait for the next try.
    func networkBack() {
        guard active, reconnecting else { return }
        retryTask?.cancel()
        retryTask = nil
        reload(play: !together)
    }

    /// The PC's address changed (home Wi-Fi / away): carry on from the same place at the new address.
    func rebase() {
        guard active, !preparing, didStart, localFile == nil else { return }
        reload(play: (player?.rate ?? 0) != 0)
    }

    /// Downloads the whole track in the background, then plays from the phone's copy.
    private func fetchWhole(gen: Int) {
        wholeTask?.cancel()
        guard let id = jobID else { return }
        wholeTask = Task { [weak self] in
            var tries = 0
            while tries < 900 {
                tries += 1
                guard let self = self, self.active, self.jobID == id, let api = self.api() else { return }
                if let job = try? await api.get("api/play/listen/job/\(id)", as: ListenJob.self) {
                    if job.state == "failed" { return }
                    if let full = job.fullURL, let url = api.media(full),
                       let file = await Downloads.get(url, name: "\(id).m4a") {
                        guard self.active, self.jobID == id else { return }
                        self.useLocal(file)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: tries < 30 ? 4_000_000_000 : 15_000_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    private func useLocal(_ file: URL) {
        guard localFile == nil else { return }
        localFile = file
        if !didStart || preparing { return }                       // it starts from the copy when it's ready
        reload(play: (player?.rate ?? 0) != 0)
    }

    // MARK: buttons

    func togglePause(quiet: Bool = false) {
        guard let p = player, didStart else { return }
        if p.timeControlStatus == .paused {
            p.play()
            if !quiet { say("Playing.") }
        } else {
            pause(quiet: quiet)
        }
    }

    func pause(quiet: Bool = false) {
        guard let p = player, didStart else { return }
        p.pause()
        save(finished: false)
        if !quiet { say("Paused.") }
    }

    func play() {
        guard let p = player, didStart else { return }
        if reconnecting { networkBack(); return }
        p.play()
    }

    /// Playing together: plays at this speed (a little faster or slower evens out small differences).
    func play(rate: Double) {
        guard let p = player, didStart else { return }
        p.rate = Float(rate)
    }

    var rate: Double { Double(player?.rate ?? 0) }

    func skip(_ by: Double, quiet: Bool = false) {
        guard didStart else { return }
        var t = currentTime() + by
        if duration > 0 { t = min(t, max(0, duration - 5)) }
        t = max(0, t)
        seek(to: t, quiet: true)
        if !quiet { say("\(by < 0 ? "Back" : "Forward") \(Int(abs(by))) seconds. Now at \(Speak.position(t)).") }
    }

    func seek(to t: Double, quiet: Bool = false) {
        guard let p = player, didStart else { return }
        position = t
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
        if !quiet { say("Now at \(Speak.position(t)).") }
    }

    func next() {
        guard let api = api(), let id = itemID else { return }
        save(finished: false)
        let gen = generation
        Task {
            do {
                let r = try await api.get("api/play/listen/next", ["item": id], as: NextResponse.self)
                guard gen == self.generation else { return }
                if let n = r.item { self.start(n, resume: true) } else { self.say("There is no next episode with audio description.") }
            } catch {
                self.say(error.localizedDescription)
            }
        }
    }

    /// saving: keep her place in Emby. quiet: don't say "Stopped". notify: tell the app it's over (closes the controls).
    func stop(saving: Bool = true, quiet: Bool = false, notify: Bool = true) {
        let wasActive = active
        if saving && didStart { save(finished: false) }
        generation += 1
        startTask?.cancel()
        startTask = nil
        wholeTask?.cancel()
        wholeTask = nil
        retryTask?.cancel()
        retryTask = nil
        tearDown()
        itemID = nil
        jobID = nil
        mediaPath = nil
        localFile = nil
        active = false
        preparing = false
        paused = false
        reconnecting = false
        retries = 0
        together = false
        if wasActive { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        if wasActive && !quiet { say("Stopped.") }
        if wasActive && notify { onEnded() }
    }

    /// The app is going to the background: keep her place, just in case.
    func saveNow() {
        if didStart { save(finished: false) }
    }

    // MARK: the end of an episode or movie

    private func finished() {
        guard let id = itemID else { return }
        save(finished: true)
        if together, let ended = togetherEnded { ended(); return }
        let done = title
        let lookForNext = hasNext
        let gen = generation
        tearDown()
        guard lookForNext, let api = api() else {
            stop(saving: false, quiet: true, notify: true)
            say("Finished \(done).")
            return
        }
        preparing = true
        progress = 0
        title = "the next episode"
        Task {
            let r = try? await api.get("api/play/listen/next", ["item": id], as: NextResponse.self)
            guard gen == self.generation else { return }
            if let n = r?.item {
                self.start(n, resume: true)
            } else {
                self.stop(saving: false, quiet: true, notify: true)
                self.say("Finished \(done).")
            }
        }
    }

    // MARK: plumbing

    private func save(finished: Bool) {
        guard let api = api(), let id = itemID else { return }
        let t = currentTime()
        lastSave = Date()
        var form = ["item": id, "pos": String(format: "%.1f", t)]
        if finished { form["finished"] = "1" }
        Task { _ = try? await api.post("api/play/listen/save", form, as: MessageResponse.self) }
    }

    private func tearDown() {
        if let o = timeObserver { player?.removeTimeObserver(o) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        controlObservation?.invalidate()
        controlObservation = nil
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
        if let f = failObserver { NotificationCenter.default.removeObserver(f) }
        failObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        didStart = false
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    private func updateNowPlaying() {
        guard let p = player, didStart else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title,
                                   MPMediaItemPropertyArtist: hasAD ? "Audio description" : "Soundtrack"]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime()
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(p.rate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = hasNext
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = false
    }
}

/// The whole audio tracks kept on the phone (the last four).
enum Downloads {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let f = base.appendingPathComponent("listen", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    /// Downloads url as name (or finds it already there). Nil if it didn't finish (tried again later).
    static func get(_ url: URL, name: String) async -> URL? {
        let dest = folder.appendingPathComponent(name)
        if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber, size.intValue > 1000 {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return dest
        }
        var request = URLRequest(url: url)
        if !API.token.isEmpty { request.setValue(API.token, forHTTPHeaderField: "X-ADP-Token") }
        guard let result = try? await session.download(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: result.0, to: dest)) != nil else { return nil }
        prune()
        return dest
    }

    /// Downloads url to dest (or finds it already there). Nil if it didn't finish.
    static func fetch(_ url: URL, to dest: URL) async -> URL? {
        if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber, size.intValue > 1000 {
            return dest
        }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        var request = URLRequest(url: url)
        if !API.token.isEmpty { request.setValue(API.token, forHTTPHeaderField: "X-ADP-Token") }
        guard let result = try? await session.download(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: result.0, to: dest)) != nil else { return nil }
        return dest
    }

    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.filter { $0.pathExtension == "m4a" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for f in sorted.dropFirst(4) { try? fm.removeItem(at: f) }
    }
}

/// A book's pieces kept on the phone while it plays (the piece it's on and the next few); only the book playing keeps them.
enum BookParts {
    static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("bookparts", isDirectory: true)
    }

    static func dir(_ bookID: String) -> URL {
        folder.appendingPathComponent(bookID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    static func file(_ bookID: String, _ i: Int, _ url: String) -> URL {
        let ext = String((url.split(separator: "?").first ?? "").split(separator: ".").last ?? "mp3").prefix(4)
        return dir(bookID).appendingPathComponent("\(i).\(ext)")
    }

    static func have(_ bookID: String, _ i: Int, _ url: String) -> URL? {
        let f = file(bookID, i, url)
        let size = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? NSNumber
        return (size?.intValue ?? 0) > 1000 ? f : nil
    }

    static func keepOnly(_ bookID: String) {
        let keep = dir(bookID).lastPathComponent
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent != keep {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
