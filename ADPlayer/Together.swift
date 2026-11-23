import Foundation
import AVFoundation
import UserNotifications

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
    /// The people she can invite (the picker is open while this isn't nil).
    @Published var inviting: [Person]?
    private var declined = Set<String>()
    var inBackground = false

    weak var model: AppModel?

    @Published private(set) var roomID = ""
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
    private var jseq = 0                    // the last skip (back, forward, a chapter) this phone went to
    private var waitingAhead = false        // ahead of the others: waiting here for them
    private var readyIseq = -1              // the item the PC has heard this phone is ready with (it then says where to go)
    private var held = false                // paused here (headphones out, a call, Pause): not started again until the room has paused
    private var heldAsk = Date.distantPast
    private var rejoining = false

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
                                            "mode": "audio", "title": item.label, "invite": ""], as: Room.self)
                self.begin(r)
                self.say("Ready to play \(r.title ?? item.label) together. Choose who to invite. When they join it starts by itself - or press Play to start now.")
                await self.inviteOpen(first: true)
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
                                            "mode": "audio", "title": b.title, "invite": ""], as: Room.self)
                self.begin(r)
                self.say("Ready to listen to \(r.title ?? label) together. Choose who to invite. When they join it starts by itself - or press Play to start now.")
                await self.inviteOpen(first: true)
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
        jseq = r.jseq ?? 0
        waitingAhead = false
        readyIseq = -1
        held = false
        rejoining = false
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
        keepAwake()
        let ready = mediaReady
        let id = roomID
        let t0 = Date()
        let form = ["cid": cid, "room": roomID, "pos": String(format: "%.2f", ready ? mediaTime : 0),
                    "ready": ready ? "1" : "0", "buf": isStuck ? "1" : "0", "iseq": String(iseqLoaded),
                    "sk": String(skips), "stl": String(stalls),
                    // which skip this phone has got to, and whether it is still loading there (the others wait for it)
                    "jseq": String(jseq), "ld": (!ready || loading) ? "1" : "0",
                    // how long a beat takes there and back, in seconds (the PC allows for it when it works out who is behind)
                    "rtt": String(format: "%.3f", rtt)]
        guard let r = try? await api.post("api/play/together/beat", form, as: Room.self), roomID == id else { return }
        let took = Date().timeIntervalSince(t0)
        if took < 3 { rtt = rtt * 0.7 + took * 0.3 }
        apply(r, readyBeat: ready)
    }

    /// Paused or waiting with the screen locked: a silent sound keeps the app going (so it keeps beating).
    private func keepAwake() {
        if active && mediaRate == 0 { KeepAlive.shared.start() } else { KeepAlive.shared.stop() }
    }

    private func apply(_ r: Room, readyBeat: Bool = false) {
        guard active else { return }
        if r.gone == true {
            let msg = r.msg ?? "Playing together has ended."
            if r.left == true { end(nil) } else { rejoin(msg) }
            return
        }
        guard r.id != nil else { return }
        // the first answer to "ready": a phone that joined late (or is back) is told there to go to where the others are
        if readyBeat && (r.iseq ?? 0) == iseqLoaded { readyIseq = iseqLoaded }
        if room != r { room = r }          // (the screens are only redrawn when something changed)
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
        if kind == "book" { book?.roomSpeed = r.rate ?? 1 } else { phone?.roomSpeed = r.rate ?? 1 }
        iseqLoaded = seq
    }

    // MARK: this phone's player

    private var mediaReady: Bool {
        if kind == "book" { return (book?.ready ?? false) && book?.bookID == room?.item }
        return (phone?.ready ?? false) && phone?.currentItemID == room?.item
    }

    /// Loading right now (even for a moment).
    private var loading: Bool { kind == "book" ? (book?.buffering ?? false) : (phone?.buffering ?? false) }

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
        keepAwake()
    }

    private func pause() {
        expectPause = Date()
        if kind == "book" { book?.pause(quiet: true) } else { phone?.pause(quiet: true) }
        keepAwake()
    }

    /// Nobody is skipped ahead to catch up (they may be in different places - nothing should be missed): a phone that
    /// is behind just carries on (the PC moves everyone back to it), and a phone that is ahead waits until the others
    /// reach it. Only a real skip (back, forward, a chapter, the next episode) moves everyone, and the PC then waits
    /// until every phone has got there and loaded.
    private func sync(_ r: Room) {
        let base = (r.rate ?? 1) > 0 ? (r.rate ?? 1) : 1
        if kind == "book" { book?.roomSpeed = base } else { phone?.roomSpeed = base }
        // paused here (headphones out, a call, Pause): not started again on the loudspeaker until the room has paused
        // too (asked again every 5 seconds if the pause didn't get through) or she presses Play
        if held {
            if !(r.want ?? false) { held = false }
            else if Date().timeIntervalSince(heldAsk) > 5 { heldAsk = Date(); control("pause", quiet: true) }
        }
        // ready, but the PC hasn't answered that yet: it may say to go to where the others are first - nothing is
        // played from here until then (she hasn't heard any of it yet, so nothing is missed)
        if readyIseq != iseqLoaded {
            if mediaRate != 0 { pause() }
            return
        }
        let run = (r.run ?? false) && !held
        // a little ahead by how late this phone's sound reaches her ears (Bluetooth headphones), so both hear it together
        let target = (r.pos ?? 0) + (run ? rtt / 2 * base : 0) + outputDelay * base
        let diff = mediaTime - target
        let js = r.jseq ?? 0
        if js != jseq {
            jseq = js
            waitingAhead = false
            if abs(diff) > 0.5 { seek(target) }
            if run { play(rate: base) } else if mediaRate != 0 { pause() }
            return
        }
        if run {
            if diff > 0.6 || (waitingAhead && diff > 0.1) {
                if !waitingAhead { waitingAhead = true; skips += 1 }
                if mediaRate != 0 { pause() }
            } else {
                waitingAhead = false
                let want = diff > 0.15 ? base * (1 - min(0.05, diff * 0.1)) : base
                if mediaRate == 0 || abs(mediaRate - want) > 0.001 { play(rate: want) }
            }
        } else {
            waitingAhead = false
            if mediaRate != 0 { pause() }
            if diff > 0.25 { seek(target) }               // paused: back to where everyone is (never forward)
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

    /// failText: said when the PC can't be reached. quiet: nothing is said if it goes wrong.
    func control(_ action: String, _ extra: [String: String] = [:], okText: String? = nil, failText: String? = nil, quiet: Bool = false) {
        guard let api = api, active else { return }
        let id = roomID
        var form = ["cid": cid, "room": id, "action": action]
        for (k, v) in extra { form[k] = v }
        Task {
            do {
                let r = try await api.post("api/play/together/control", form, as: Room.self)
                guard self.roomID == id else { return }
                if let t = okText { self.say(t) }
                self.apply(r)
            } catch {
                guard self.roomID == id, !quiet else { return }
                switch error {
                case APIError.server(_), APIError.signIn(_): self.say(error.localizedDescription)
                default: self.say(failText ?? error.localizedDescription)
                }
            }
        }
    }

    /// Paused on this phone straight away, then for everyone (asked again every 5 seconds until the room has paused,
    /// so it isn't started again here - on the loudspeaker, say - in the meantime).
    func pauseHere(_ text: String) {
        guard active else { return }
        held = true
        heldAsk = Date()
        pause()
        control("pause", okText: text, failText: "Paused here. Couldn't reach the PC - the others may still be playing.")
    }

    /// The room is playing (or about to), as far as this phone knows.
    var roomPlaying: Bool { (room?.want ?? false) && !held }

    /// playpause, play, pause, back30, fwd30, next, prev, stop
    func command(_ c0: String) {
        guard active else { return }
        let r = room
        let want = r?.want ?? false
        let waiting = r?.waiting ?? false
        var c = c0
        if c == "stop" { stopAll(); return }
        if c == "playpause" { c = (want && !waiting && !held) ? "pause" : "play" }
        if c == "play" {
            held = false
            control("play", okText: waiting ? "Starting." : "Playing.", failText: "Couldn't reach the PC - it didn't start.")
            return
        }
        if c == "pause" { pauseHere("Paused."); return }
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

    /// Stop for everyone: the other phones stop too (and are told who stopped it). Tried a few times; she's told
    /// only once the PC has it, or that it couldn't be reached (the others may then still be playing).
    func stopAll() {
        guard active, api != nil else { return }
        let id = roomID
        seenInvites.insert(id)
        finish()
        Task {
            var ok = false
            for i in 0..<4 {
                if i > 0 { try? await Task.sleep(nanoseconds: UInt64(2 * i) * 1_000_000_000) }
                guard let api = self.api else { break }
                do {
                    _ = try await api.post("api/play/together/control", ["cid": self.cid, "room": id, "action": "stop"], as: Room.self)
                    ok = true
                } catch APIError.signIn(_) {
                    break
                } catch {
                }
                if ok { break }
            }
            self.say(ok ? "Stopped for everyone." : "Couldn't reach the PC - the others may still be playing.")
            await self.pollInvites()
        }
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

    /// The app is being closed (swiped away) while it's paused or waiting together: it leaves the room, so the
    /// others aren't kept waiting for this phone. Best effort - it waits two seconds at most.
    func leaveIfIdle() {
        guard active, !roomPlaying, let api = api else { return }
        let form = ["cid": cid, "room": roomID, "action": "leave"]
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await api.post("api/play/together/control", form, as: Room.self)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    private func end(_ message: String?) {
        finish()
        if let m = message { say(m) }
        Task { await self.pollInvites() }
    }

    /// The PC let go of this phone (no signal for a few minutes): it joins the same room again by itself, then goes
    /// to where the others are. Only when the room has really ended does it stop.
    private func rejoin(_ msg: String) {
        guard !rejoining, let api = api else { return }
        rejoining = true
        let id = roomID
        Task {
            do {
                let r = try await api.post("api/play/together/join", ["cid": self.cid, "room": id, "mode": "audio"], as: Room.self)
                guard self.roomID == id else { return }
                self.rejoining = false
                if r.gone == true || r.id == nil { self.end(msg); return }
                self.jseq = -1                  // (so it goes straight to where the others are)
                self.readyIseq = -1
                self.waitingAhead = false
                self.msgSeq = r.msgSeq ?? self.msgSeq
                self.say("Back with the others.")
                self.apply(r)
            } catch APIError.server(_) {
                guard self.roomID == id else { return }
                self.rejoining = false
                self.end(msg)                   // the room is over
            } catch {
                guard self.roomID == id else { return }
                self.rejoining = false          // no connection yet: the next beat tries again
            }
        }
    }

    private func finish() {
        beatTask?.cancel()
        beatTask = nil
        roomID = ""
        room = nil
        held = false
        phone?.togetherEnded = nil
        book?.togetherEnded = nil
        stopPlayers()
        KeepAlive.shared.stop()
        model?.showPlayer = false
        model?.soundIdle()
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
        } else if held {
            state = "Paused."
        } else if let h = r.hold, !h.isEmpty {
            state = "Waiting a moment for \(h.joined(separator: " and ")) to catch up."
        } else {
            state = (r.want ?? false) ? "Playing." : "Paused."
        }
        if ready && !held, let st = r.status, !st.isEmpty { state = st }
        let pos = ready ? mediaTime : (r.pos ?? 0)
        var text = (others.isEmpty ? "Playing together" : "Together with \(names)") + ": \(r.title ?? ""). \(state) \(Speak.position(pos))"
        if let rt = r.runtime, rt > 0 { text += " of \(Speak.duration(rt))" }
        text += "."
        if kind == "book", let b = book, let chapter = b.chapterSentence(pos) { text += " " + chapter }
        if ready && kind != "book" { text += phone?.hasAD == false ? " You hear the soundtrack." : " You hear the audio description." }
        return text
    }

    /// Where it is and how long it is, in seconds (VoiceOver's value for the place).
    var place: (pos: Double, total: Double) { (mediaReady ? mediaTime : (room?.pos ?? 0), room?.runtime ?? 0) }

    var paused: Bool { held || !((room?.want ?? false) && !(room?.waiting ?? false)) }
    var hasNextEpisode: Bool { kind != "book" && (room?.hasNext ?? false) }

    // MARK: invitations

    func pollInvites() async {
        guard !active, let api = api, model?.needSignIn == false else { invites = []; return }
        guard let r = try? await api.get("api/play/together/list", ["cid": cid], as: InvitesResponse.self) else { return }
        guard !active else { return }
        invites = r.rooms.filter { !declined.contains($0.id) }
        for inv in invites where !seenInvites.contains(inv.id + (inv.invited == true ? ":i" : "")) {
            seenInvites.insert(inv.id + (inv.invited == true ? ":i" : ""))     // (again when an invitation comes for a room already listed)
            if inBackground {
                if inv.invited == true { notify(inv) }
            } else {
                say(inv.line + " The Join button is at the top.")
            }
        }
    }

    /// Not now: the invitation goes away here, and the one who invited sees "said not now".
    func decline(_ inv: Invite) {
        declined.insert(inv.id)
        invites.removeAll { $0.id == inv.id }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["together-" + inv.id])
        if inv.invited == true, let api = api {
            Task { _ = try? await api.post("api/play/together/decline", ["room": inv.id], as: MessageResponse.self) }
        }
        say("Okay.")
    }

    /// A phone notification while the app is in the background (asked for once, the first time).
    private func notify(_ inv: Invite) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = "Play together"
            n.body = inv.line
            n.sound = .default
            n.userInfo = ["room": inv.id]
            c.add(UNNotificationRequest(identifier: "together-" + inv.id, content: n, trigger: nil))
        }
    }

    // MARK: inviting

    /// Only people who can sign in to the player; the ones already playing or invited aren't offered again.
    func inviteOpen(first: Bool = false) async {
        guard active, let api = api else { return }
        guard let r = try? await api.get("api/play/people", as: PeopleResponse.self) else {
            if !first { say("Couldn't reach the app.") }
            return
        }
        let have = Set((room?.people ?? []).filter { $0.state != "declined" }.map { $0.name })
        let avail = r.people.filter { !have.contains($0.name) }
        if avail.isEmpty {
            if !first { say(r.people.isEmpty ? "Nobody else can sign in to the player." : "Everyone is already invited or playing.") }
            return
        }
        if active { inviting = avail }
    }

    func inviteSend(_ names: [String]) {
        inviting = nil
        guard active, !names.isEmpty, let api = api else { return }
        let rid = roomID
        Task {
            do {
                let r = try await api.post("api/play/together/invite", ["cid": cid, "room": rid, "names": names.joined(separator: ",")],
                                           as: MessageResponse.self)
                self.say(r.message)
            } catch {
                self.say(error.localizedDescription)
            }
        }
    }
}
