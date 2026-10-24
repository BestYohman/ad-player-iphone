import Foundation
import AVFoundation
import MediaPlayer
import UIKit

struct SleepChoice: Hashable {
    let value: String
    let label: String
}

/// Audiobooks on this phone. The book's own files are played one after another (passed through
/// the PC, which keeps the Audiobookshelf key), so skipping and speed are instant. Her place is
/// saved to Audiobookshelf, so its own apps carry on from the same spot.
@MainActor
final class BookPlayer: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var preparing = false
    @Published private(set) var bookID = ""
    @Published private(set) var title = ""
    @Published private(set) var author = ""
    @Published private(set) var paused = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var chapters: [BookChapter] = []
    @Published private(set) var sleepChoice = "off"
    @Published private(set) var speed: Double = BookPlayer.savedSpeed()

    var api: @MainActor () -> API? = { nil }
    var say: @MainActor (String) -> Void = { _ in }
    var onEnded: @MainActor () -> Void = {}

    nonisolated static let speeds: [Double] = [0.75, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    nonisolated static let sleepChoices: [SleepChoice] = [
        SleepChoice(value: "off", label: "Off"), SleepChoice(value: "15", label: "15 minutes"),
        SleepChoice(value: "30", label: "30 minutes"), SleepChoice(value: "45", label: "45 minutes"),
        SleepChoice(value: "60", label: "1 hour"), SleepChoice(value: "chapter", label: "End of this chapter")]

    private var tracks: [BookTrack] = []
    private var forceTx = Set<Int>()          // parts this phone couldn't play as they are: use the PC's MP3
    private var part = 0                      // which file is loaded
    private var base: Double = 0              // the PC's MP3 of a part starts part-way in: this far
    private var pendingOffset: Double = 0     // where in the part the one being loaded starts
    private var switching = false
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var generation = 0
    private var loadGeneration = 0
    private var lastSave = Date.distantPast
    private var sleepAt: Date?
    private var sleepPosition: Double?
    private var artwork: MPMediaItemArtwork?
    private var chapterShown = -2
    private var startTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            // after a phone call or Siri: carry on if iOS says to
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) else { return }
            Task { @MainActor in
                guard let self = self, self.active, !self.preparing else { return }
                self.play()
            }
        }
    }

    nonisolated private static func savedSpeed() -> Double {
        let v = UserDefaults.standard.double(forKey: "bookSpeed")
        return (v >= 0.5 && v <= 3) ? v : 1
    }

    nonisolated static func speedLabel(_ v: Double) -> String {
        v == 1 ? "Normal speed" : "\(number(v)) times"
    }

    nonisolated static func number(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Files iPhone plays as they are; anything else comes as MP3 from the PC.
    nonisolated static func playsDirectly(_ t: BookTrack) -> Bool {
        let codec = (t.codec ?? "").lowercased()
        if !codec.isEmpty {
            return ["mp3", "aac", "alac", "flac", "ac3", "eac3", "pcm_s16le", "pcm_s24le"].contains(codec)
        }
        let mime = (t.mime ?? "").lowercased()
        return mime.contains("mpeg") || mime.contains("mp4") || mime.contains("aac") || mime.contains("flac") || mime.contains("m4a")
    }

    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: what to say

    var statusText: String {
        if !active { return "Nothing is playing on this phone." }
        if preparing { return "Getting \(title) ready…" }
        var s = "\(paused ? "Paused" : "Playing") on this phone: \(title)" + (author.isEmpty ? "" : " by \(author)") + "."
        if let chapter = chapterSentence(position) { s += " " + chapter }
        if duration > 0 { s += " \(Speak.position(position)) of \(Speak.duration(duration))." }
        if speed != 1 { s += " Speed \(BookPlayer.number(speed)) times." }
        if let sleep = sleepText { s += " " + sleep }
        return s
    }

    var sleepText: String? {
        if let at = sleepAt { return "Pausing in \(Speak.count(max(1, Int((at.timeIntervalSinceNow / 60).rounded())), "minute"))." }
        if sleepPosition != nil { return "Pausing at the end of this chapter." }
        return nil
    }

    func chapterSentence(_ pos: Double) -> String? {
        guard let i = chapterIndex(pos) else { return nil }
        return "Chapter \(i + 1) of \(chapters.count): \(chapters[i].title)."
    }

    func chapterIndex(_ pos: Double) -> Int? {
        var found: Int?
        for (n, c) in chapters.enumerated() {
            if c.start <= pos + 0.5 { found = n } else { break }
        }
        return found
    }

    var hasNextChapter: Bool {
        guard !chapters.isEmpty else { return false }
        return (chapterIndex(currentTime()) ?? -1) < chapters.count - 1
    }

    /// Where she is in the whole book, in seconds.
    func currentTime() -> Double {
        guard active, !preparing, part < tracks.count else { return position }
        if switching { return tracks[part].start + pendingOffset }
        let t = player?.currentTime().seconds ?? 0
        return tracks[part].start + base + (t.isFinite ? t : 0)
    }

    private func partIndex(_ pos: Double) -> Int {
        var i = tracks.count - 1
        while i > 0 && pos < tracks[i].start - 0.01 { i -= 1 }
        return max(0, i)
    }

    // MARK: starting

    /// at: start here (seconds into the book), e.g. a chapter. Otherwise her place when resume is true.
    func start(id: String, label: String, resume: Bool, at: Double?) {
        if active && !preparing && bookID == id, let at = at {          // a chapter of the book that's playing
            seek(to: at)
            if paused { play() }
            say(chapterSentence(at) ?? "Playing from \(Speak.position(at)).")
            return
        }
        stop(saving: true, quiet: true, notify: false)
        guard let api = api() else { return }
        generation += 1
        let gen = generation
        configureAudioSession()
        active = true
        preparing = true
        bookID = id
        title = label
        author = ""
        paused = false
        position = 0
        duration = 0
        chapters = []
        tracks = []
        forceTx = []
        sleepAt = nil
        sleepPosition = nil
        sleepChoice = "off"
        artwork = nil
        chapterShown = -2
        say("Getting \(label) ready.")

        startTask = Task { [weak self] in
            do {
                let b = try await api.get("api/play/books/book", ["id": id], as: BookDetail.self)
                guard let self = self, gen == self.generation else { return }
                guard !b.tracks.isEmpty else { throw APIError.server("That book has no audio.") }
                self.title = b.title
                self.author = b.author ?? ""
                self.duration = b.duration
                self.chapters = b.chapters
                self.tracks = b.tracks
                var pos = at ?? ((resume && !b.finished) ? max(0, b.position - 2) : 0)
                if b.duration > 0 && pos >= b.duration - 2 { pos = 0 }
                self.position = pos
                let p = AVPlayer()
                p.allowsExternalPlayback = true
                p.defaultRate = Float(self.speed)
                self.player = p
                self.controlObservation = p.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
                    let status = observed.timeControlStatus
                    Task { @MainActor in self?.controlChanged(status) }
                }
                self.timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                let i = self.partIndex(pos)
                self.load(i, pos - self.tracks[i].start, play: true, announce: true)
                if let cover = b.cover { self.loadArtwork(api.media(cover), gen: gen) }
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

    /// Loads one file of the book, starting `offset` seconds into it.
    private func load(_ i: Int, _ offset: Double, play: Bool, announce: Bool = false) {
        guard let p = player, let api = api(), i >= 0, i < tracks.count else { return }
        let t = tracks[i]
        let off = max(0, min(offset, max(0, t.duration - 0.5)))
        part = i
        pendingOffset = off
        switching = true
        loadGeneration += 1
        let lg = loadGeneration
        let direct = !forceTx.contains(i) && BookPlayer.playsDirectly(t)
        base = direct ? 0 : off
        let path = direct ? t.url : t.tx + "?t=" + String(format: "%.1f", off)
        guard let url = api.media(path) else { return }
        statusObservation?.invalidate()
        statusObservation = nil
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        if direct { item.preferredForwardBufferDuration = 300 }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            Task { @MainActor in
                self?.itemStatusChanged(status, lg: lg, index: i, offset: off, direct: direct, play: play, announce: announce)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.partEnded(lg) }
        }
        p.replaceCurrentItem(with: item)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, lg: Int, index: Int, offset: Double, direct: Bool, play: Bool, announce: Bool) {
        guard lg == loadGeneration, let p = player else { return }
        if status == .failed {
            if direct {                                   // try the PC's MP3 of this part instead
                forceTx.insert(index)
                load(index, offset, play: play, announce: announce)
                return
            }
            let name = title
            stop(saving: false, quiet: true, notify: true)
            say("This phone couldn't play \(name).")
            return
        }
        guard status == .readyToPlay, switching else { return }
        if direct && offset > 0.5 {
            p.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.partReady(lg: lg, play: play, announce: announce) }
            }
        } else {
            partReady(lg: lg, play: play, announce: announce)
        }
    }

    private func partReady(lg: Int, play: Bool, announce: Bool) {
        guard lg == loadGeneration, let p = player else { return }
        switching = false
        preparing = false
        if play {
            p.defaultRate = Float(speed)
            p.play()
        }
        position = currentTime()
        updateNowPlaying()
        if announce {
            let pos = position
            say("Playing \(title)" + (author.isEmpty ? "" : " by \(author)") + " on this phone" +
                (pos > 5 ? " from \(Speak.position(pos))" : "") + ".")
        }
    }

    private func partEnded(_ lg: Int) {
        guard lg == loadGeneration, active else { return }
        if part + 1 < tracks.count {
            load(part + 1, 0, play: true)
            return
        }
        save(finished: true)
        let done = title
        stop(saving: false, quiet: true, notify: true)
        say("Finished \(done).")
    }

    private func controlChanged(_ status: AVPlayer.TimeControlStatus) {
        guard !switching else { return }
        paused = status == .paused
        updateNowPlaying()
    }

    private func tick() {
        guard active, !preparing, !switching else { return }
        position = currentTime()
        let playing = (player?.rate ?? 0) != 0
        if playing && Date().timeIntervalSince(lastSave) > 30 { save(finished: false) }
        let timeUp = sleepAt.map { Date() >= $0 } ?? false
        let chapterOver = sleepPosition.map { position >= $0 - 0.5 } ?? false
        if playing && (timeUp || chapterOver) {
            sleepAt = nil
            sleepPosition = nil
            sleepChoice = "off"
            pause(quiet: true)
            say("Sleep timer: paused.")
        }
        let shown = chapterIndex(position) ?? -1
        if shown != chapterShown {                         // a new chapter: show its name on the lock screen
            chapterShown = shown
            updateNowPlaying()
        }
    }

    // MARK: buttons

    func togglePause(quiet: Bool = false) {
        guard active, !preparing, let p = player else { return }
        if p.rate == 0 {
            play()
            if !quiet { say("Playing.") }
        } else {
            pause(quiet: quiet)
        }
    }

    func pause(quiet: Bool = false) {
        guard active, let p = player else { return }
        p.pause()
        save(finished: false)
        if !quiet { say("Paused.") }
    }

    func play() {
        guard active, !preparing, let p = player else { return }
        p.defaultRate = Float(speed)
        p.play()
    }

    func seek(to target: Double) {
        guard active, !preparing, let p = player, !tracks.isEmpty else { return }
        let pos = max(0, duration > 0 ? min(target, duration - 1) : target)
        position = pos
        let i = partIndex(pos)
        let wasPlaying = p.rate != 0 || switching
        if i == part && !switching && !forceTx.contains(i) && BookPlayer.playsDirectly(tracks[i]) {
            p.seek(to: CMTime(seconds: pos - tracks[i].start, preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor in self?.updateNowPlaying() }
            }
        } else {
            load(i, pos - tracks[i].start, play: wasPlaying)
        }
    }

    func skip(_ by: Double, quiet: Bool = false) {
        guard active, !preparing else { return }
        let t = max(0, min(currentTime() + by, max(0, duration - 1)))
        seek(to: t)
        if !quiet { say("\(by < 0 ? "Back" : "Forward") \(Int(abs(by))) seconds. Now at \(Speak.position(t)).") }
    }

    func nextChapter(quiet: Bool = false) {
        guard active, !preparing else { return }
        guard !chapters.isEmpty else { if !quiet { say("This book has no chapters.") }; return }
        var i = chapterIndex(currentTime()) ?? -1
        if i + 1 >= chapters.count { if !quiet { say("This is the last chapter.") }; return }
        i += 1
        seek(to: chapters[i].start)
        if !quiet { say("Chapter \(i + 1) of \(chapters.count): \(chapters[i].title).") }
        lastSave = Date.distantPast                         // saved on the next tick
    }

    /// Back to the start of this chapter, or to the one before when it has only just started.
    func previousChapter(quiet: Bool = false) {
        guard active, !preparing else { return }
        guard !chapters.isEmpty else { if !quiet { say("This book has no chapters.") }; return }
        let pos = currentTime()
        var i = chapterIndex(pos) ?? 0
        if pos - chapters[i].start < 5 && i > 0 { i -= 1 }
        seek(to: chapters[i].start)
        if !quiet { say("Chapter \(i + 1) of \(chapters.count): \(chapters[i].title).") }
        lastSave = Date.distantPast
    }

    func setSpeed(_ v: Double) {
        speed = v
        UserDefaults.standard.set(v, forKey: "bookSpeed")
        if let p = player {
            p.defaultRate = Float(v)
            if p.rate != 0 { p.rate = Float(v) }
        }
        updateNowPlaying()
        say(v == 1 ? "Normal speed." : "Speed \(BookPlayer.number(v)) times.")
    }

    func setSleep(_ choice: String) {
        sleepAt = nil
        sleepPosition = nil
        sleepChoice = choice
        switch choice {
        case "off":
            say("Sleep timer off.")
        case "chapter":
            let pos = currentTime()
            if let i = chapterIndex(pos) {
                let c = chapters[i]
                sleepPosition = c.end > c.start ? c.end : (i + 1 < chapters.count ? chapters[i + 1].start : duration)
            } else {
                sleepPosition = chapters.first?.start ?? duration
            }
            say(chapters.isEmpty ? "It will pause at the end of the book." : "It will pause at the end of this chapter.")
        default:
            let minutes = Int(choice) ?? 15
            sleepAt = Date().addingTimeInterval(Double(minutes) * 60)
            say("It will pause in \(Speak.count(minutes, "minute")).")
        }
    }

    /// saving: keep her place in Audiobookshelf. quiet: don't say "Stopped". notify: tell the app it's over.
    func stop(saving: Bool = true, quiet: Bool = false, notify: Bool = true) {
        let wasActive = active
        if saving && active && !preparing { save(finished: false) }
        generation += 1
        loadGeneration += 1
        startTask?.cancel()
        startTask = nil
        tearDown()
        active = false
        preparing = false
        paused = false
        switching = false
        bookID = ""
        sleepAt = nil
        sleepPosition = nil
        sleepChoice = "off"
        if wasActive { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        if wasActive && !quiet { say("Stopped.") }
        if wasActive && notify { onEnded() }
    }

    /// The app is going to the background: keep her place, just in case.
    func saveNow() {
        if active && !preparing { save(finished: false) }
    }

    // MARK: plumbing

    private func save(finished: Bool) {
        guard let api = api(), active, !preparing, !bookID.isEmpty else { return }
        let t = finished ? duration : currentTime()
        lastSave = Date()
        let form = ["item": bookID, "pos": String(format: "%.1f", t), "duration": String(format: "%.1f", duration),
                    "finished": finished ? "1" : "0"]
        Task { _ = try? await api.post("api/play/books/save", form, as: MessageResponse.self) }
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
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    private func loadArtwork(_ url: URL?, gen: Int) {
        guard let url = url else { return }
        Task { [weak self] in
            guard let result = try? await URLSession.shared.data(from: url), let image = UIImage(data: result.0) else { return }
            guard let self = self, gen == self.generation else { return }
            self.artwork = BookPlayer.makeArtwork(image)
            self.updateNowPlaying()
        }
    }

    /// The lock screen: the chapter as the title, the book as the album, the author as the artist.
    private func updateNowPlaying() {
        guard active, !preparing, let p = player else { return }
        let pos = currentTime()
        var info: [String: Any] = [MPMediaItemPropertyAlbumTitle: title, MPMediaItemPropertyArtist: author]
        if let i = chapterIndex(pos) {
            info[MPMediaItemPropertyTitle] = chapters[i].title
        } else {
            info[MPMediaItemPropertyTitle] = title
        }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = pos
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(p.rate)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = speed
        if let a = artwork { info[MPMediaItemPropertyArtwork] = a }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = !chapters.isEmpty
        c.previousTrackCommand.isEnabled = !chapters.isEmpty
    }
}
