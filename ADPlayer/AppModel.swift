import Foundation
import SwiftUI
import UIKit
import MediaPlayer
import Network
import Combine
import AVFoundation

/// Everything the screens share: the PC's address, the chosen TV (or this phone), what's playing.
@MainActor
final class AppModel: ObservableObject {
    /// The one model: the screens and the Siri shortcuts share it.
    static let shared = AppModel()

    nonisolated static let phoneID = "__local"
    nonisolated static let phoneName = "This phone - just the audio"

    @Published var server: String = UserDefaults.standard.string(forKey: "server") ?? ""
    @Published var devices: [Device] = []
    @Published var otherDevices: [String] = []
    @Published var pairing: Device?
    @Published var pairCode = ""
    @Published var target: String = AppModel.phoneID {
        didSet {
            guard oldValue != target else { return }
            if !restoring, let d = devices.first(where: { $0.id == target }), d.pair == true {
                restoring = true; target = oldValue; restoring = false        // an Apple TV that has to be paired first
                pairStart(d); return
            }
            if !restoring { AppModel.noteUsed(target) }
            if !restoring { UserDefaults.standard.set(nameOf(target), forKey: "targetName") }
            tvStatus = nil
            tvMisses = 0
            Task { await self.refreshStatus(); await self.loadContinue(); await self.loadContinueBooks() }
        }
    }
    @Published var continueItems: [Item] = []
    @Published var continueLoading = false
    @Published var message = ""
    @Published var showPlayer = false
    /// The TV's state is kept on its own, so only the screens that show it follow it (it's asked every few seconds).
    let tvState: TVState
    var tvStatus: TVStatus? {
        get { tvState.status }
        set { tvState.set(newValue) }
    }
    @Published var continueBooks: [BookItem] = []
    @Published var booksSetUp = true          // false: Audiobookshelf isn't set up on the PC, so the audiobook parts are hidden
    @Published var booksNote = ""
    @Published var me: Me? {
        didSet {                       // kept, so the right layout shows straight away next time (before the PC answers)
            if let v = me?.sight { UserDefaults.standard.set(v, forKey: "sight") }
            if let o = me?.sightOpts, let d = try? JSONEncoder().encode(o) { UserDefaults.standard.set(d, forKey: "sightOpts") }
        }
    }
    @Published var needSignIn = false
    /// The address in use now: the PC's home-network address on the home Wi-Fi, otherwise the one typed in.
    @Published var activeAddress = ""

