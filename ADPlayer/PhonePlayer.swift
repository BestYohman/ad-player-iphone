import Foundation
import AVFoundation
import MediaPlayer

/// "Listen on this phone": plays just the audio description track, using Apple's own player.
/// It streams from the PC a little at a time (nothing is downloaded ahead of time), keeps playing
/// with the screen locked, and works with the lock screen, Control Center, headphones and AirPlay.
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

    var api: @MainActor () -> API? = { nil }
    var say: @MainActor (String) -> Void = { _ in }
    var onEnded: @MainActor () -> Void = {}

    private var player: AVPlayer?
    private var itemID: String?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var lastSave = Date.distantPast
    private var startTask: Task<Void, Never>?
    private var generation = 0
    private var didStart = false

    init() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            // after a phone call or Siri: carry on if iOS says to
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) else { return }
            Task { @MainActor in
                guard let self = self, self.active else { return }
                self.player?.play()
            }
        }
    }

    var statusText: String {
        if !active { return "Nothing is playing on this phone." }
        if preparing {
            return progress > 0 ? "Getting the audio of \(title) ready… \(progress) percent." : "Getting the audio of \(title) ready…"
        }
        let start = "\(paused ? "Paused" : "Playing") on this phone: \(title)."
        return duration > 0 ? start + " \(Speak.position(position)) of \(Speak.duration(duration))." : start
    }

    func currentTime() -> Double {
        let t = player?.currentTime().seconds ?? position
        return t.isFinite ? t : position
    }

    // MARK: starting

    func start(_ item: Item, resume: Bool) {
        stop(saving: true, quiet: true, notify: false)
        guard let api = api() else { return }
        generation += 1
        let gen = generation
        configureAudioSession()
        active = true
        preparing = true
        progress = 0
        title = item.label
        paused = false
        position = 0
        duration = 0
        hasNext = item.type == "Episode"
        itemID = item.id
        say("Getting the audio of \(item.label) ready.")

        startTask = Task { [weak self] in
            do {
                var job = try await api.post("api/play/listen/prepare", ["item": item.id, "fmt": "hls"], as: ListenJob.self)
                guard let self = self, gen == self.generation else { return }
                let resumeAt = resume ? (job.resumeTicks ?? 0) / 10_000_000 : 0
                self.title = job.title ?? item.label
                self.duration = (job.runtimeTicks ?? 0) / 10_000_000
                self.hasNext = job.hasNext ?? self.hasNext
                // The PC makes the audio in small pieces; playing can start once the first ones exist
                // (or, when carrying on part way through, once it has got past that point).
                while true {
                    if job.state == "failed" { throw APIError.server(job.error ?? "Couldn't get the audio ready.") }
                    let farEnough = resumeAt <= 5 || (job.encodedSeconds ?? 0) >= resumeAt + 15
                    if job.url != nil && (job.state == "ready" || ((job.playable ?? false) && farEnough)) { break }
                    self.progress = Int(job.progress ?? 0)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard gen == self.generation else { return }
                    job = try await api.get("api/play/listen/job/\(job.id)", as: ListenJob.self)
                    guard gen == self.generation else { return }
                }
                guard let path = job.url, let url = api.media(path) else { throw APIError.server("Couldn't get the audio ready.") }
                self.begin(url: url, at: resumeAt > 5 ? resumeAt : 0, gen: gen)
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

    private func begin(url: URL, at start: Double, gen: Int) {
        let item = AVPlayerItem(url: url)
        // Ask for about 10 minutes loaded ahead, so skipping forward is instant. Playing still starts
        // as soon as a few seconds are ready; the rest loads in the background. (iOS may load less if it needs the memory.)
        item.preferredForwardBufferDuration = 600
        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        player = p
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            Task { @MainActor in self?.itemStatusChanged(status, gen: gen, start: start) }
        }
        controlObservation = p.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let status = observed.timeControlStatus
            Task { @MainActor in self?.controlChanged(status) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finished() }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, gen: Int, start: Double) {
        guard gen == generation, let p = player else { return }
        if status == .failed {
            stop(saving: false, quiet: true, notify: true)
            say("This phone couldn't play the audio.")
            return
        }
        guard status == .readyToPlay, !didStart else { return }
        didStart = true
        p.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, gen == self.generation else { return }
                self.preparing = false
                self.position = start
                self.player?.play()
                self.updateNowPlaying()
                let from = start > 0 ? " from \(Speak.position(start))" : ""
                self.say("Playing \(self.title) on this phone\(from), with audio description.")
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
        p.play()
    }

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
        tearDown()
        itemID = nil
        active = false
        preparing = false
        paused = false
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
                                   MPMediaItemPropertyArtist: "Audio description"]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime()
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(p.rate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = hasNext
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = false
    }
}
