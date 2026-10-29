import Foundation
import AVFoundation

/// Playing together: one person starts a show, movie or audiobook with "Play together" on, and the other
/// gets a Join button. Every second this phone tells the PC where it is; the PC keeps the one clock both
/// phones follow (play, pause, skipping, chapters, the next episode). This phone plays just the audio:
/// the audio description, or the soundtrack when there is none.
@MainActor
final class Together: ObservableObject {
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "together") {
        didSet { UserDefaults.standard.set(enabled, forKey: "together") }
    }
    @Published private(set) var room: Room?
    @Published private(set) var invites: [Invite] = []

    weak var model: AppModel?

    private(set) var roomID = ""
    private var kind = ""
    private var iseq = 0
    private var iseqLoaded = 0
    private var msgSeq = 0
    private var rtt = 0.15
    private var beatTask: Task<Void, Never>?
    private var seenInvites = Set<String>()
    private var bufSince: Date?
    private var stuck = false
    private var seekAt: Date?
    private var seekCost = 0.5
    private var skips = 0
    private var stalls = 0
    private var expectPlay = Date.distantPast
    private var expectPause = Date.distantPast

    let cid: String = {
        if let c = UserDefaults.standard.string(forKey: "cid"), !c.isEmpty { return c }
        let c = "i" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        UserDefaults.standard.set(c, forKey: "cid")
        return c
    }()

    var active: Bool { !roomID.isEmpty }
    var isBook: Bool { kind == "book" }

    private var api: API? { model?.api }
    private func say(_ t: String) { model?.say(t) }
    private var phone: PhonePlayer? { model?.phone }
    private var book: BookPlayer? { model?.book }

    // MARK: starting and joining

    func startShow(_ item: Item, resume: Bool) {
        guard let api = api else { return }
        if active { leave(quiet: true) }
        stopPlayers()
        say("Starting \(item.label) to play together.")
        let pos = resume ? (item.resumeTicks ?? 0) / 10_000_000 : 0
        Task {
            do {
                let r = try await api.post("api/play/together/start",
                                           ["cid": cid, "kind": "video", "item": item.id, "pos": String(format: "%.1f", pos),
                                            "mode": "audio", "title": item.label], as: Room.self)
                self.begin(r)
                self.say("Ready to play \(r.title ?? item.label) together. When the other person presses Join it starts by itself - or press Play to start now.")
            } catch {
                self.say(error.localizedDescription)
            }
        }
    }

    func startBook(id: String, label: String, resume: Bool, at: Double?) {
        guard let api = api else { return }
        if active { leave(quiet: true) }
        stopPlayers()
        say("Starting \(label) to listen together.")
        Task {
            do {
                let b = try await api.get("api/play/books/book", ["id": id], as: BookDetail.self)
                var pos = at ?? ((resume && !b.finished) ? max(0, b.position - 2) : 0)
                if b.duration > 0 && pos >= b.duration - 2 { pos = 0 }
                let r = try await api.post("api/play/together/start",
                                           ["cid": cid, "kind": "book", "item": id, "pos": String(format: "%.1f", pos),
                                            "mode": "audio", "title": b.title], as: Room.self)
                self.begin(r)
                self.say("Ready to listen to \(r.title ?? label) together. When the other person presses Join it starts by itself - or press Play to start now.")
            } catch {
                self.say(error.localizedDescription)
            }
        }
    }

    func join(_ invite: Invite) {
        guard let api = api else { return }
        stopPlayers()
        say("Joining.")
        Task {
            do {
                let r = try await api.post("api/play/together/join", ["cid": cid, "room": invite.id, "mode": "audio"], as: Room.self)
                self.begin(r)
                let by = r.by ?? invite.by
                self.say("Joined \(by): \(r.title ?? invite.title). " +
                         (r.kind == "book" ? "Getting the book ready." : "Getting the audio ready - it starts in step with \(by)."))
            } catch {
                self.say(error.localizedDescription)
                await self.pollInvites()
            }
        }
    }

    private func stopPlayers() {
        phone?.stop(saving: true, quiet: true, notify: false)
        book?.stop(saving: true, quiet: true, notify: false)
    }

    private func begin(_ r: Room) {
        roomID = r.id ?? ""
        kind = r.kind ?? ""
        iseq = 0
        iseqLoaded = 0
        msgSeq = r.msgSeq ?? 0
        skips = 0
        stalls = 0
        invites = []
        phone?.togetherEnded = { [weak self] in self?.ended() }
        book?.togetherEnded = { [weak self] in self?.ended() }
        model?.showPlayer = true
        apply(r)
        beatTask?.cancel()
        let id = roomID
        beatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, self.roomID == id else { return }
                await self.beat()
            }
        }
    }

    // MARK: every second

    private func beat() async {
        guard let api = api, active else { return }
        let ready = mediaReady
        let t0 = Date()
        let form = ["cid": cid, "room": roomID, "pos": String(format: "%.2f", ready ? mediaTime : 0),
                    "ready": ready ? "1" : "0", "buf": isStuck ? "1" : "0", "iseq": String(iseqLoaded),
                    "sk": String(skips), "stl": String(stalls)]
        guard let r = try? await api.post("api/play/together/beat", form, as: Room.self) else { return }
        let took = Date().timeIntervalSince(t0)
        if took < 3 { rtt = rtt * 0.7 + took * 0.3 }
        apply(r)
    }

    private func apply(_ r: Room) {
        guard active else { return }
        if r.gone == true {
            end(r.left == true ? nil : (r.msg ?? "Playing together has ended."))
            return
        }
        guard r.id != nil else { return }
        room = r
        kind = r.kind ?? kind
        if let ms = r.msgSeq, ms != msgSeq {
            msgSeq = ms
            if let m = r.msg, !m.isEmpty, r.msgBy != cid { say(m) }
        }
        let n = r.iseq ?? 0
        if n != iseq {
            iseq = n
            load(r)
        } else if iseqLoaded == n && mediaReady {
            sync(r)
        }
    }

    private func load(_ r: Room) {
        let seq = r.iseq ?? 0
        let pos = r.pos ?? 0
        if kind == "book" {
            book?.start(id: r.item ?? "", label: r.title ?? "", resume: false, at: pos, noplay: true)
        } else {
            let item = Item(id: r.item ?? "", type: (r.hasNext ?? false) ? "Episode" : "Movie", label: r.title ?? "",
                            length: nil, played: nil, resume: nil, resumeTicks: nil, hasAD: nil)
            phone?.start(item, resume: false, together: pos)
        }
        iseqLoaded = seq
    }

    // MARK: this phone's player

    private var mediaReady: Bool {
        if kind == "book" { return (book?.ready ?? false) && book?.bookID == room?.item }
        return (phone?.ready ?? false) && phone?.currentItemID == room?.item
    }

    private var mediaTime: Double { kind == "book" ? (book?.currentTime() ?? 0) : (phone?.currentTime() ?? 0) }
    private var mediaRate: Double { kind == "book" ? (book?.rate ?? 0) : (phone?.rate ?? 0) }

    /// Still loading for more than a second (a quick hiccup isn't reported); learns how long a skip takes here.
    private var isStuck: Bool {
        let b = mediaReady && (kind == "book" ? (book?.buffering ?? false) : (phone?.buffering ?? false))
        if let s = seekAt, mediaReady, !b {
            seekCost = min(6, max(0.2, seekCost * 0.6 + Date().timeIntervalSince(s) * 0.4))
            seekAt = nil
        }
        guard b else { bufSince = nil; stuck = false; return false }
        if bufSince == nil { bufSince = Date() }
        let long = Date().timeIntervalSince(bufSince ?? Date()) > 1
        if long && !stuck { stuck = true; stalls += 1 }
        return long
    }

    private func seek(_ t: Double) {
        seekAt = Date()
        skips += 1
        if kind == "book" { book?.seek(to: max(0, t)) } else { phone?.seek(to: max(0, t), quiet: true) }
    }

    private func play(rate: Double) {
        expectPlay = Date()
        if kind == "book" { book?.play(rate: rate) } else { phone?.play(rate: rate) }
    }

    private func pause() {
        expectPause = Date()
        if kind == "book" { book?.pause(quiet: true) } else { phone?.pause(quiet: true) }
    }

    /// Small differences: a little faster or slower. Skipping (which loads again - slow on a phone network)
    /// only for big ones, aimed ahead by how long a skip takes on this phone.
    private func sync(_ r: Room) {
        let base = (r.rate ?? 1) > 0 ? (r.rate ?? 1) : 1
        let run = r.run ?? false
        // a little ahead by how late this phone's sound reaches her ears (Bluetooth headphones), so both hear it together
        let target = (r.pos ?? 0) + (run ? rtt / 2 * base : 0) + outputDelay * base
        let diff = mediaTime - target
        let lead = min(5, seekCost) * base
        if run {
            if mediaRate == 0 {
                if abs(diff) > 0.75 { seek(target + lead) }
                play(rate: base)
                return
            }
            if abs(diff) > 2.5 {
                seek(target + lead)
                play(rate: base)
            } else if abs(diff) > 0.15 {
                play(rate: base * (1 - max(-0.08, min(0.08, diff * 0.15))))
            } else if abs(mediaRate - base) > 0.001 {
                play(rate: base)
            }
        } else {
            if mediaRate != 0 { pause() }
            if abs(diff) > 0.25 { seek(target) }
        }
    }

    // MARK: headphone delay

    static let delays: [(String, String)] = [("auto", "Auto"), ("0", "None"), ("0.1", "0.1 seconds"), ("0.2", "0.2 seconds"),
                                            ("0.3", "0.3 seconds"), ("0.4", "0.4 seconds"), ("0.5", "0.5 seconds")]
    @Published var delayChoice: String = UserDefaults.standard.string(forKey: "hpDelay") ?? "auto" {
        didSet { UserDefaults.standard.set(delayChoice, forKey: "hpDelay") }
    }

    /// Seconds this phone's sound is late: Auto asks iPhone (AirPods and other Bluetooth headphones are about 0.2 s).
    var outputDelay: Double {
        if let v = Double(delayChoice) { return v }
        let l = AVAudioSession.sharedInstance().outputLatency
        return l.isFinite ? min(0.5, max(0, l)) : 0
    }

    // MARK: buttons (on screen, lock screen and headphones)

    func control(_ action: String, _ extra: [String: String] = [:], okText: String? = nil) {
        guard let api = api, active else { return }
        var form = ["cid": cid, "room": roomID, "action": action]
        for (k, v) in extra { form[k] = v }
        Task {
            do {
                let r = try await api.post("api/play/together/control", form, as: Room.self)
                if let t = okText { self.say(t) }
                self.apply(r)
            } catch {
                self.say(error.localizedDescription)
            }
        }
    }

    /// playpause, play, pause, back30, fwd30, next, prev, stop
    func command(_ c0: String) {
        guard active else { return }
        let r = room
        let want = r?.want ?? false
        let waiting = r?.waiting ?? false
        var c = c0
        if c == "stop" { leave(quiet: false); return }
        if c == "playpause" { c = (want && !waiting) ? "pause" : "play" }
        if c == "play" { control("play", okText: waiting ? "Starting." : "Playing."); return }
        if c == "pause" { control("pause", okText: "Paused."); return }
        let now = mediaReady ? mediaTime : (r?.pos ?? 0)
        if c == "back30" || c == "fwd30" {
            let np = max(0, now + (c == "back30" ? -30 : 30))
            control("seek", ["pos": String(format: "%.1f", np)],
                    okText: "\(c == "back30" ? "Back" : "Forward") 30 seconds. Now at \(Speak.position(np)).")
            return
        }
        if kind == "book" && (c == "next" || c == "prev"), let b = book {
            let ch = b.chapters
            guard !ch.isEmpty else { say("This book has no chapters."); return }
            var i = b.chapterIndex(now) ?? -1
            if c == "next" {
                if i + 1 >= ch.count { say("This is the last chapter."); return }
                i += 1
            } else {
                if i < 0 { i = 0 } else if now - ch[i].start < 5 && i > 0 { i -= 1 }
            }
            control("seek", ["pos": String(format: "%.1f", ch[i].start)], okText: "Chapter \(i + 1) of \(ch.count): \(ch[i].title).")
            return
        }
        if c == "next" { control("next") }
    }

    func seekTo(_ t: Double) {
        control("seek", ["pos": String(format: "%.1f", max(0, t))])
    }

    func setSpeed(_ v: Double) {
        control("rate", ["rate": String(v)], okText: v == 1 ? "Normal speed." : "Speed \(BookPlayer.number(v)) times.")
    }

    private func ended() {
        control("ended", ["item": room?.item ?? ""])
    }

    func leave(quiet: Bool) {
        guard active, let api = api else { return }
        let id = roomID
        seenInvites.insert(id)
        finish()
        if !quiet { say("You left playing together.") }
        Task {
            _ = try? await api.post("api/play/together/control", ["cid": cid, "room": id, "action": "leave"], as: Room.self)
            await self.pollInvites()
        }
    }

    private func end(_ message: String?) {
        finish()
        if let m = message { say(m) }
        Task { await self.pollInvites() }
    }

    private func finish() {
        beatTask?.cancel()
        beatTask = nil
        roomID = ""
        room = nil
        phone?.togetherEnded = nil
        book?.togetherEnded = nil
        stopPlayers()
        model?.showPlayer = false
    }

    // MARK: what to say

    var statusText: String {
        guard let r = room else { return "Joining…" }
        let others = r.others ?? []
        let names = others.joined(separator: " and ")
        let ready = mediaReady
        let part: String
        if kind == "book" { part = "the book" }
        else if phone?.hasAD == false && ready { part = "the soundtrack (this one has no audio description)" }
        else { part = "the audio" }
        var state: String
        if !ready {
            let p = phone?.progress ?? 0
            state = "Getting \(part) ready" + (kind != "book" && p > 0 ? ", \(p) percent" : "") + "."
        } else if r.waiting == true {
            let notReady = (r.notReady ?? []).joined(separator: " and ")
            state = others.isEmpty ? "Waiting for someone to join. Press Play to start now."
                                   : "Waiting for \(notReady.isEmpty ? names : notReady) to be ready."
        } else if let h = r.hold, !h.isEmpty {
            state = "Waiting a moment for \(h.joined(separator: " and ")) to catch up."
        } else {
            state = (r.want ?? false) ? "Playing." : "Paused."
        }
        let pos = ready ? mediaTime : (r.pos ?? 0)
        var text = (others.isEmpty ? "Playing together" : "Together with \(names)") + ": \(r.title ?? ""). \(state) \(Speak.position(pos))"
        if let rt = r.runtime, rt > 0 { text += " of \(Speak.duration(rt))" }
        text += "."
        if kind == "book", let b = book, let chapter = b.chapterSentence(pos) { text += " " + chapter }
        if ready && kind != "book" { text += phone?.hasAD == false ? " You hear the soundtrack." : " You hear the audio description." }
        return text
    }

    var paused: Bool { !((room?.want ?? false) && !(room?.waiting ?? false)) }
    var hasNextEpisode: Bool { kind != "book" && (room?.hasNext ?? false) }

    // MARK: invitations

    func pollInvites() async {
        guard !active, let api = api, model?.needSignIn == false else { invites = []; return }
        guard let r = try? await api.get("api/play/together/list", ["cid": cid], as: InvitesResponse.self) else { return }
        guard !active else { return }
        invites = r.rooms
        for inv in r.rooms where !seenInvites.contains(inv.id) {
            seenInvites.insert(inv.id)
            let what = (inv.kind == "book" ? "listen to " : "play ") + inv.title
            say("\(inv.by) wants to \(what) together. The Join button is at the top.")
        }
    }
}
