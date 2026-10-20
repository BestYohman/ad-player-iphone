import Foundation
import SwiftUI
import UIKit

/// Everything the screens share: the PC's address, the chosen TV (or this phone), what's playing.
@MainActor
final class AppModel: ObservableObject {
    nonisolated static let phoneID = "__local"
    nonisolated static let phoneName = "This phone - just the audio"

    @Published var server: String = UserDefaults.standard.string(forKey: "server") ?? ""
    @Published var devices: [Device] = []
    @Published var otherDevices: [String] = []
    @Published var target: String = AppModel.phoneID {
        didSet {
            guard oldValue != target else { return }
            if !restoring { UserDefaults.standard.set(nameOf(target), forKey: "targetName") }
            tvStatus = nil
            tvMisses = 0
            Task { await self.refreshStatus(); await self.loadContinue() }
        }
    }
    @Published var continueItems: [Item] = []
    @Published var continueLoading = false
    @Published var message = ""
    @Published var showPlayer = false
    @Published var tvStatus: TVStatus?

    let phone: PhonePlayer

    private var restoring = false
    private var restoredOnce = false
    private var pollTask: Task<Void, Never>?
    private var tvStartedAt = Date.distantPast
    private var tvMisses = 0
    private var lastRefresh = Date.distantPast

    init() {
        phone = PhonePlayer()
        phone.api = { [weak self] in self?.api }
        phone.say = { [weak self] text in self?.say(text) }
        phone.onEnded = { [weak self] in
            guard let self = self else { return }
            if self.isPhone { self.showPlayer = false }
            Task { await self.loadContinue() }
        }
    }

    var api: API? { API.normalise(server).map { API(base: $0) } }
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
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    // MARK: connecting

    /// Returns nil when the PC answered, otherwise what went wrong.
    func connect(_ text: String) async -> String? {
        guard let url = API.normalise(text) else { return APIError.badAddress.localizedDescription }
        let probe = API(base: url)
        do {
            _ = try await probe.get("api/play/devices", as: DevicesResponse.self)
        } catch APIError.server(_) {
            // the PC answered (Emby might just be off right now) - good enough
        } catch {
            return error.localizedDescription
        }
        server = url.absoluteString
        UserDefaults.standard.set(server, forKey: "server")
        lastRefresh = .distantPast
        await refreshAll()
        return nil
    }

    func refreshAll() async {
        lastRefresh = Date()
        await refreshDevices(announce: false)
        await loadContinue()
        await refreshStatus()
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

    func list(kind: String, parent: String? = nil, query: String? = nil) async throws -> [Item] {
        guard let api = api else { throw APIError.badAddress }
        let r = try await api.get("api/play/list", ["kind": kind, "device": target, "parent": parent, "q": query], as: ItemsResponse.self)
        return r.items
    }

    // MARK: playing

    func play(_ item: Item, resume: Bool) {
        if isPhone {
            showPlayer = true
            phone.start(item, resume: resume)
            return
        }
        guard let api = api else { return }
        if phone.active { phone.stop(saving: true, quiet: true, notify: false) }
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
        Task {
            do {
                let r = try await api.post("api/play/cmd", ["device": device, "cmd": command], as: MessageResponse.self)
                if command == "stop" {
                    self.showPlayer = false
                    self.tvStatus = nil
                }
                if command == "next" { self.tvStartedAt = Date() }
                self.say(r.message)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await self.refreshStatus()
                if command == "stop" { await self.loadContinue() }
            } catch {
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
            }
        }
    }

    func whereAmI() {
        if isPhone {
            guard phone.active else { say("Nothing is playing on this phone."); return }
            if phone.preparing { say(phone.statusText); return }
            say(Speak.whereAmI(title: phone.title, position: phone.currentTime(), total: phone.duration,
                               paused: phone.paused, on: " on this phone"))
            return
        }
        Task {
            await self.refreshStatus()
            guard let s = self.tvStatus else { self.say("Couldn't reach the TV."); return }
            if s.playing, let pos = s.posTicks, let run = s.runTicks, run > 0 {
                var text = Speak.whereAmI(title: s.title ?? "", position: pos / 10_000_000, total: run / 10_000_000,
                                          paused: s.paused ?? false, on: "")
                if s.ad == false && s.hasAD == true { text += " Audio description is off." }
                if s.hasAD == false { text += " No audio description track." }
                self.say(text)
            } else {
                self.say(s.text)
            }
        }
    }

    // MARK: app comes and goes

    func scene(active: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard active else {
            phone.saveNow()
            return
        }
        if api != nil && Date().timeIntervalSince(lastRefresh) > 30 {
            Task { await self.refreshAll() }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                if !self.isPhone { await self.refreshStatus() }
                let wait: UInt64 = self.showPlayer ? 3 : 15
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }
}