    let phone: PhonePlayer
    let book: BookPlayer
    let together: Together
    let video = VideoModel()
    /// Low and full vision: the video plays on this phone (off: just the audio, as before).
    @Published var preferVideo: Bool = UserDefaults.standard.object(forKey: "preferVideo") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preferVideo, forKey: "preferVideo") }
    }

    // MARK: how she sees the screen

    /// "none" (the audio-only layout), "low" (big and high contrast) or "full" (posters and rows). Until the PC answers:
    /// the last answer; an older PC that doesn't know about it: the audio-only layout, as before.
    var sight: String { me?.sight ?? UserDefaults.standard.string(forKey: "sight") ?? "none" }
    /// An older PC doesn't ask (it couldn't keep the answer); nor while it hasn't answered yet.
    var sightChosen: Bool { me?.sight == nil || me?.sightChosen != false }
    /// The PC keeps how she sees the screen (so it can be changed here).
    var sightKnown: Bool { me?.sight != nil }
    var low: Bool { sight == "low" }
    var opts: SightOpts {
        if let o = me?.sightOpts { return o }
        if let d = UserDefaults.standard.data(forKey: "sightOpts"), let o = try? JSONDecoder().decode(SightOpts.self, from: d) { return o }
        return SightOpts()
    }
    /// The video plays on this phone: full vision, or low vision with the video on (as the PC decides: someone who
    /// only listens sees the video once they chose low or full vision themselves).
    var videoOK: Bool {
        (sight == "full" || (sight == "low" && opts.video != false)) && (me?.role != "listen" || me?.sightChosen == true)
    }

    func sightSave(_ form: [String: String], said: String) {
        guard let api = api else { return }
        if var m = me, var o = m.sightOpts {          // shown straight away (VoiceOver reads the new value)
            for (k, v) in form {
                switch k {
                case "size": o.size = v
                case "screen": o.screen = v
                case "video": o.video = v == "1"
                case "focus": o.focus = v == "1"
                case "still": o.still = v == "1"
                case "posters": o.posters = v == "1"
                default: break
                }
            }
            m.sightOpts = o; me = m
        }
        Task {
            do {
                let r = try await api.post("api/play/sight", form, as: SightResponse.self)
                if var m = self.me {
                    m.sight = r.sight ?? m.sight; m.sightChosen = r.sightChosen ?? true; m.sightOpts = r.sightOpts ?? m.sightOpts
                    self.me = m
                }
                if !self.videoOK && self.video.active { self.video.stop() }
                self.say(said)
            } catch { self.say(error.localizedDescription) }
        }
    }
    private let monitor = NWPathMonitor()
    private var onWiFi = false
    private var addressTask: Task<Void, Never>?
    /// Each address check has a number: only the newest may set the address.
    private var addressGen = 0

    private var restoring = false
    private var restoredOnce = false
    private var pollTask: Task<Void, Never>?
    private var tvStartedAt = Date.distantPast
    private var tvMisses = 0
    private var lastRefresh = Date.distantPast
    private var interruptedPlaying = false

    init() {
        phone = PhonePlayer()
        book = BookPlayer()
        together = Together()
        tvState = TVState()
        video.model = self
        phone.api = { [weak self] in self?.api }
        phone.say = { [weak self] text in self?.say(text) }
        phone.onEnded = { [weak self] in
            guard let self = self else { return }
            if self.isPhone && !self.book.active { self.showPlayer = false }
            self.soundIdle()
            Task { await self.loadContinue() }
        }
        book.api = { [weak self] in self?.api }
        book.say = { [weak self] text in self?.say(text) }
        book.onEnded = { [weak self] in
            guard let self = self else { return }
            if self.isPhone && !self.phone.active { self.showPlayer = false }
            self.soundIdle()
            Task { await self.loadContinueBooks() }
        }
        setUpRemoteControls()
        setUpSoundEvents()
        restoreNowPlaying()
        Offline.shared.api = { [weak self] in self?.api }
        Offline.shared.say = { [weak self] text in self?.say(text) }
        together.model = self
        API.signInNeeded = { [weak self] in self?.needSignIn = true }
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(wifi: wifi, up: up) }
        }
        monitor.start(queue: DispatchQueue(label: "network"))
    }

    // MARK: home Wi-Fi or away

    private var typedURL: URL? { API.normalise(server) }

    /// On the home Wi-Fi: straight to the PC; elsewhere: the address typed in.
    var atHome: Bool { !activeAddress.isEmpty && activeAddress != (typedURL?.absoluteString ?? "") }

    private func networkChanged(wifi: Bool, up: Bool) {
        onWiFi = wifi
        guard up else { return }
        addressTask?.cancel()
        addressTask = Task {
            await self.chooseAddress()
            if Task.isCancelled { return }
            self.phone.networkBack(); self.book.networkBack()
            if let api = self.api { await Places.flush(api) }
            self.flushSignOuts()
            Offline.shared.resume()
        }
    }

    /// Does this home address prove it's this PC? Asked without the sign-in: with the key from signing in, it must
    /// answer a random question; signed in before there were keys, it must give this PC's id.
    private func provesHome(_ u: URL) async -> Bool {
        if LanProof.has {
            let nonce = LanProof.nonce()
            guard let m = await API(base: u).quickMe(["nonce": nonce, "kid": LanProof.id]) else { return false }
            return LanProof.matches(m.lanProof, nonce: nonce)
        }
        let id = UserDefaults.standard.string(forKey: "serverID") ?? ""
        guard !id.isEmpty, let m = await API(base: u).quickMe() else { return false }
        return m.serverID == id
    }

    /// Picks the address: on Wi-Fi, this PC's home address if it answers and proves it's this PC.
    func chooseAddress() async {
        addressGen += 1
        let gen = addressGen
        guard let away = typedURL else { return }
        var pick = away.absoluteString
        let id = UserDefaults.standard.string(forKey: "serverID") ?? ""
        let homes = UserDefaults.standard.stringArray(forKey: "homeURLs") ?? []
        if onWiFi && (LanProof.has || !id.isEmpty) {
            for h in homes {
                if h == pick { break }
                guard let u = URL(string: h) else { continue }
                let ok = await provesHome(u)
                if Task.isCancelled || gen != addressGen { return }      // a newer check is under way
                if ok { pick = h; break }
            }
        }
        guard !Task.isCancelled, gen == addressGen else { return }
        let old = api?.base.absoluteString ?? ""
        activeAddress = pick
        if !old.isEmpty && old != pick {
            phone.rebase()
            book.rebase()
        }
    }

    // MARK: signing in

    /// Asks the PC who is signed in on this phone (and remembers its home-network addresses).
    func checkSignIn() async {
        guard let api = api else { return }
        do {
            let m = try await api.get("api/play/me", as: Me.self)
            me = m
            if let id = m.serverID, !id.isEmpty { UserDefaults.standard.set(id, forKey: "serverID") }
            if let h = m.homeURLs { UserDefaults.standard.set(h, forKey: "homeURLs") }
            needSignIn = !(m.signedIn ?? false) || API.token.isEmpty
            if !needSignIn && !LanProof.has { await fetchLanKey() }
        } catch APIError.signIn(_) {
            needSignIn = true
        } catch {
            // the PC didn't answer: keep going as before
        }
    }

    /// Signed in before the PC gave keys: get it, over the address typed in (never a home address).
    private func fetchLanKey() async {
        guard let away = typedURL, !API.token.isEmpty else { return }
        if let m = try? await API(base: away).get("api/play/me", ["lan_key": "1"], as: Me.self) {
            LanProof.remember(id: m.lanProofID, key: m.lanProofKey)
        }
    }

    /// Returns nil when signed in, otherwise what went wrong.
    func signIn(user: String, password: String) async -> String? {
        guard let api = api else { return APIError.badAddress.localizedDescription }
        do {
            let r = try await api.post("api/play/login", ["user": user, "password": password, "app": "1"], as: LoginResponse.self)
            guard let token = r.token, !token.isEmpty else { return "The PC's app needs updating for signing in." }
            API.token = token
            Keychain.set("token", token)
            LanProof.forget()
            // (signed in on a home address: the key is fetched over the address typed in)
            if !atHome { LanProof.remember(id: r.lanProofID, key: r.lanProofKey) }
            await checkSignIn()
            await chooseAddress()
            needSignIn = false
            await refreshAll()
            say(r.message)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func signOut() {
        together.leave(quiet: true)
        phone.stop(saving: true, quiet: true, notify: false)
        book.stop(saving: true, quiet: true, notify: false)
        let old = API.token
        API.token = ""
        Keychain.set("token", nil)
        LanProof.forget()
        me = nil
        needSignIn = true
        if !old.isEmpty { sendSignOut(old) }
    }

    /// Tells the PC this phone signed out. With no connection, it's kept and told later.
    private func sendSignOut(_ token: String) {
        AppModel.keepSignOut(token, true)
        guard let api = api else { return }
        Task {
            if (try? await api.post("api/play/logout", [:], token: token, as: MessageResponse.self)) != nil {
                AppModel.keepSignOut(token, false)
            }
        }
    }

    /// The sign-outs the PC hasn't been told about yet (kept safe, like the sign-in).
    private static func keepSignOut(_ token: String, _ keep: Bool) {
        var left = (Keychain.get("signouts") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        left.removeAll { $0 == token }
        if keep { left.append(token) }
        Keychain.set("signouts", left.suffix(5).joined(separator: ","))
    }

    func flushSignOuts() {
        for t in (Keychain.get("signouts") ?? "").split(separator: ",").map(String.init) where !t.isEmpty && t != API.token {
            sendSignOut(t)
        }
    }

    /// Something is playing on this phone (a show's audio or a book).
    var phoneBusy: Bool { phone.active || book.active }

    var api: API? {
        if !activeAddress.isEmpty, let u = URL(string: activeAddress) { return API(base: u) }
        return API.normalise(server).map { API(base: $0) }
    }
    var isPhone: Bool { target == AppModel.phoneID }
    var targetName: String { nameOf(target) }

    private func nameOf(_ id: String) -> String {
        if id == AppModel.phoneID { return AppModel.phoneName }
        return devices.first(where: { $0.id == id })?.name ?? "the TV"
    }

    /// "SHIELD – Moonfin, signed in as Me" -> "SHIELD – Moonfin"
    private static func baseName(_ name: String) -> String {
        if let r = name.range(of: ", signed in as") { return String(name[..<r.lowerBound]) }
        return name
    }

    // MARK: speaking

    /// Shows the message and has VoiceOver read it out.
    func say(_ text: String) {
        message = text
        announce(text)
    }

    func announce(_ text: String) {
        // a moment's wait, so a screen opening at the same time doesn't cut it off
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            // queued: VoiceOver finishes what it's saying first, and this doesn't cut it off
            let queued = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: queued)
        }
    }

    // MARK: connecting

    /// Returns nil when the PC answered, otherwise what went wrong.
    func connect(_ text: String) async -> String? {
        let tries = API.candidates(text)
        guard !tries.isEmpty else { return APIError.badAddress.localizedDescription }
        var found: URL?
        var problem = ""
        for url in tries {
            // the AD Player answers "who am I" without signing in, and says which PC it is
            do {
                let me = try await API(base: url).get("api/play/me", as: Me.self)
                if me.serverID != nil || me.signedIn != nil { found = url; break }
                problem = "That address answered, but not like the AD Player."
            } catch APIError.signIn(_) {
                found = url; break
            } catch APIError.server(_) {
                problem = "That address answered, but not like the AD Player. Check the web address and port."
            } catch {
                problem = error.localizedDescription
            }
        }
        // On the home Wi-Fi the web address often can't be reached from inside (many routers don't loop back):
        // keep the web address for away from home, and use the PC's home address it gave before.
        // It's only used (and sent the sign-in) once it proves it's this PC, as above.
        var home = ""
        if found == nil, onWiFi, let typed = tries.first {
            for h in UserDefaults.standard.stringArray(forKey: "homeURLs") ?? [] {
                guard let u = URL(string: h) else { continue }
                if await provesHome(u) { found = typed; home = h; break }
            }
        }
        guard let url = found else { return problem.isEmpty ? APIError.network.localizedDescription : problem }
        server = url.absoluteString
        UserDefaults.standard.set(server, forKey: "server")
        addressGen += 1                                       // an older address check doesn't change it now
        activeAddress = home
        lastRefresh = .distantPast
        await checkSignIn()
        if home.isEmpty { await chooseAddress() }
        if !needSignIn { Task { await refreshAll() } }      // the lists load in the background - connected already
        return nil
    }

    func refreshAll() async {
        lastRefresh = Date()
        if let api = api { await Places.flush(api) }          // places kept while the PC couldn't be reached
        flushSignOuts()
        await refreshDevices(announce: false)
        await loadContinue()
        await loadContinueBooks()
        await refreshStatus()
    }

    /// Play on: the TVs and this phone, the ones used last first.
    var playOnList: [(String, String)] {
        let used = UserDefaults.standard.dictionary(forKey: "devUsed") as? [String: Double] ?? [:]
        var all = devices.map { ($0.id, $0.name + ($0.pair == true ? " - pair it first" : ""), max(($0.last ?? 0), used[$0.id] ?? 0)) }
        all.append((AppModel.phoneID, AppModel.phoneName, used[AppModel.phoneID] ?? 0))
        return all.enumerated().sorted { a, b in a.element.2 != b.element.2 ? a.element.2 > b.element.2 : a.offset < b.offset }
            .map { ($0.element.0, $0.element.1) }
    }

    static func noteUsed(_ id: String) {
        var used = UserDefaults.standard.dictionary(forKey: "devUsed") as? [String: Double] ?? [:]
        used[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(used, forKey: "devUsed")
    }

    /// An Apple TV is paired with the PC once: the TV shows a code, she types it in.
    func pairStart(_ d: Device) {
        guard let api = api else { return }
        say("Asking \(AppModel.baseName(d.name)) for a code.")
        Task {
            do {
                let r = try await api.post("api/play/pair", ["device": d.id], as: MessageResponse.self)
                self.say(r.message)
                self.pairCode = ""
                self.pairing = d
            } catch { self.say(error.localizedDescription) }
        }
    }

    func pairFinish() {
        guard let d = pairing, let api = api else { return }
        pairing = nil
        let code = pairCode
        Task {
            do {
                let r = try await api.post("api/play/pair", ["device": d.id, "pin": code], as: MessageResponse.self)
                self.say(r.message)
                await self.refreshDevices(announce: false)
                if let n = self.devices.first(where: { $0.id == d.id }), n.pair != true { self.target = n.id }
            } catch { self.say(error.localizedDescription) }
        }
    }

    func refreshDevices(announce: Bool) async {
        guard let api = api else { return }
        do {
            let r = try await api.get("api/play/devices", as: DevicesResponse.self)
            devices = r.devices
            otherDevices = r.other ?? []
            let saved = UserDefaults.standard.string(forKey: "targetName") ?? AppModel.phoneName
            if !isPhone && !devices.contains(where: { $0.id == target }) {
                // the TV reconnected (new id) or went away: find it again by its name
                choose(byName: saved, tellIfMissing: true)
            } else if !restoredOnce {
                choose(byName: saved, tellIfMissing: true)
            }
            restoredOnce = true
            if announce {
                let n = devices.count
                say(n == 0 ? "No TVs found. Open Emby or Moonfin on the TV, then refresh the TV list."
                           : "\(n) TV\(n == 1 ? "" : "s") found.")
            }
        } catch {
            if announce { say(error.localizedDescription) }
        }
    }

    private func choose(byName name: String, tellIfMissing: Bool) {
        guard name != AppModel.phoneName else { return }
        restoring = true
        defer { restoring = false }
        if let d = devices.first(where: { $0.name == name }) ?? devices.first(where: { AppModel.baseName($0.name) == AppModel.baseName(name) }) {
            target = d.id
        } else {
            target = AppModel.phoneID
            if tellIfMissing {
                message = "\(AppModel.baseName(name)) isn't connected right now, so this phone is chosen. Open Emby or Moonfin on the TV, then refresh the TV list."
            }
        }
    }

    func loadContinue() async {
        guard api != nil else { return }
        continueLoading = true
        defer { continueLoading = false }
        if let items = try? await list(kind: "continue") { continueItems = items }
    }

    func list(kind: String, parent: String? = nil, query: String? = nil, view: ListView? = nil) async throws -> [Item] {
        guard let api = api else { throw APIError.badAddress }
        var q: [String: String?] = ["kind": kind, "device": target, "parent": parent, "q": query]
        if let view = view { for (k, v) in view.query { q[k] = v } }
        let r = try await api.get("api/play/list", q, as: ItemsResponse.self)
        return r.items
    }

    /// What a list's filters can choose from (its genres, parental ratings and years).
    func filterChoices(kind: String) async -> FilterChoices? {
        guard let api = api else { return nil }
        return try? await api.get("api/play/filters", ["kind": kind], as: FilterChoices.self)
    }

    /// A download plays on this phone (it's on the phone, not the PC).
    func playDownloaded(_ s: Offline.Saved) {
        if !isPhone { target = AppModel.phoneID }
        if s.kind == "book" {
            playBook(id: s.item, label: s.title, resume: true)
        } else {
            play(Item(id: s.item, type: s.itemType, label: s.title, length: nil, played: nil, resume: nil, resumeTicks: nil, hasAD: s.hasAD),
                 resume: true)
        }
    }

    /// Play together works on the phone: with a TV chosen, it moves to the phone first.
    func phoneForTogether() {
        if !isPhone { target = AppModel.phoneID }
    }

    /// Home at the bottom of each screen: back to the start (the lists close).
    @Published var homeToken = UUID()
    func goHome() {
        showPlayer = false
        homeToken = UUID()
    }

    // MARK: audiobooks

    func loadContinueBooks() async {
        guard api != nil else { return }
        do {
            continueBooks = try await bookList(kind: "books_continue")
            booksSetUp = true
            booksNote = ""
        } catch APIError.server(let message) {
            // not set up on the PC (or the PC's app is older than audiobooks): hide them
            if message.contains("aren't set up") || message.contains("(404)") {
                booksSetUp = false
            } else {
                booksNote = message
            }
        } catch {
            booksNote = error.localizedDescription
        }
    }

    func bookList(kind: String, parent: String? = nil, query: String? = nil) async throws -> [BookItem] {
        guard let api = api else { throw APIError.badAddress }
        let r = try await api.get("api/play/books/list", ["kind": kind, "parent": parent, "q": query], as: BookItemsResponse.self)
        return r.items
    }

    // MARK: bookmarks

    /// Keeps the place it's at now as a bookmark (named after the chapter and time).
    /// Add to / remove from favorites (as on the web page). Returns the PC's message, or nil after saying the problem.
    func setFavorite(_ item: Item, on: Bool) async -> String? {
        guard let api = api else { return nil }
        do {
            return try await api.post("api/play/favorite", ["item": item.id, "on": on ? "1" : "0"], as: MessageResponse.self).message
        } catch {
            say(error.localizedDescription); return nil
        }
    }

    /// Ask for audio description for a show or movie that has none.
    func requestAD(_ item: Item) async -> String? {
        guard let api = api else { return nil }
        do {
            return try await api.post("api/play/request", ["item": item.id], as: MessageResponse.self).message
        } catch {
            say(error.localizedDescription); return nil
        }
    }

    func addBookmark(bookID: String, at: Double) {
        guard let api = api, !bookID.isEmpty else { return }
        Task {
            do {
                let r = try await api.post("api/play/books/bookmark", ["item": bookID, "time": String(format: "%.1f", at)], as: BookmarksResponse.self)
                self.say(r.message ?? "Bookmark added.")
            } catch {
                self.say(error.localizedDescription)
            }
        }
    }

    func bookmarks(_ bookID: String) async throws -> [BookmarkEntry] {
        guard let api = api else { throw APIError.badAddress }
        return BookmarkEntry.numbered(try await api.get("api/play/books/bookmarks", ["id": bookID], as: BookmarksResponse.self).bookmarks)
    }

    /// action: remove or rename. Returns the bookmarks as they are now.
    func changeBookmark(_ bookID: String, _ action: String, time: Double, title: String = "") async throws -> [BookmarkEntry] {
        guard let api = api else { throw APIError.badAddress }
        let r = try await api.post("api/play/books/bookmark", ["item": bookID, "action": action, "time": String(format: "%.1f", time),
                                                               "title": title], as: BookmarksResponse.self)
        if let m = r.message { say(m) }
        return BookmarkEntry.numbered(r.bookmarks)
    }

    /// at: start this many seconds into the book (a chapter); otherwise her place when resume is true.
    func playBook(id: String, label: String, resume: Bool, at: Double? = nil, together startTogether: Bool = false) {
        if video.active { video.stop() }
        if together.active && together.isBook && together.room?.item == id, let at = at, !startTogether {
            together.seekTo(at)                                    // a chapter of the book we're listening to together
            showPlayer = true
            return
        }
        if startTogether {
            phoneForTogether()
            together.startBook(id: id, label: label, resume: resume, at: at)
            return
        }
        if together.active { together.leave(quiet: true) }
        if isPhone {
            if phone.active { phone.stop(saving: true, quiet: true, notify: false) }
            showPlayer = true
            book.start(id: id, label: label, resume: resume, at: at)
            return
        }
        guard let api = api else { return }
        if phone.active { phone.stop(saving: true, quiet: true, notify: false) }
        if book.active { book.stop(saving: true, quiet: true, notify: false) }
        var form = ["device": target, "item": id, "resume": resume ? "1" : "0"]
        if let at = at { form["at"] = String(format: "%.1f", at) }
        Task {
            do {
                let r = try await api.post("api/play/books/start", form, as: MessageResponse.self)
                self.tvStartedAt = Date()
                self.tvMisses = 0
                self.showPlayer = true
                self.say(r.message)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.refreshStatus()
            } catch {
                self.say(error.localizedDescription)
            }
        }
    }

    // MARK: playing

    func play(_ item: Item, resume: Bool, together startTogether: Bool = false) {
        if video.active { video.stop() }
        if startTogether {
            phoneForTogether()
            together.startShow(item, resume: resume)
            return
        }
        if together.active { together.leave(quiet: true) }
        if isPhone {
            if book.active { book.stop(saving: true, quiet: true, notify: false) }
            showPlayer = true
            phone.start(item, resume: resume)
            return
        }
        guard let api = api else { return }
        if phone.active { phone.stop(saving: true, quiet: true, notify: false) }
        if book.active { book.stop(saving: true, quiet: true, notify: false) }
        let device = target
        Task {
            do {
                let r = try await api.post("api/play/start", ["device": device, "item": item.id, "resume": resume ? "1" : "0"], as: MessageResponse.self)
                self.tvStartedAt = Date()
                self.tvMisses = 0
                self.showPlayer = true
                self.say(r.message)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.refreshStatus()
            } catch {
                self.say(error.localizedDescription)
            }
        }
    }

    /// A button for the TV: pause, unpause, back30, fwd30, stop, next, volup, voldown, ad
    func tv(_ command: String) {
        guard let api = api, !isPhone else { return }
        let device = target
        // Play / Pause shows the other one straight away (a second press then doesn't send the same again)
        let playPause = command == "pause" || command == "unpause"
        if playPause { tvState.guess(paused: command == "pause") }
        Task {
            do {
                let r = try await api.post("api/play/cmd", ["device": device, "cmd": command], as: MessageResponse.self)
                if command == "stop" {
                    self.showPlayer = false
                    self.tvStatus = nil
                }
                if command == "next" || command == "prev" { self.tvStartedAt = Date() }
                self.say(r.message)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await self.refreshStatus()
                if command == "stop" { await self.loadContinue(); await self.loadContinueBooks() }
            } catch {
                if playPause { self.tvState.clearGuess() }
                self.say(error.localizedDescription)
            }
        }
    }

    func refreshStatus() async {
        guard let api = api, !isPhone else { tvStatus = nil; return }
        let device = target
        guard let s = try? await api.get("api/play/status", ["device": device], as: TVStatus.self), device == target else { return }
        tvStatus = s
        if s.playing {
            tvMisses = 0
        } else if showPlayer && Date().timeIntervalSince(tvStartedAt) > 10 {
            // it finished, or was stopped on the TV itself: back to choosing something
            tvMisses += 1
            if tvMisses >= 2 {
                showPlayer = false
                await loadContinue()
                await loadContinueBooks()
            }
        }
    }

    /// Play or Pause on the TV, by what the screen shows (it changes straight away when pressed).
    func tvPlayPause() {
        tv(tvState.paused ? "unpause" : "pause")
    }

    /// Magic Tap (two-finger double tap): play or pause what's playing - on this phone, together, or on the TV.
    func playPause() {
        if video.active { video.playPause(); return }
        if together.active { together.command("playpause"); return }
        if isPhone {
            if book.active { book.togglePause() }
            else if phone.active { phone.togglePause() }
            else if !resumeLast() { say("Nothing is playing.") }
            return
        }
        guard tvStatus?.playing == true else { say("Nothing is playing on the TV."); return }
        tvPlayPause()
    }

    func whereAmI() {
        Task { self.say(await self.whereAmIText()) }
    }

    /// What's playing, where she is in it and the time left (the Where am I? button, and Siri).
    func whereAmIText() async -> String {
        if isPhone && book.active {
            if book.preparing { return book.statusText }
            var text = Speak.whereAmI(title: book.title, position: book.currentTime(), total: book.duration, paused: book.paused, on: " on this phone")
            if let chapter = book.chapterSentence(book.currentTime()) { text += " " + chapter }
            if let sleep = book.sleepText { text += " " + sleep }
            return text
        }
        if isPhone {
            guard phone.active else { return "Nothing is playing on this phone." }
            if phone.preparing { return phone.statusText }
            return Speak.whereAmI(title: phone.title, position: phone.currentTime(), total: phone.duration,
                                  paused: phone.paused, on: " on this phone")
        }
        await refreshStatus()
        guard let s = tvStatus else { return "Couldn't reach the TV." }
        if s.book == true { return s.text }
        if s.playing, let pos = s.posTicks, let run = s.runTicks, run > 0 {
            var text = Speak.whereAmI(title: s.title ?? "", position: pos / 10_000_000, total: run / 10_000_000,
                                      paused: s.paused ?? false, on: "")
            if s.ad == false && s.hasAD == true { text += " Audio description is off." }
            if s.hasAD == false { text += " No audio description track." }
            return text
        }
        return s.text
    }

    // MARK: Siri and the Shortcuts app

    private enum Match {
        case item(Item)
        case book(BookItem)
    }

    /// "Play … in AD Player": finds it on the PC (movies, shows, episodes, audiobooks) and plays the best match where
    /// Play on is set. A show plays its next episode. Returns what Siri says.
    func playBestMatch(_ asked: String) async -> String {
        let q = asked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "Say what to play." }
        guard api != nil else { return "Set up AD Player first: type the address of the PC." }
        guard !needSignIn else { return "Sign in to AD Player first." }
        // "friends 4 2": one episode was asked for
        let wantsEpisode = q.range(of: #"\d+\s+\d+\s*$"#, options: .regularExpression) != nil
        var best: (score: Double, match: Match)?
        var problem: String?
        func consider(_ label: String, _ m: Match, _ bonus: Double) {
            let sc = AppModel.matchScore(label, q) + bonus
            if best == nil || sc > best!.score { best = (sc, m) }
        }
        for kind in ["search_movies", "search_shows"] {
            do {
                for (n, it) in try await list(kind: kind, query: q).enumerated() {
                    guard ["Movie", "Video", "Episode", "Series"].contains(it.type ?? "") else { continue }
                    consider(it.label, .item(it), (wantsEpisode && it.type == "Episode" ? 5 : 0) - Double(n) * 0.01)
                }
            } catch {
                problem = problem ?? error.localizedDescription
            }
        }
        if booksSetUp {
            do {
                for (n, b) in try await bookList(kind: "books_search", query: q).enumerated() {
                    guard !["BookSeries", "BookAuthor", "Chapter"].contains(b.type) else { continue }
                    consider(b.label, .book(b), -Double(n) * 0.01)
                }
            } catch {
                problem = problem ?? error.localizedDescription
            }
        }
        guard let found = best?.match else { return problem ?? "Nothing found for \(q)." }
        let place = isPhone ? "" : " on \(AppModel.baseName(targetName))"
        switch found {
        case .book(let b):
            playBook(id: b.id, label: b.label, resume: true)
            return "Playing \(b.label)\(place)."
        case .item(let it):
            if it.type == "Series" {
                guard let ep = await nextEpisode(of: it) else { return "No episode of \(it.label) is left to watch." }
                play(ep, resume: true)
                return "Playing \(ep.label)\(place)."
            }
            play(it, resume: true)
            return "Playing \(it.label)\(place)."
        }
    }

    /// 3: the same name, 2: starts with it, 1.5: has it in it, 1: the PC found it some other way (author, say).
    private static func matchScore(_ label: String, _ asked: String) -> Double {
        func plain(_ s: String) -> String {
            s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let l = plain(label), a = plain(asked)
        if a.isEmpty { return 1 }
        if l == a { return 3 }
        if l.hasPrefix(a) { return 2 }
        if l.contains(a) { return 1.5 }
        return 1
    }

    /// A show's next episode: the first one, season by season, that's in progress or not watched yet.
    private func nextEpisode(of series: Item) async -> Item? {
        guard let all = try? await list(kind: "seasons", parent: series.id) else { return nil }
        let seasons = all.filter { $0.type == nil || $0.type == "Season" }
        let regular = seasons.filter { !$0.label.lowercased().contains("special") }
        for season in regular.isEmpty ? seasons : regular {
            guard let eps = try? await list(kind: "episodes", parent: season.id) else { continue }
            if let e = eps.first(where: { $0.canResume || $0.played != true }) { return e }
        }
        return nil
    }

    /// "Resume AD Player": carries on with what's loaded, or the last thing played on this phone.
    func resumeForSiri() -> String {
        if together.active { together.command("play"); return "Playing together." }
        if isPhone && book.active { book.play(); return "Playing \(book.title)." }
        if isPhone && phone.active { phone.play(); return "Playing \(phone.title)." }
        if !isPhone, let s = tvStatus, s.playing {
            if s.paused == true { tv("unpause") }
            return "Playing \(s.title ?? "") on the TV."
        }
        let last = LastPlay.load()
        if resumeLast() { return "Carrying on with \(last?.title ?? "the last one")." }
        return api == nil ? "Set up AD Player first: type the address of the PC." : "Nothing to carry on with yet."
    }

    // MARK: app comes and goes

    func scene(active: Bool) {
        pollTask?.cancel()
        pollTask = nil
        together.inBackground = !active
        guard active else {
            phone.saveNow()
            book.saveNow()
            if video.active { video.save() }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard let self = self else { return }
                    if !self.needSignIn && !self.together.active { await self.together.pollInvites() }
                }
            }
            return
        }
        Offline.shared.resume()
        if api != nil && Date().timeIntervalSince(lastRefresh) > 30 {
            Task {
                await self.chooseAddress()
                await self.checkSignIn()
                if !self.needSignIn { await self.refreshAll() }
            }
        }
        pollTask = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                guard let self = self else { return }
                if !self.needSignIn {
                    if !self.isPhone && n % (self.showPlayer ? 3 : 15) == 0 { await self.refreshStatus() }
                    if !self.together.active && n % 5 == 0 { await self.together.pollInvites() }
                }
                n += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: lock screen, Control Center and headphone buttons

    /// One set of handlers for both players: they go to whichever is playing.
    /// Next and previous (AirPods double and triple press, the car, the lock screen) are 30 seconds forward and back:
    /// a press never moves her far from her place. Episodes and chapters are chosen with the app's own buttons.
    private func setUpRemoteControls() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.handle("play") ?? .commandFailed }
        c.pauseCommand.addTarget { [weak self] _ in self?.handle("pause") ?? .commandFailed }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.handle("toggle") ?? .commandFailed }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.handle("fwd") ?? .commandFailed }
        c.skipBackwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.handle("back") ?? .commandFailed }
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in self?.handle("fwd") ?? .commandFailed }
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in self?.handle("back") ?? .commandFailed }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.handle("seek", e.positionTime) ?? .commandFailed
        }
    }

    /// iPhone calls these on the main thread; the answer says whether there was anything to work.
    nonisolated private func handle(_ action: String, _ value: Double = 0) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { self.remote(action, value) }
        }
        Task { @MainActor in _ = self.remote(action, value) }
        return .success
    }

    @discardableResult
    private func remote(_ action: String, _ value: Double = 0) -> MPRemoteCommandHandlerStatus {
        if video.active {
            switch action {
            case "play": if video.paused { video.playPause() }
            case "pause": if !video.paused { video.playPause() }
            case "toggle": video.playPause()
            case "fwd": video.skip(30)
            case "back": video.skip(-30)
            case "seek": video.player.seek(to: CMTime(seconds: value, preferredTimescale: 600))
            default: return .commandFailed
            }
            return .success
        }
        if together.active {
            switch action {
            case "play": together.command("play")
            case "pause": together.command("pause")
            case "toggle": together.command("playpause")
            case "fwd": together.command("fwd30")
            case "back": together.command("back30")
            case "seek": together.seekTo(value)
            default: return .commandFailed
            }
            return .success
        }
        if book.active {
            guard book.canControl else { return .commandFailed }
            switch action {
            case "play": book.play()
            case "pause": book.pause(quiet: true)
            case "toggle": book.togglePause(quiet: true)
            case "fwd": book.skip(30, quiet: true)
            case "back": book.skip(-30, quiet: true)
            case "seek": book.seek(to: value)
            default: return .commandFailed
            }
            return .success
        }
        if phone.active {
            guard phone.canControl else { return .commandFailed }
            switch action {
            case "play": phone.play()
            case "pause": phone.pause(quiet: true)
            case "toggle": phone.togglePause(quiet: true)
            case "fwd": phone.skip(30, quiet: true)
            case "back": phone.skip(-30, quiet: true)
            case "seek": phone.seek(to: value, quiet: true)
            default: return .commandFailed
            }
            return .success
        }
        // nothing loaded (the app was closed, or the phone restarted): Play carries on with the last one
        if action == "play" || action == "toggle" { return resumeLast() ? .success : .noActionableNowPlayingItem }
        return .noActionableNowPlayingItem
    }

    /// Carries on with the last thing played on this phone, from her place.
    @discardableResult
    func resumeLast() -> Bool {
        guard !phoneBusy, !together.active, !video.active, let l = LastPlay.load(), api != nil else { return false }
        if !isPhone { target = AppModel.phoneID }
        showPlayer = true
        if l.kind == "book" {
            book.start(id: l.item, label: l.title, resume: true, at: nil)
        } else {
            phone.start(Item(id: l.item, type: l.type, label: l.title, length: nil, played: nil, resume: nil, resumeTicks: nil,
                             hasAD: l.hasAD), resume: true)
        }
        return true
    }

    /// The lock screen shows the last thing played (after the app was closed), so Play there carries on with it.
    private func restoreNowPlaying() {
        guard !phoneBusy, let l = LastPlay.load() else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: l.title,
                                   MPMediaItemPropertyArtist: l.kind == "book" ? "Audiobook" : (l.hasAD == false ? "Soundtrack" : "Audio description"),
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: l.pos,
                                   MPNowPlayingInfoPropertyPlaybackRate: 0.0]
        if l.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = l.duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: calls, Siri, headphones coming out, the app closing

    private func setUpSoundEvents() {
        let n = NotificationCenter.default
        n.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            #if os(iOS)
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap { AVAudioSession.InterruptionReason(rawValue: $0) }
            let suspended = reason == .appWasSuspended
            #else
            let suspended = false                    // (the Apple TV doesn't say why)
            #endif
            let resume = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            Task { @MainActor in self?.interruption(type, suspended: suspended, resume: resume) }
        }
        n.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            guard reason == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.headphonesGone() }
        }
        n.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.mediaReset() }
        }
        n.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // her place is kept on the phone straight away (sent to the PC when it can be)
            MainActor.assumeIsolated {
                self?.phone.saveNow()
                self?.book.saveNow()
                // swiped away while paused together: it leaves the room, so the others aren't kept waiting
                self?.together.leaveIfIdle()
            }
        }
    }

    /// A phone call or Siri: her place is kept; playing together, it pauses for everyone. Afterwards it carries on
    /// only if it was playing and iPhone says to (a book together: the others decide).
    private func interruption(_ type: AVAudioSession.InterruptionType?, suspended: Bool, resume: Bool) {
        guard let type = type else { return }
        if type == .began {
            if suspended { return }                     // (the app was only asleep - nothing was interrupted)
            phone.saveNow()
            book.saveNow()
            if together.active {
                interruptedPlaying = together.roomPlaying
                if interruptedPlaying { together.pauseHere("Paused for everyone.") }
            } else {
                interruptedPlaying = phone.wasPlaying || book.wasPlaying
            }
            return
        }
        let wasPlaying = interruptedPlaying
        interruptedPlaying = false
        guard wasPlaying, resume else { return }
        if together.active {
            if !together.isBook { together.command("play") }
            return
        }
        if book.active { book.play() } else if phone.active { phone.play() }
    }

    /// Headphones taken out or Bluetooth lost: it pauses (for everyone, playing together), so it doesn't carry on
    /// out loud on the phone's speaker.
    private func headphonesGone() {
        if together.active {
            if together.roomPlaying { together.pauseHere("Paused for everyone - headphones disconnected.") }
            return
        }
        if book.active && book.canControl {
            let was = book.wasPlaying
            book.pause(quiet: true)
            if was { say("Paused - headphones disconnected.") }
        } else if phone.active && phone.canControl {
            let was = phone.wasPlaying
            phone.pause(quiet: true)
            if was { say("Paused - headphones disconnected.") }
        }
    }

    /// iPhone's sound system restarted: the players and the sound are set up again.
    private func mediaReset() {
        KeepAlive.shared.reset()
        if phone.active { phone.mediaReset() }
        if book.active { book.mediaReset() }
    }

    /// Nothing plays any more: the sound is let go, so other apps can carry on.
    func soundIdle() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !self.phone.active, !self.book.active, !self.together.active, !self.video.active else { return }
            KeepAlive.shared.stop()
            Sound.deactivate()
        }
    }
}

/// The TV's state (asked every few seconds while Now playing is open). Kept apart from the model so only the
/// screens that show it are redrawn, and only when something really changed.
@MainActor
final class TVState: ObservableObject {
    @Published private(set) var status: TVStatus?
    /// Play or Pause just pressed: shown straight away, until the TV says the same (or a few seconds pass).
    @Published private(set) var pausedGuess: Bool?
    private var guessAt = Date.distantPast

    /// Paused, as the screen shows it.
    var paused: Bool { pausedGuess ?? (status?.paused ?? false) }

    func set(_ s: TVStatus?) {
        if let g = pausedGuess, s == nil || s?.paused == g || Date().timeIntervalSince(guessAt) > 4 { pausedGuess = nil }
        if status != s { status = s }
    }

    func guess(paused: Bool) {
        pausedGuess = paused
        guessAt = Date()
    }

    func clearGuess() {
        if pausedGuess != nil { pausedGuess = nil }
    }
}
